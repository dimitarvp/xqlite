defmodule Xqlite.TypeExtension do
  @moduledoc """
  Behaviour for converting between Elixir types and SQLite storage values.

  SQLite supports five storage types: NULL, INTEGER, REAL, TEXT, and BLOB.
  Type extensions bridge the gap between richer Elixir types (DateTime, Date,
  custom structs) and these storage types.

  ## Callbacks

    * `encode/1` — converts an Elixir term to a SQLite-compatible value.
      Return `{:ok, sqlite_value}` on success, `:skip` to pass to the next
      extension in the chain, or `{:error, reason}` when the value is this
      extension's to convert but cannot be stored. An `{:error, reason}`
      stops the chain and the call that supplied the parameter fails with
      `{:error, {:type_extension_refused, %{position: n, extension: module,
      reason: reason}}}`, where `n` is the parameter's 1-based place in the
      list.

    * `decode/1` — converts a SQLite value back to an Elixir term.
      Return `{:ok, elixir_term}` on success or `:skip` to pass to the next
      extension. Decoding has no refusal: a value no extension converts is
      handed back as SQLite stored it.

  ## Built-in extensions

    * `Xqlite.TypeExtension.DateTime` — `DateTime` ↔ ISO 8601 text
      (the offset is written; decoding applies it and returns UTC, so
      the instant round-trips and the offset does not)
    * `Xqlite.TypeExtension.NaiveDateTime` — `NaiveDateTime` ↔ ISO 8601 text
    * `Xqlite.TypeExtension.Date` — `Date` ↔ `YYYY-MM-DD` text
    * `Xqlite.TypeExtension.Time` — `Time` ↔ `HH:MM:SS` text
    * `Xqlite.TypeExtension.Instant` — `DateTime` → int64 epoch
      nanoseconds (encode-only; the integer alternative to `DateTime`)
    * `Xqlite.TypeExtension.Duration` — exact-unit `Duration` → int64
      nanoseconds (encode-only; Elixir 1.17+)
    * `Xqlite.TypeExtension.JSON` — plain maps/lists ↔ JSON text
    * `Xqlite.TypeExtension.UUID` — canonical UUID text ↔ compact 16-byte value
    * `Xqlite.TypeExtension.Decimal` — `Decimal` → TEXT (encode-only; needs the
      optional `:decimal` dependency)

  Arrays need no dedicated extension — `Xqlite.TypeExtension.JSON`
  encodes and decodes lists.

  ## Extension ordering

  Extensions are applied in list order. The first extension that returns
  `{:ok, value}` wins — remaining extensions are not consulted. This matters
  most for `decode/1`, where multiple extensions might match the same value.
  Place more specific extensions before general, shape-driven ones: `JSON`
  decodes any JSON-shaped TEXT and `UUID` decodes any 16-byte binary, so a
  narrower converter must precede them to win.

  ## Example

      defmodule MyApp.DecimalExtension do
        @behaviour Xqlite.TypeExtension

        @impl true
        def encode(%Decimal{} = d), do: {:ok, Decimal.to_string(d)}
        def encode(_), do: :skip

        @impl true
        def decode(_), do: :skip
      end

      # Usage with Xqlite.stream/4:
      Xqlite.stream(conn, "SELECT amount FROM payments", [],
        type_extensions: [MyApp.DecimalExtension, Xqlite.TypeExtension.DateTime])
  """

  @doc """
  Converts an Elixir term to a SQLite-compatible storage value.

  Return `{:ok, sqlite_value}` where `sqlite_value` is an integer, float,
  binary, `nil`, or an `%Xqlite.Blob{}` wrapping bytes that must be stored
  as a `BLOB` whatever they contain. Return `:skip` if this extension does
  not handle the given value. Return `{:error, reason}` when the value is
  this extension's to convert but cannot be stored — the chain stops there
  and the caller is told which parameter, which extension and why.
  """
  @callback encode(value :: term()) :: {:ok, Xqlite.sqlite_value()} | :skip | {:error, term()}

  @doc """
  Converts a SQLite storage value back to an Elixir term.

  Return `{:ok, elixir_term}` on successful conversion. Return `:skip`
  if this extension does not handle the given value.
  """
  @callback decode(value :: Xqlite.sqlite_value()) :: {:ok, term()} | :skip

  @doc """
  Encodes a list of query parameters through the extension chain.

  Positional or keyword is decided once, from the list's first element, by
  the same rule the NIF applies when it binds: a list whose first element is
  a two-element tuple with an atom key is a keyword list, and every other
  list is positional. The whole list is then encoded that way — in a keyword
  list every pair's value goes through the chain, in a positional list every
  element does. Values that no extension handles pass through unchanged.

  Answers `{:ok, params}` with the encoded list, or
  `{:error, {:type_extension_refused, %{position: n, extension: module,
  reason: reason}}}` for the first parameter an extension refused. The
  position is 1-based and counts a keyword pair as one parameter, the same
  way the NIF numbers its bindings. `nil` in place of a list is accepted and
  answers `{:ok, nil}`.
  """
  @spec encode_params(params :: list() | keyword() | nil, extensions :: [module()]) ::
          {:ok, list() | keyword() | nil} | {:error, Xqlite.error_reason()}
  def encode_params(params, []), do: {:ok, params}

  def encode_params(nil, _extensions), do: {:ok, nil}

  def encode_params([{key, _} | _] = params, extensions) when is_atom(key) do
    encode_keyword(params, extensions, 1, [])
  end

  def encode_params(params, extensions) when is_list(params) do
    encode_positional(params, extensions, 1, [])
  end

  defp encode_positional([], _extensions, _position, acc), do: {:ok, Enum.reverse(acc)}

  defp encode_positional([value | rest], extensions, position, acc) do
    case encode_value(value, extensions) do
      {:ok, encoded} -> encode_positional(rest, extensions, position + 1, [encoded | acc])
      {:error, details} -> refusal(details, position)
    end
  end

  defp encode_keyword([], _extensions, _position, acc), do: {:ok, Enum.reverse(acc)}

  defp encode_keyword([{key, value} | rest], extensions, position, acc) do
    case encode_value(value, extensions) do
      {:ok, encoded} -> encode_keyword(rest, extensions, position + 1, [{key, encoded} | acc])
      {:error, details} -> refusal(details, position)
    end
  end

  defp encode_keyword([other | rest], extensions, position, acc) do
    encode_keyword(rest, extensions, position + 1, [other | acc])
  end

  defp refusal(%{extension: extension, reason: reason}, position) do
    {:error,
     {:type_extension_refused, %{position: position, extension: extension, reason: reason}}}
  end

  @doc """
  Decodes result rows through the extension chain.

  Each cell in each row is passed through the extension chain.
  Values that no extension handles pass through unchanged.
  """
  @spec decode_rows(rows :: [[term()]], extensions :: [module()]) :: [[term()]]
  def decode_rows(rows, []), do: rows

  def decode_rows(rows, extensions) do
    Enum.map(rows, fn row ->
      Enum.map(row, fn value -> decode_value(value, extensions) end)
    end)
  end

  @doc """
  Encodes a single value through the extension chain.

  Answers `{:ok, encoded}` with the value the first extension that handled
  it produced, or `{:ok, value}` unchanged when no extension matched. An
  extension that claims the value but cannot store it answers
  `{:error, %{extension: module, reason: reason}}` and the chain stops
  there. The answer is always tagged, so a parameter whose own value is an
  `{:error, term}` tuple is never mistaken for a refusal.
  """
  @spec encode_value(value :: term(), extensions :: [module()]) ::
          {:ok, term()} | {:error, %{extension: module(), reason: term()}}
  def encode_value(value, []), do: {:ok, value}

  def encode_value(value, [ext | rest]) do
    case ext.encode(value) do
      {:ok, encoded} -> {:ok, encoded}
      :skip -> encode_value(value, rest)
      {:error, reason} -> {:error, %{extension: ext, reason: reason}}
    end
  end

  @doc """
  Decodes a single value through the extension chain.

  Returns the decoded value from the first extension that handles it,
  or the original value if no extension matches.
  """
  @spec decode_value(value :: term(), extensions :: [module()]) :: term()
  def decode_value(value, []), do: value

  def decode_value(value, [ext | rest]) do
    case ext.decode(value) do
      {:ok, decoded} -> decoded
      :skip -> decode_value(value, rest)
    end
  end
end

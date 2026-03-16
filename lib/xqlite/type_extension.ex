defmodule Xqlite.TypeExtension do
  @moduledoc """
  Behaviour for converting between Elixir types and SQLite storage values.

  SQLite supports five storage types: NULL, INTEGER, REAL, TEXT, and BLOB.
  Type extensions bridge the gap between richer Elixir types (DateTime, Date,
  custom structs) and these storage types.

  ## Callbacks

    * `encode/1` — converts an Elixir term to a SQLite-compatible value.
      Return `{:ok, sqlite_value}` on success or `:skip` to pass to the next
      extension in the chain.

    * `decode/1` — converts a SQLite value back to an Elixir term.
      Return `{:ok, elixir_term}` on success or `:skip` to pass to the next
      extension.

  ## Built-in extensions

    * `Xqlite.TypeExtension.DateTime` — `DateTime` ↔ ISO 8601 text
    * `Xqlite.TypeExtension.NaiveDateTime` — `NaiveDateTime` ↔ ISO 8601 text
    * `Xqlite.TypeExtension.Date` — `Date` ↔ `YYYY-MM-DD` text
    * `Xqlite.TypeExtension.Time` — `Time` ↔ `HH:MM:SS` text

  ## Extension ordering

  Extensions are applied in list order. The first extension that returns
  `{:ok, value}` wins — remaining extensions are not consulted. This matters
  most for `decode/1`, where multiple extensions might match the same string
  format. Place more specific extensions before general ones.

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
  binary, or nil. Return `:skip` if this extension does not handle the
  given value.
  """
  @callback encode(value :: term()) :: {:ok, Xqlite.sqlite_value()} | :skip

  @doc """
  Converts a SQLite storage value back to an Elixir term.

  Return `{:ok, elixir_term}` on successful conversion. Return `:skip`
  if this extension does not handle the given value.
  """
  @callback decode(value :: Xqlite.sqlite_value()) :: {:ok, term()} | :skip

  @doc """
  Encodes a list of query parameters through the extension chain.

  Handles both positional parameter lists and keyword parameter lists.
  Values that no extension handles pass through unchanged.
  """
  @spec encode_params(params :: list() | keyword(), extensions :: [module()]) ::
          list() | keyword()
  def encode_params(params, []), do: params

  def encode_params([{key, _} | _] = params, extensions) when is_atom(key) do
    Enum.map(params, fn
      {k, value} when is_atom(k) -> {k, encode_value(value, extensions)}
      other -> other
    end)
  end

  def encode_params(params, extensions) when is_list(params) do
    Enum.map(params, fn value -> encode_value(value, extensions) end)
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

  Returns the encoded value from the first extension that handles it,
  or the original value if no extension matches.
  """
  @spec encode_value(value :: term(), extensions :: [module()]) :: term()
  def encode_value(value, []), do: value

  def encode_value(value, [ext | rest]) do
    case ext.encode(value) do
      {:ok, encoded} -> encoded
      :skip -> encode_value(value, rest)
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

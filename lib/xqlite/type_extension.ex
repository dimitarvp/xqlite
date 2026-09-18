defmodule Xqlite.TypeExtension do
  @moduledoc """
  Behaviour for converting between Elixir types and SQLite storage values.

  SQLite supports five storage types: NULL, INTEGER, REAL, TEXT, and BLOB.
  Type extensions bridge the gap between richer Elixir types (DateTime, Date,
  custom structs) and these storage types.

  ## Callbacks

    * `encode/1` — converts an Elixir term to a SQLite-compatible value.
      Return `{:ok, value}` on success, `:skip` to pass to the next
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

  Return `{:ok, value}` where `value` is a `t:Xqlite.param_value/0` — an
  integer, a float, a binary, `true`, `false`, `nil`, or an `%Xqlite.Blob{}`
  wrapping bytes that must be stored as a `BLOB` whatever they contain.
  Return `:skip` if this extension does
  not handle the given value. Return `{:error, reason}` when the value is
  this extension's to convert but cannot be stored — the chain stops there
  and the caller is told which parameter, which extension and why.
  """
  @callback encode(value :: term()) :: {:ok, Xqlite.param_value()} | :skip | {:error, term()}

  @doc """
  Converts a SQLite storage value back to an Elixir term.

  Return `{:ok, elixir_term}` on successful conversion. Return `:skip`
  if this extension does not handle the given value.

  There is no `{:error, reason}` here, unlike `c:encode/1`, and that is by
  design: a stored value this extension claims but cannot read back is not a
  failed read, it is a value the extension declines, so the answer is `:skip`
  and the value comes back as SQLite stored it. Returning anything other than
  `{:ok, term}` or `:skip` breaks this contract and raises while the rows are
  being consumed, where none of `Xqlite.stream/4`'s `:on_error` modes catches
  it.
  """
  @callback decode(value :: Xqlite.sqlite_value()) :: {:ok, term()} | :skip

  @doc false
  # Every door that takes `:type_extensions`, and both chain functions below,
  # judge the list here: counting an improper list with `length/1` raised, and
  # a term that is no list at all reached the encode chain and raised there.
  # `nil` means no extensions, as an absent option does.
  @spec validate_extensions(term()) :: {:ok, [module()]} | {:error, Xqlite.error_reason()}
  def validate_extensions(nil), do: {:ok, []}

  def validate_extensions(given) when is_list(given), do: walk_extensions(given, 1, [])

  def validate_extensions(other), do: {:error, {:invalid_type_extensions, not_a_list(other)}}

  defp walk_extensions([], _position, walked), do: {:ok, Enum.reverse(walked)}

  defp walk_extensions([extension | rest], position, walked) when is_atom(extension) do
    case extension_module?(extension) do
      true -> walk_extensions(rest, position + 1, [extension | walked])
      false -> {:error, {:invalid_type_extensions, bad_element(position, extension)}}
    end
  end

  defp walk_extensions([element | _rest], position, _walked),
    do: {:error, {:invalid_type_extensions, bad_element(position, element)}}

  defp walk_extensions(tail, _position, _walked),
    do: {:error, {:invalid_type_extensions, improper_tail(tail)}}

  # Reading the behaviour declaration costs more than the query the walk
  # guards, so a module that passed is remembered for the life of the node.
  # Its two callbacks are asked again on every call, which is cheap and
  # catches one recompiled without them; a false there can also mean the
  # module is merely unloaded, so the full check — which loads it again — has
  # the last word. A module that failed is remembered as nothing, so one
  # fixed and recompiled passes at once.
  defp extension_module?(extension) do
    case :persistent_term.get({__MODULE__, extension}, false) do
      true -> exports_callbacks?(extension) or validate_extension(extension)
      false -> remember_extension(extension, validate_extension(extension))
    end
  end

  defp exports_callbacks?(extension) do
    function_exported?(extension, :encode, 1) and function_exported?(extension, :decode, 1)
  end

  defp validate_extension(extension) do
    Code.ensure_loaded?(extension) and declares_extension?(extension) and
      exports_callbacks?(extension)
  end

  defp remember_extension(extension, true) do
    :persistent_term.put({__MODULE__, extension}, true)
    true
  end

  defp remember_extension(_extension, false), do: false

  defp declares_extension?(extension) do
    attributes = extension.module_info(:attributes)

    attributes
    |> Keyword.get_values(:behaviour)
    |> List.flatten()
    |> Enum.member?(__MODULE__)
  end

  defp not_a_list(term), do: %{reason: :not_a_list, value_type: Xqlite.term_type(term)}
  defp improper_tail(tail), do: %{reason: :improper_tail, value_type: Xqlite.term_type(tail)}

  defp bad_element(position, term),
    do: %{reason: :bad_element, position: position, value_type: Xqlite.term_type(term)}

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

  The parameter list is walked by hand, so it answers for a broken list what
  the native walk answers for the same one, and a call refuses the same way
  with extensions as without: a list whose tail is not `[]` is
  `{:error, {:expected_list, %{reason: :improper_tail, value_type: kind}}}`
  (`:expected_keyword_list` for a keyword list), a term that is no list and
  not `nil` is `{:error, {:expected_list, %{reason: :not_a_list, value_type:
  kind}}}`, and a keyword element that is no `{key, value}` pair travels on
  to the NIF, which answers `{:error, {:expected_keyword_tuple, %{reason:
  :bad_element, position: n, value_type: kind}}}`.

  The extension list is judged first, the way every door that takes the
  `:type_extensions` option judges it: it must be a proper list, or `nil` for
  none, and every element an atom naming a module that declares
  `@behaviour Xqlite.TypeExtension` and exports both callbacks. Anything else
  answers `{:error, {:invalid_type_extensions, refusal}}` before a single
  parameter is touched, the refusal naming what stopped the walk and, for an
  element that is no extension module, its one-based position.
  """
  @spec encode_params(params :: term(), extensions :: term()) ::
          {:ok, term()} | {:error, Xqlite.error_reason()}
  def encode_params(params, extensions) do
    case validate_extensions(extensions) do
      {:ok, []} -> judge_params(params)
      {:ok, walked} -> encode_params_checked(params, walked)
      {:error, reason} -> {:error, reason}
    end
  end

  # With no extension to run, the list is walked for its shape alone and
  # handed back as it came: the same refusals, and no list rebuilt for
  # nothing. The unchecked twin below keeps its short circuit, so a door with
  # no extensions still walks its list once, in the NIF.
  defp judge_params(nil), do: {:ok, nil}

  defp judge_params([{key, _value} | _rest] = params) when is_atom(key),
    do: judge_keyword(params, params)

  defp judge_params(params) when is_list(params), do: judge_positional(params, params)

  defp judge_params(params), do: {:error, {:expected_list, not_a_list(params)}}

  defp judge_positional([], params), do: {:ok, params}
  defp judge_positional([_value | rest], params), do: judge_positional(rest, params)

  defp judge_positional(tail, _params), do: {:error, {:expected_list, improper_tail(tail)}}

  defp judge_keyword([], params), do: {:ok, params}
  defp judge_keyword([_element | rest], params), do: judge_keyword(rest, params)

  defp judge_keyword(tail, _params),
    do: {:error, {:expected_keyword_list, improper_tail(tail)}}

  @doc false
  # For a caller that walked the list already — every door does, before its
  # telemetry metadata — so the list is walked once per call, not once per
  # function that touches it.
  @spec encode_params_checked(params :: term(), extensions :: [module()]) ::
          {:ok, term()} | {:error, Xqlite.error_reason()}
  def encode_params_checked(params, []), do: {:ok, params}

  def encode_params_checked(nil, _extensions), do: {:ok, nil}

  def encode_params_checked([{key, _} | _] = params, extensions) when is_atom(key) do
    encode_keyword(params, extensions, 1, [])
  end

  def encode_params_checked(params, extensions) when is_list(params) do
    encode_positional(params, extensions, 1, [])
  end

  def encode_params_checked(params, _extensions),
    do: {:error, {:expected_list, not_a_list(params)}}

  defp encode_positional([], _extensions, _position, acc), do: {:ok, Enum.reverse(acc)}

  defp encode_positional([value | rest], extensions, position, acc) do
    case encode_value(value, extensions) do
      {:ok, encoded} -> encode_positional(rest, extensions, position + 1, [encoded | acc])
      {:error, details} -> refusal(details, position)
    end
  end

  defp encode_positional(tail, _extensions, _position, _acc),
    do: {:error, {:expected_list, improper_tail(tail)}}

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

  defp encode_keyword(tail, _extensions, _position, _acc),
    do: {:error, {:expected_keyword_list, improper_tail(tail)}}

  defp refusal(%{extension: extension, reason: reason}, position) do
    {:error,
     {:type_extension_refused, %{position: position, extension: extension, reason: reason}}}
  end

  @doc """
  Decodes result rows through the extension chain.

  Each cell in each row is passed through the extension chain.
  Values that no extension handles pass through unchanged.

  Answers `{:ok, rows}` with the decoded rows. The extension list is judged
  first, exactly as `encode_params/2` judges it, and a list that is no proper
  list of extension modules answers
  `{:error, {:invalid_type_extensions, refusal}}` before a single value is
  touched.

  The rows are judged the way `encode_params/2` judges a parameter list: a
  term that is no list is
  `{:error, {:expected_list, %{reason: :not_a_list, value_type: kind}}}`, a
  list whose tail is not `[]` the same tag with `:improper_tail`, and a row
  that is no list the same tag with `:bad_element` and the row's one-based
  `:position`. A row's own tail is read only by the walk that decodes its
  values, so a row whose tail is not `[]` is refused when an extension is on
  and handed back untouched when the extension list is empty.
  """
  @spec decode_rows(rows :: term(), extensions :: term()) ::
          {:ok, [[term()]]} | {:error, Xqlite.error_reason()}
  def decode_rows(rows, extensions) do
    case validate_extensions(extensions) do
      {:ok, walked} -> decode_judged_rows(rows, walked)
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_judged_rows(rows, []) when is_list(rows), do: judge_rows(rows, rows, 1)

  defp decode_judged_rows(rows, extensions) when is_list(rows),
    do: decode_walked_rows(rows, extensions, 1, [])

  defp decode_judged_rows(rows, _extensions), do: {:error, {:expected_list, not_a_list(rows)}}

  defp judge_rows([], rows, _position), do: {:ok, rows}

  defp judge_rows([row | rest], rows, position) when is_list(row),
    do: judge_rows(rest, rows, position + 1)

  defp judge_rows([row | _rest], _rows, position),
    do: {:error, {:expected_list, bad_element(position, row)}}

  defp judge_rows(tail, _rows, _position), do: {:error, {:expected_list, improper_tail(tail)}}

  defp decode_walked_rows([], _extensions, _position, acc), do: {:ok, Enum.reverse(acc)}

  defp decode_walked_rows([row | rest], extensions, position, acc) when is_list(row) do
    case decode_row(row, extensions, []) do
      {:ok, decoded} -> decode_walked_rows(rest, extensions, position + 1, [decoded | acc])
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_walked_rows([row | _rest], _extensions, position, _acc),
    do: {:error, {:expected_list, bad_element(position, row)}}

  defp decode_walked_rows(tail, _extensions, _position, _acc),
    do: {:error, {:expected_list, improper_tail(tail)}}

  defp decode_row([], _extensions, acc), do: {:ok, Enum.reverse(acc)}

  defp decode_row([value | rest], extensions, acc),
    do: decode_row(rest, extensions, [decode_value(value, extensions) | acc])

  defp decode_row(tail, _extensions, _acc), do: {:error, {:expected_list, improper_tail(tail)}}

  @doc false
  # The twin of `encode_params_checked/2` for the read side: the rows come
  # back directly, since a caller that walked the list has nothing left to be
  # refused for.
  @spec decode_rows_checked(rows :: [[term()]], extensions :: [module()]) :: [[term()]]
  def decode_rows_checked(rows, []), do: rows

  def decode_rows_checked(rows, extensions) do
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

  This function runs once per value, so it does not judge the extension
  list — the caller vouches for it. `encode_params/2` and `decode_rows/2`
  are the two functions that judge a list, once per call.
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

  This function runs once per value, so it does not judge the extension
  list — the caller vouches for it. `encode_params/2` and `decode_rows/2`
  are the two functions that judge a list, once per call. An extension whose
  `decode/1` answers anything but `{:ok, term}` or `:skip` breaks the
  callback's contract and raises here.
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

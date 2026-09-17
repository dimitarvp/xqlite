defmodule Xqlite.Pragma do
  @moduledoc ~S"""
  Deals with [Sqlite pragmas](https://www.sqlite.org/pragma.html).

  This module deliberately omits the PRAGMAs that are deprecated, or are used with non-standard
  sqlite compile options, or are intended for testing sqlite.
  """

  alias Xqlite.PragmaSpec

  @type name :: String.t()
  @type pragma_opts :: keyword()
  @type pragma_key :: String.t() | atom()
  @type pragma_value :: String.t() | integer() | boolean() | atom()

  @type get_result ::
          {:ok,
           integer()
           | float()
           | boolean()
           | atom()
           | String.t()
           | list()
           | nil}
          | Xqlite.error()

  @type list_result :: {:ok, list()} | Xqlite.error()

  @type auto_vacuum_key :: 0 | 1 | 2
  @type auto_vacuum_value :: :none | :full | :incremental
  @type secure_delete_key :: 0 | 1 | 2
  @type secure_delete_value :: true | false | :fast
  @type synchronous_key :: 0 | 1 | 2 | 3
  @type synchronous_value :: :off | :normal | :full | :extra
  @type temp_store_key :: 0 | 1 | 2
  @type temp_store_value :: :default | :file | :memory

  @signed_i32 -2_147_483_648..0x7FFFFFFF
  @u32 0..0x7FFFFFFF
  @nonzero_u32 1..0x7FFFFFFF
  @bool 0..1

  @true_words ~w(on yes true)
  @false_words ~w(off no false)

  @schema %{
    application_id: %PragmaSpec{
      return_type: :int,
      read_arities: [0],
      schema_prefix: true,
      writable: true,
      valid_values: @signed_i32
    },
    analysis_limit: %PragmaSpec{
      return_type: :int,
      read_arities: [0],
      writable: true,
      valid_values: @u32
    },
    busy_timeout: %PragmaSpec{
      return_type: :int,
      read_arities: [0],
      writable: true,
      valid_values: @u32
    },
    cache_size: %PragmaSpec{
      return_type: :int,
      read_arities: [0],
      schema_prefix: true,
      writable: true,
      valid_values: @signed_i32
    },
    cache_spill: %PragmaSpec{
      return_type: :int,
      read_arities: [0],
      writable: true,
      valid_values: @u32
    },
    data_version: %PragmaSpec{return_type: :int, read_arities: [0]},
    freelist_count: %PragmaSpec{
      return_type: :int,
      read_arities: [0],
      schema_prefix: true
    },
    hard_heap_limit: %PragmaSpec{
      return_type: :int,
      read_arities: [0],
      writable: true,
      valid_values: @u32
    },
    incremental_vacuum: %PragmaSpec{
      return_type: :int,
      read_arities: [0, 1],
      schema_prefix: true
    },
    journal_size_limit: %PragmaSpec{
      return_type: :int,
      read_arities: [0],
      schema_prefix: true,
      writable: true,
      valid_values: @signed_i32
    },
    legacy_file_format: %PragmaSpec{return_type: :int, read_arities: [0]},
    max_page_count: %PragmaSpec{
      return_type: :int,
      read_arities: [0],
      schema_prefix: true,
      writable: true,
      valid_values: @nonzero_u32
    },
    mmap_size: %PragmaSpec{
      return_type: :int,
      read_arities: [0],
      schema_prefix: true,
      writable: true,
      valid_values: @signed_i32
    },
    page_count: %PragmaSpec{
      return_type: :int,
      read_arities: [0],
      schema_prefix: true
    },
    page_size: %PragmaSpec{
      return_type: :int,
      read_arities: [0],
      schema_prefix: true,
      writable: true,
      valid_values: [512, 1024, 2048, 4096, 8192, 16384, 32768, 65536]
    },
    soft_heap_limit: %PragmaSpec{
      return_type: :int,
      read_arities: [0],
      writable: true,
      valid_values: @u32
    },
    threads: %PragmaSpec{
      return_type: :int,
      read_arities: [0],
      writable: true,
      valid_values: @u32
    },
    user_version: %PragmaSpec{
      return_type: :int,
      read_arities: [0],
      schema_prefix: true,
      writable: true,
      valid_values: @signed_i32
    },
    wal_autocheckpoint: %PragmaSpec{
      return_type: :int,
      read_arities: [0],
      writable: true,
      valid_values: @u32
    },
    auto_vacuum: %PragmaSpec{
      return_type: :int,
      read_arities: [0],
      schema_prefix: true,
      writable: true,
      valid_values: 0..2,
      int_mapping: %{0 => :none, 1 => :full, 2 => :incremental}
    },
    secure_delete: %PragmaSpec{
      return_type: :int,
      read_arities: [0],
      schema_prefix: true,
      writable: true,
      valid_values: 0..2,
      int_mapping: %{0 => false, 1 => true, 2 => :fast}
    },
    synchronous: %PragmaSpec{
      return_type: :int,
      read_arities: [0],
      schema_prefix: true,
      writable: true,
      valid_values: [0, 1, 2, 3, "OFF", "NORMAL", "FULL", "EXTRA"],
      int_mapping: %{0 => :off, 1 => :normal, 2 => :full, 3 => :extra}
    },
    temp_store: %PragmaSpec{
      return_type: :int,
      read_arities: [0],
      writable: true,
      valid_values: [0, 1, 2, "DEFAULT", "FILE", "MEMORY"],
      int_mapping: %{0 => :default, 1 => :file, 2 => :memory}
    },
    automatic_index: %PragmaSpec{
      return_type: :bool,
      read_arities: [0],
      writable: true,
      valid_values: @bool
    },
    cell_size_check: %PragmaSpec{
      return_type: :bool,
      read_arities: [0],
      writable: true,
      valid_values: @bool
    },
    checkpoint_fullfsync: %PragmaSpec{
      return_type: :bool,
      read_arities: [0],
      writable: true,
      valid_values: @bool
    },
    defer_foreign_keys: %PragmaSpec{
      return_type: :bool,
      read_arities: [0],
      writable: true,
      valid_values: @bool
    },
    foreign_keys: %PragmaSpec{
      return_type: :bool,
      read_arities: [0],
      writable: true,
      valid_values: @bool
    },
    fullfsync: %PragmaSpec{
      return_type: :bool,
      read_arities: [0],
      writable: true,
      valid_values: @bool
    },
    ignore_check_constraints: %PragmaSpec{
      return_type: :bool,
      read_arities: [0],
      writable: true,
      valid_values: @bool
    },
    legacy_alter_table: %PragmaSpec{
      return_type: :bool,
      read_arities: [0],
      writable: true,
      valid_values: @bool
    },
    query_only: %PragmaSpec{
      return_type: :bool,
      read_arities: [0],
      writable: true,
      valid_values: @bool
    },
    read_uncommitted: %PragmaSpec{
      return_type: :bool,
      read_arities: [0],
      writable: true,
      valid_values: @bool
    },
    recursive_triggers: %PragmaSpec{
      return_type: :bool,
      read_arities: [0],
      writable: true,
      valid_values: @bool
    },
    reverse_unordered_selects: %PragmaSpec{
      return_type: :bool,
      read_arities: [0],
      writable: true,
      valid_values: @bool
    },
    trusted_schema: %PragmaSpec{
      return_type: :bool,
      read_arities: [0],
      writable: true,
      valid_values: @bool
    },
    encoding: %PragmaSpec{
      return_type: :text,
      read_arities: [0],
      writable: true,
      valid_values: ~w(UTF-8 UTF-16 UTF-16le UTF-16be)
    },
    journal_mode: %PragmaSpec{
      return_type: :text,
      read_arities: [0],
      schema_prefix: true,
      writable: true,
      valid_values: ~w(DELETE TRUNCATE PERSIST MEMORY WAL OFF)
    },
    locking_mode: %PragmaSpec{
      return_type: :text,
      read_arities: [0],
      schema_prefix: true,
      writable: true,
      valid_values: ~w(NORMAL EXCLUSIVE)
    },
    # integrity_check and quick_check return "ok" (text) when no errors,
    # or a list of error strings. Zero-arity GET uses the single-value path.
    integrity_check: %PragmaSpec{
      return_type: :text,
      read_arities: [0, 1],
      schema_prefix: true
    },
    quick_check: %PragmaSpec{
      return_type: :text,
      read_arities: [0, 1],
      schema_prefix: true
    },
    collation_list: %PragmaSpec{return_type: :list, read_arities: [0]},
    compile_options: %PragmaSpec{return_type: :list, read_arities: [0]},
    database_list: %PragmaSpec{return_type: :list, read_arities: [0]},
    foreign_key_check: %PragmaSpec{
      return_type: :list,
      read_arities: [0, 1],
      schema_prefix: true
    },
    foreign_key_list: %PragmaSpec{return_type: :list, read_arities: [1]},
    function_list: %PragmaSpec{return_type: :list, read_arities: [0]},
    index_info: %PragmaSpec{
      return_type: :list,
      read_arities: [1],
      schema_prefix: true
    },
    index_list: %PragmaSpec{
      return_type: :list,
      read_arities: [1],
      schema_prefix: true
    },
    index_xinfo: %PragmaSpec{
      return_type: :list,
      read_arities: [1],
      schema_prefix: true
    },
    module_list: %PragmaSpec{return_type: :list, read_arities: [0]},
    optimize: %PragmaSpec{
      return_type: :list,
      read_arities: [0, 1],
      schema_prefix: true
    },
    pragma_list: %PragmaSpec{return_type: :list, read_arities: [0]},
    table_info: %PragmaSpec{
      return_type: :list,
      read_arities: [1],
      schema_prefix: true
    },
    table_xinfo: %PragmaSpec{
      return_type: :list,
      read_arities: [1],
      schema_prefix: true
    },
    wal_checkpoint: %PragmaSpec{
      return_type: :list,
      read_arities: [0, 1],
      schema_prefix: true
    },
    shrink_memory: %PragmaSpec{return_type: :nothing, read_arities: [0]}
  }

  @all @schema |> Map.keys() |> Enum.sort()

  @string_to_atom_map Map.new(@all, fn key -> {Atom.to_string(key), key} end)

  @readable_with_zero_args @schema
                           |> Enum.filter(fn {_, s} -> 0 in s.read_arities end)
                           |> Enum.map(fn {name, _} -> name end)
                           |> Enum.sort()

  @readable_with_one_arg @schema
                         |> Enum.filter(fn {_, s} -> 1 in s.read_arities end)
                         |> Enum.map(fn {name, _} -> name end)
                         |> Enum.sort()

  @writable @schema
            |> Enum.filter(fn {_, s} -> s.writable end)
            |> Enum.map(fn {name, _} -> name end)
            |> Enum.sort()

  @returning_boolean @schema
                     |> Enum.filter(fn {_, s} -> s.return_type == :bool end)
                     |> Enum.map(fn {name, _} -> name end)
                     |> Enum.sort()

  @returning_int @schema
                 |> Enum.filter(fn {_, s} -> s.return_type == :int end)
                 |> Enum.map(fn {name, _} -> name end)
                 |> Enum.sort()

  @returning_text @schema
                  |> Enum.filter(fn {_, s} -> s.return_type == :text end)
                  |> Enum.map(fn {name, _} -> name end)
                  |> Enum.sort()

  @returning_list @schema
                  |> Enum.filter(fn {_, s} -> s.return_type == :list end)
                  |> Enum.map(fn {name, _} -> name end)
                  |> Enum.sort()

  @returning_nothing @schema
                     |> Enum.filter(fn {_, s} -> s.return_type == :nothing end)
                     |> Enum.map(fn {name, _} -> name end)
                     |> Enum.sort()

  @valid_write_arg_values @schema
                          |> Enum.filter(fn {_, s} -> s.writable and s.valid_values != nil end)
                          |> Map.new(fn {name, s} -> {name, s.valid_values} end)

  @doc ~S"""
  Returns a map of all supported PRAGMAs keyed by name, with `%PragmaSpec{}`
  structs describing each PRAGMA's capabilities.
  """
  @spec schema() :: %{atom() => PragmaSpec.t()}
  def schema, do: @schema

  @doc ~S"""
  Returns a map of writable PRAGMAs to their allowed value specs.
  """
  @spec valid_write_arg_values() :: %{atom() => Range.t() | list()}
  def valid_write_arg_values, do: @valid_write_arg_values

  @doc ~S"""
  Checks a value against a PRAGMA's spec and answers the form SQLite is given.

  This is the one rule `Xqlite.set_pragma/3`, `put/4` and the connection
  options of `Xqlite.open/2` all apply, so no two of them can drift apart.
  The name is matched without regard to case; the value is judged by what
  the pragma stores:

    * a true/false pragma takes `true`, `false`, `1`, `0`, and the words
      `on`, `off`, `yes`, `no`, `true` and `false` as atoms or strings in
      any case. It answers `1` or `0`.
    * a pragma that stores a number takes an integer inside the range its
      spec gives and nothing else — a boolean is refused, because SQLite
      would write it as `ON` and store zero.
    * a pragma that names a mode takes the words its spec lists, as atoms
      or strings in any case, and the integers its spec lists. It answers
      the spec's own upper-case spelling of the word.

  Answers `{:ok, value_for_sqlite}`, or one of:

    * `{:error, {:invalid_pragma_value, %{pragma: name, value: value}}}` —
      including for `nil`, which no pragma takes.
    * `{:error, {:read_only_pragma, name}}` — the pragma cannot be written.
    * `{:error, {:unknown_pragma, name}}` for a name this module does not
      model, atom or string alike, and `{:error, {:invalid_pragma_name,
      key}}` for a key that is neither. `Xqlite.set_pragma/3` treats both as
      "not mine" and hands the value to SQLite as written; `put/4` refuses
      them.
  """
  @spec check_value(pragma_key(), term()) :: {:ok, pragma_value()} | Xqlite.error()
  def check_value(key, value) do
    with {:ok, name} <- resolve_name(key),
         {:ok, spec} <- writable_spec(name) do
      check_spec_value(name, spec, value)
    end
  end

  defp resolve_name(key) when is_atom(key) do
    case Map.fetch(@string_to_atom_map, downcased_name(key)) do
      {:ok, name} -> {:ok, name}
      :error -> {:error, {:unknown_pragma, key}}
    end
  end

  defp resolve_name(key) when is_binary(key) do
    case Map.fetch(@string_to_atom_map, String.downcase(key)) do
      {:ok, name} -> {:ok, name}
      :error -> {:error, {:unknown_pragma, key}}
    end
  end

  defp resolve_name(key), do: {:error, {:invalid_pragma_name, key}}

  defp downcased_name(key) do
    key
    |> Atom.to_string()
    |> String.downcase()
  end

  defp writable_spec(name) do
    case Map.get(@schema, name) do
      %PragmaSpec{writable: true} = spec -> {:ok, spec}
      %PragmaSpec{} -> {:error, {:read_only_pragma, name}}
      nil -> {:error, {:unknown_pragma, name}}
    end
  end

  defp check_spec_value(name, %PragmaSpec{return_type: :bool}, value) do
    case boolean_form(value) do
      {:ok, _} = ok -> ok
      :error -> invalid_value(name, value)
    end
  end

  defp check_spec_value(name, %PragmaSpec{valid_values: values}, value) when is_list(values) do
    case listed_form(values, value) do
      {:ok, _} = ok -> ok
      :error -> invalid_value(name, value)
    end
  end

  defp check_spec_value(name, %PragmaSpec{valid_values: range}, value)
       when is_struct(range, Range) and is_integer(value) do
    case value in range do
      true -> {:ok, value}
      false -> invalid_value(name, value)
    end
  end

  defp check_spec_value(name, _spec, value), do: invalid_value(name, value)

  defp invalid_value(name, value) do
    {:error, {:invalid_pragma_value, %{pragma: name, value: value}}}
  end

  defp boolean_form(true), do: {:ok, 1}
  defp boolean_form(false), do: {:ok, 0}
  defp boolean_form(1), do: {:ok, 1}
  defp boolean_form(0), do: {:ok, 0}

  defp boolean_form(value) when is_atom(value) or is_binary(value) do
    value
    |> word_of()
    |> boolean_word()
  end

  defp boolean_form(_value), do: :error

  defp boolean_word(word) when word in @true_words, do: {:ok, 1}
  defp boolean_word(word) when word in @false_words, do: {:ok, 0}
  defp boolean_word(_word), do: :error

  defp listed_form(values, value) when is_integer(value) do
    case value in values do
      true -> {:ok, value}
      false -> :error
    end
  end

  defp listed_form(values, value) when is_atom(value) or is_binary(value) do
    word = word_of(value)

    case Enum.find(values, fn listed ->
           is_binary(listed) and String.downcase(listed) == word
         end) do
      nil -> :error
      listed -> {:ok, listed}
    end
  end

  defp listed_form(_values, _value), do: :error

  defp word_of(value) when is_binary(value), do: String.downcase(value)

  defp word_of(value) when is_atom(value) do
    value
    |> Atom.to_string()
    |> String.downcase()
  end

  @doc "Returns the names of all PRAGMAs supported by this library."
  @spec all() :: [atom()]
  def all, do: @all

  @doc "Returns the names of all readable PRAGMAs that don't require an argument."
  @spec readable_with_zero_args() :: [atom()]
  def readable_with_zero_args, do: @readable_with_zero_args

  @doc "Returns the names of all readable PRAGMAs that require one argument."
  @spec readable_with_one_arg() :: [atom()]
  def readable_with_one_arg, do: @readable_with_one_arg

  @doc "Returns the names of all writable PRAGMAs."
  @spec writable() :: [atom()]
  def writable, do: @writable

  @doc "Returns the names of all pragmas that return a boolean."
  @spec returning_boolean() :: [atom()]
  def returning_boolean, do: @returning_boolean

  @doc "Returns the names of all pragmas that return an integer."
  @spec returning_int() :: [atom()]
  def returning_int, do: @returning_int

  @doc "Returns the names of all pragmas that return text."
  @spec returning_text() :: [atom()]
  def returning_text, do: @returning_text

  @doc "Returns the names of all pragmas that return a list."
  @spec returning_list() :: [atom()]
  def returning_list, do: @returning_list

  @doc "Returns the names of all pragmas that return nothing."
  @spec returning_nothing() :: [atom()]
  def returning_nothing, do: @returning_nothing

  @doc ~S"""
  A convenience wrapper to extract the `:rows` from a successful `XqliteNIF.query/3` call.
  """
  @spec query_to_pragma_result({:ok, Xqlite.query_result()} | Xqlite.error()) ::
          list_result()
  def query_to_pragma_result({:ok, %{rows: rows}}), do: {:ok, rows}
  def query_to_pragma_result({:error, _} = err), do: err

  @doc ~S"""
  Fetches a PRAGMA's value, optionally specifying an extra argument:
  - `get(db, :auto_vacuum)` is a PRAGMA that does _not_ require an extra argument.
  - `get(db, :table_info, :users)` is a PRAGMA that does require an extra argument.

  The last argument is a list of options:
  - `:db_name` - must be a string. The values `"main"` and `"temp"` are treated specially,
    as in  instruct sqlite to use the main (originally opened) database or a temporary DB
    respectively. Any other value refers to a name of an ATTACH-ed database. This function
    will fail if there is no ATTACH-ed database with the specified name.

  A known name is matched with its case folded, so `:foreign_keys`,
  `:FOREIGN_KEYS`, `"foreign_keys"` and `"FOREIGN_KEYS"` all reach the same
  PRAGMA. A name this module does not know is refused with
  `{:error, {:unknown_pragma, name}}` before any statement is built, with or
  without an extra argument, and a key that is neither an atom nor a string
  with `{:error, {:invalid_pragma_name, key}}`. SQLite parses an unknown
  PRAGMA and ignores it, so letting one through would answer with an empty
  result and no hint that the name was wrong.
  """
  @spec get(Xqlite.conn(), pragma_key(), pragma_key() | pragma_opts(), pragma_opts()) ::
          get_result()
  def get(db, key, arg_or_opts \\ [], opts \\ [])

  def get(db, key, arg, opts) when not is_list(arg) do
    do_get_with_arg(db, key, arg, opts)
  end

  def get(db, key, opts, []) when is_list(opts) do
    do_get_no_arg(db, key, opts)
  end

  def get(db, key, arg_list, opts) when is_list(arg_list) do
    with {:ok, name} <- resolve_name(key) do
      get_list_arg(db, name, arg_list, opts)
    end
  end

  defp get_list_arg(db, name, arg_list, opts) do
    case name in @readable_with_one_arg do
      true -> do_get_with_arg(db, name, arg_list, opts)
      false -> do_get_no_arg(db, name, arg_list ++ opts)
    end
  end

  defp do_get_no_arg(db, key, opts) do
    with {:ok, name} <- resolve_name(key),
         {:ok, spec} <- known_spec(name) do
      dispatch_get(db, name, spec, opts)
    end
  end

  defp known_spec(name) do
    case Map.fetch(@schema, name) do
      {:ok, spec} -> {:ok, spec}
      :error -> {:error, {:unknown_pragma, name}}
    end
  end

  # int_mapping wins over return_type: this clause must stay first.
  defp dispatch_get(db, key, %PragmaSpec{int_mapping: mapping}, opts) when is_map(mapping) do
    with {:ok, value} <- do_pragma_read(db, key, opts) do
      case Map.get(mapping, value) do
        nil -> {:error, {:unexpected_value, value}}
        mapped -> {:ok, mapped}
      end
    end
  end

  defp dispatch_get(db, key, %PragmaSpec{return_type: :bool}, opts) do
    with {:ok, value} <- do_pragma_read(db, key, opts) do
      {:ok, int2bool(value)}
    end
  end

  defp dispatch_get(db, key, %PragmaSpec{return_type: type}, opts)
       when type in [:int, :text] do
    do_pragma_read(db, key, opts)
  end

  defp dispatch_get(db, key, %PragmaSpec{return_type: :list}, opts) do
    with {:ok, rows} <- do_query(db, key, nil, opts) do
      {:ok, process_list_result(key, rows)}
    end
  end

  defp dispatch_get(db, key, %PragmaSpec{return_type: :nothing}, opts) do
    case do_pragma_read(db, key, opts) do
      {:ok, :no_value} -> :ok
      other -> other
    end
  end

  defp do_get_with_arg(db, key, arg, opts) do
    with {:ok, name} <- resolve_name(key),
         {:ok, _spec} <- known_spec(name) do
      query_with_arg(db, name, arg, opts)
    end
  end

  defp query_with_arg(db, key, arg, opts) do
    with {:ok, rows} <- do_query(db, key, arg, opts) do
      {:ok, process_list_result(key, rows)}
    end
  end

  @doc "Returns the list of indexes for the given table."
  @spec index_list(Xqlite.conn(), name(), pragma_opts()) :: list_result()
  def index_list(db, name, opts \\ []), do: get(db, :index_list, name, opts)

  @doc "Returns column information for the given index."
  @spec index_info(Xqlite.conn(), name(), pragma_opts()) :: list_result()
  def index_info(db, name, opts \\ []), do: get(db, :index_info, name, opts)

  @doc "Returns extended column information for the given index, including key vs auxiliary columns."
  @spec index_xinfo(Xqlite.conn(), name(), pragma_opts()) :: list_result()
  def index_xinfo(db, name, opts \\ []), do: get(db, :index_xinfo, name, opts)

  @doc "Returns column information for the given table."
  @spec table_info(Xqlite.conn(), name(), pragma_opts()) :: list_result()
  def table_info(db, name, opts \\ []), do: get(db, :table_info, name, opts)

  @doc "Returns extended column information for the given table, including hidden and generated columns."
  @spec table_xinfo(Xqlite.conn(), name(), pragma_opts()) :: list_result()
  def table_xinfo(db, name, opts \\ []), do: get(db, :table_xinfo, name, opts)

  @doc ~S"""
  Changes a PRAGMA's value.

  A known name is matched with its case folded, the same way `get/3,4` match
  it. A name this module does not know is refused with
  `{:error, {:unknown_pragma, name}}` before any statement is built, and a
  key that is neither an atom nor a string with
  `{:error, {:invalid_pragma_name, key}}`. SQLite parses an unknown PRAGMA
  and ignores it, so letting one through would report success while changing
  nothing.

  The value goes through `check_value/2`, so a value the PRAGMA cannot take
  is refused with `{:error, {:invalid_pragma_value, %{pragma: name, value:
  value}}}` and a PRAGMA that can only be read is refused with
  `{:error, {:read_only_pragma, name}}`. What SQLite is given is the form
  `check_value/2` answered, never the caller's spelling.

  ## Options

    * `:db_name` (string) - Target a specific attached database schema.
      `"main"` and `"temp"` are built-in; other values refer to ATTACH-ed databases.
  """
  @spec put(Xqlite.conn(), pragma_key(), pragma_value(), pragma_opts()) ::
          {:ok, term()} | Xqlite.error()
  def put(db, key, val, opts \\ [])

  def put(db, key, val, opts) do
    with {:ok, name} <- resolve_name(key) do
      do_put(db, name, val, opts)
    end
  end

  defp do_put(db, key_atom, val, opts) do
    case check_value(key_atom, val) do
      {:ok, checked} -> put_checked(db, key_atom, checked, opts)
      {:error, _reason} = err -> err
    end
  end

  defp put_checked(db, key_atom, val, opts) do
    case Keyword.get(opts, :db_name) do
      nil ->
        XqliteNIF.set_pragma(db, to_string(key_atom), val)

      db_name ->
        sql = "PRAGMA #{quote_name(db_name)}.#{key_atom} = #{format_pragma_value(val)};"

        case XqliteNIF.execute_batch(db, sql) do
          :ok -> {:ok, nil}
          error -> error
        end
    end
  end

  defp do_pragma_read(db, key, opts) do
    case Keyword.get(opts, :db_name) do
      nil ->
        XqliteNIF.get_pragma(db, to_string(key))

      db_name ->
        sql = "PRAGMA #{quote_name(db_name)}.#{key};"

        case XqliteNIF.query(db, sql, []) do
          {:ok, %{rows: [[value]]}} -> {:ok, value}
          {:ok, %{rows: []}} -> {:ok, :no_value}
          {:error, _} = err -> err
        end
    end
  end

  defp do_query(db, key, arg, opts) do
    prefix = pragma_prefix(opts)

    sql =
      case arg do
        nil -> "PRAGMA #{prefix}#{key};"
        _ -> "PRAGMA #{prefix}#{key}(#{quote_name(to_string(arg))});"
      end

    db |> XqliteNIF.query(sql, []) |> query_to_pragma_result()
  end

  defp pragma_prefix(opts) do
    case Keyword.get(opts, :db_name) do
      nil -> ""
      db_name -> "#{quote_name(db_name)}."
    end
  end

  @doc false
  @spec quote_name(String.t() | atom()) :: String.t()
  def quote_name(name) do
    "\"#{String.replace(to_string(name), "\"", "\"\"")}\""
  end

  defp process_list_result(key, rows) do
    case key do
      :collation_list ->
        Enum.map(rows, fn
          [seq, name] -> %{seq: seq, name: name}
          other -> %{unknown: other}
        end)

      :integrity_check ->
        values_only(rows)

      :quick_check ->
        values_only(rows)

      _ when is_list(rows) ->
        rows
        |> single_column_rows?()
        |> maybe_flatten(rows)
    end
  end

  defp single_column_rows?([[_single] | _]), do: true
  defp single_column_rows?(_), do: false

  defp maybe_flatten(true, rows), do: values_only(rows)
  defp maybe_flatten(false, rows), do: rows

  defp values_only(r) do
    r
    |> Enum.map(fn
      [{_k, v}] -> v
      [v] -> v
      other -> other
    end)
  end

  # A PRAGMA takes no bound parameter, so a string value is quoted into the
  # statement text; the quote inside it has to be doubled or the value ends
  # the literal early.
  # Only what `check_value/2` answers reaches this: an integer or a word.
  defp format_pragma_value(val) when is_binary(val), do: "'#{String.replace(val, "'", "''")}'"
  defp format_pragma_value(val) when is_integer(val), do: Integer.to_string(val)

  @spec int2bool(0 | 1) :: boolean()
  defp int2bool(0), do: false
  defp int2bool(1), do: true
end

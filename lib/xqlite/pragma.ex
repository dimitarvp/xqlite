defmodule Xqlite.Pragma do
  @moduledoc ~S"""
  Deals with [Sqlite pragmas](https://www.sqlite.org/pragma.html).

  This module deliberately omits the PRAGMAs that are deprecated, or are used with non-standard
  sqlite compile options, or are intended for testing sqlite.
  """

  import Xqlite, only: [int2bool: 1]

  # We need those called in module attribute definitions
  # and that cannot be done with functions in the same module.
  # They have to be in another module.
  import Xqlite.PragmaUtil,
    only: [
      filter: 2,
      of_type: 2,
      readable_with_one_arg?: 1,
      readable_with_zero_args?: 1,
      writable?: 1
    ]

  @type name :: String.t()
  @type pragma_opts :: keyword()
  @type pragma_key :: String.t() | atom()
  @type pragma_value :: String.t() | integer()
  @type pragma_result :: any()
  @type pragma_get_result :: {:ok, list()} | {:error, String.t()}
  @type auto_vacuum_key :: 1 | 2 | 3
  @type auto_vacuum_value :: :none | :full | :incremental
  @type secure_delete_key :: 0 | 1 | 2
  @type secure_delete_value :: true | false | :fast
  @type synchronous_key :: 0 | 1 | 2 | 3
  @type synchronous_value :: :off | :normal | :full | :extra
  @type temp_store_key :: 0 | 1 | 2
  @type temp_store_value :: :default | :file | :memory

  @schema %{
    application_id: [r: {0, true, :int}, w: {true, :int, :nothing}],
    analysis_limit: [r: {0, false, :int}, w: {false, :int, :int}],
    auto_vacuum: [r: {0, true, :int}, w: {true, :int, :nothing}],
    automatic_index: [r: {0, false, :bool}, w: {false, :bool, :nothing}],
    busy_timeout: [r: {0, false, :int}, w: {false, :int, :int}],
    cache_size: [r: {0, true, :int}, w: {true, :int, :nothing}],
    cache_spill: [r: {0, false, :int}, w: {false, :bool, :nothing}, w: {true, :int, :nothing}],
    cell_size_check: [r: {0, false, :bool}, w: {false, :bool, :nothing}],
    checkpoint_fullfsync: [r: {0, false, :bool}, w: {false, :bool, :nothing}],
    collation_list: [r: {0, false, :list}],
    compile_options: [r: {0, false, :list}],
    data_version: [r: {0, false, :int}],
    database_list: [r: {0, false, :list}],
    defer_foreign_keys: [r: {0, false, :bool}, w: {false, :bool, :nothing}],
    encoding: [r: {0, false, :text}, w: {false, :text, :nothing}],
    foreign_key_check: [r: {0, true, :list}, r: {1, true, :text, :list}],
    foreign_key_list: [r: {1, false, :text, :list}],
    foreign_keys: [r: {0, false, :bool}, w: {false, :bool, :nothing}],
    freelist_count: [r: {0, true, :int}],
    fullfsync: [r: {0, false, :bool}, w: {false, :bool, :nothing}],
    function_list: [r: {0, false, :list}],
    hard_heap_limit: [w: {false, :int, :nothing}],
    ignore_check_constraints: [r: {0, false, :bool}, w: {false, :bool, :nothing}],
    incremental_vacuum: [r: {0, true, :int}, r: {1, true, :int, :int}],
    index_info: [r: {1, true, :text, :list}],
    index_list: [r: {1, true, :text, :list}],
    index_xinfo: [r: {1, true, :text, :list}],
    integrity_check: [
      # only returns "ok" in this case.
      r: {0, true, :text},
      r: {0, true, :list},
      # only returns "ok" in this case.
      r: {1, true, :int, :text},
      r: {1, true, :int, :list}
    ],
    journal_mode: [r: {0, true, :text}, w: {true, :text, :text}],
    journal_size_limit: [r: {0, true, :int}, w: {true, :int, :int}],
    legacy_alter_table: [r: {0, false, :bool}, w: {false, :bool, :nothing}],
    legacy_file_format: [r: {0, false, :int}],
    locking_mode: [r: {0, true, :text}, w: {true, :text, :text}],
    max_page_count: [r: {0, true, :int}, w: {true, :int, :int}],
    mmap_size: [r: {0, true, :int}, w: {true, :int, :int}],
    module_list: [r: {0, false, :list}],
    optimize: [
      r: {0, true, :list},
      r: {0, true, :nothing},
      r: {1, true, :int, :list},
      r: {1, true, :int, :nothing}
    ],
    page_count: [r: {0, true, :int}],
    page_size: [r: {0, true, :int}, w: {true, :int, :nothing}],
    pragma_list: [r: {0, false, :list}],
    query_only: [r: {0, false, :bool}, w: {false, :bool, :nothing}],
    quick_check: [
      # only returns "ok" in this case.
      r: {0, true, :text},
      r: {0, true, :list},
      # only returns "ok" in this case.
      r: {1, true, :int, :text},
      r: {1, true, :int, :list}
    ],
    read_uncommitted: [r: {0, false, :bool}, w: {false, :bool, :nothing}],
    recursive_triggers: [r: {0, false, :bool}, w: {false, :bool, :nothing}],
    reverse_unordered_selects: [r: {0, false, :bool}, w: {false, :bool, :nothing}],
    secure_delete: [r: {0, true, :int}, w: {true, :int, :int}],
    shrink_memory: [r: {0, false, :nothing}],
    soft_heap_limit: [r: {0, false, :int}, w: {false, :int, :int}],
    # Int and text can be passed as argument when setting, query always returns int
    synchronous: [r: {0, true, :int}, w: {true, :int, :nothing}, w: {true, :text, :nothing}],
    table_info: [r: {1, true, :text, :list}],
    table_xinfo: [r: {1, true, :text, :list}],
    # Int and text can be passed as argument when setting, query always returns int
    temp_store: [r: {0, false, :int}, w: {false, :int, :nothing}, w: {false, :text, :nothing}],
    threads: [r: {0, false, :int}, w: {false, :int, :int}],
    trusted_schema: [r: {0, false, :bool}, w: {false, :bool, :nothing}],
    user_version: [r: {0, true, :int}, w: {true, :int, :nothing}],
    wal_autocheckpoint: [r: {0, false, :int}, w: {false, :int, :int}],
    wal_checkpoint: [r: {0, true, :list}, r: {1, true, :text, :list}]
  }

  @i32 0..0xFFFFFFFF
  @signed_i32 -2_147_483_648..0x7FFFFFFF
  @u32 0..0x7FFFFFFF
  @nonzero_u32 1..0x7FFFFFFF
  @bool 0..1

  @valid_write_arg_values %{
    application_id: @signed_i32,
    analysis_limit: @i32,
    auto_vacuum: 0..2,
    automatic_index: @bool,
    busy_timeout: @u32,
    cache_size: @signed_i32,
    cache_spill: @u32,
    cell_size_check: @bool,
    checkpoint_fullfsync: @bool,
    defer_foreign_keys: @bool,
    encoding: ~w(UTF-8 UTF-16 UTF-16le UTF-16be),
    foreign_keys: @bool,
    fullfsync: @bool,
    hard_heap_limit: @u32,
    ignore_check_constraints: @bool,
    journal_mode: ~w(DELETE TRUNCATE PERSIST MEMORY WAL OFF),
    journal_size_limit: @i32,
    legacy_alter_table: @bool,
    locking_mode: ~w(NORMAL EXCLUSIVE),
    max_page_count: @nonzero_u32,
    mmap_size: @i32,
    page_size: [512, 1024, 2048, 4096, 8192, 16384, 32768, 65536],
    query_only: @bool,
    read_uncommitted: @bool,
    recursive_triggers: @bool,
    reverse_unordered_selects: @bool,
    secure_delete: 0..2,
    soft_heap_limit: @u32,
    synchronous: [0, 1, 2, 3, "OFF", "NORMAL", "FULL", "EXTRA"],
    temp_store: [0, 1, 2, "DEFAULT", "FILE", "MEMORY"],
    threads: @u32,
    trusted_schema: @bool,
    user_version: @signed_i32,
    wal_autocheckpoint: @i32
  }

  @all @schema |> Map.keys() |> Enum.sort()
  @readable_with_zero_args filter(@schema, &readable_with_zero_args?/1)
  @readable_with_one_arg filter(@schema, &readable_with_one_arg?/1)
  @writable filter(@schema, &writable?/1)
  @returning_boolean of_type(@schema, :bool)
  @returning_int of_type(@schema, :int)
  @returning_text of_type(@schema, :text)
  @returning_list of_type(@schema, :list)
  @returning_nothing of_type(@schema, :nothing)

  @pragmas_with_special_int_mapping [
    :auto_vacuum,
    :secure_delete,
    :synchronous,
    :temp_store
  ]

  @doc ~S"""
  Returns a map with keys equal to all supported PRAGMAs, and the values being detailed
  machine description of the read/write modes of each PRAGMA (contains number of read
  arguments, read/write argument types, whether a schema/database prefix is allowed,
  and the return type).
  """
  def schema(), do: @schema

  @doc ~S"""
  Returns a map with keys equal to all writable PRAGMAs, and the values being a mini
  specification of allowed values.
  """
  def valid_write_arg_values(), do: @valid_write_arg_values

  @doc ~S"""
  Returns the names of all PRAGMAs that are supported by this library.
  """
  def all(), do: @all

  @doc ~S"""
  Returns the names of all readable PRAGMAs that don't require argument.
  """
  def readable_with_zero_args(), do: @readable_with_zero_args

  @doc ~S"""
  Returns the names of all readable PRAGMAs that require one argument.
  """
  def readable_with_one_arg(), do: @readable_with_one_arg

  @doc ~S"""
  Returns the names of all writable PRAGMAs that require one argument.
  """
  def writable(), do: @writable

  @doc ~S"""
  Returns the names of all pragmas, readable and writable, that return a boolean.
  """
  def returning_boolean(), do: @returning_boolean

  @doc ~S"""
  Returns the names of all pragmas, readable and writable, that return an integer.
  """
  def returning_int(), do: @returning_int

  @doc ~S"""
  Returns the names of all pragmas, readable and writable, that return a text.
  """
  def returning_text(), do: @returning_text

  @doc ~S"""
  Returns the names of all pragmas, readable and writable, that return a list.
  """
  def returning_list(), do: @returning_list

  @doc ~S"""
  Returns the names of all pragmas, readable and writable, that return nothing.
  """
  def returning_nothing(), do: @returning_nothing

  @doc ~S"""
  A convenience wrapper to extract the `:rows` from a successful `XqliteNIF.query/3` call.
  """
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
  """
  @spec get(reference(), pragma_key(), pragma_key() | pragma_opts(), pragma_opts()) ::
          pragma_get_result()
  def get(db, key, arg_or_opts \\ [], opts \\ [])

  def get(db, key, arg, opts) when not is_list(arg) do
    # Handles get(db, key, "some_arg") and get(db, key, "some_arg", opts)
    # If the 3rd argument is NOT a list, it MUST be a PRAGMA argument.
    do_get_with_arg(db, key, arg, opts)
  end

  def get(db, key, opts, []) when is_list(opts) do
    # Handles get(db, key) -> get(db, key, [], [])
    # and get(db, key, some: :opt) -> get(db, key, [some: :opt], [])
    # In these cases, there is NO pragma argument.
    do_get_no_arg(db, key, opts)
  end

  def get(db, key, arg_list, opts) when is_list(arg_list) do
    # This is the ambiguous case: get(db, key, [some_list]).
    # Is `[some_list]` an argument (e.g. for a future PRAGMA) or is it opts?
    # We rely on @readable_with_one_arg to decide.
    if key in @readable_with_one_arg do
      # Assume it's an argument
      do_get_with_arg(db, key, arg_list, opts)
    else
      # Assume it's opts
      do_get_no_arg(db, key, arg_list ++ opts)
    end
  end

  # Handler for PRAGMAs that take NO arguments. Dispatches based on return type.
  defp do_get_no_arg(db, key, _opts) when key in @pragmas_with_special_int_mapping do
    with {:ok, value} <- XqliteNIF.get_pragma(db, to_string(key)) do
      {:ok, map_special_int_to_atom(key, value)}
    end
  end

  defp do_get_no_arg(db, key, _opts) when key in @returning_boolean do
    with {:ok, value} <- XqliteNIF.get_pragma(db, to_string(key)) do
      {:ok, int2bool(value)}
    end
  end

  defp do_get_no_arg(db, key, _opts) when key in @returning_int or key in @returning_text do
    XqliteNIF.get_pragma(db, to_string(key))
  end

  defp do_get_no_arg(db, key, _opts) when key in @returning_list do
    with {:ok, rows} <- do_query(db, key) do
      {:ok, process_list_result(key, rows)}
    end
  end

  defp do_get_no_arg(db, key, _opts) when key in @returning_nothing do
    case XqliteNIF.get_pragma(db, to_string(key)) do
      {:ok, :no_value} -> :ok
      other -> other
    end
  end

  # Handler for PRAGMAs that take ONE argument.
  defp do_get_with_arg(db, key, arg, _opts) do
    with {:ok, rows} <- do_query(db, key, arg) do
      # All known PRAGMAs with an argument return a list.
      {:ok, process_list_result(key, rows)}
    end
  end

  defp do_query(db, key, arg \\ nil)

  defp do_query(db, key, nil) do
    db |> XqliteNIF.query("PRAGMA #{key};") |> query_to_pragma_result()
  end

  defp do_query(db, key, arg) do
    db |> XqliteNIF.query("PRAGMA #{key}(#{arg});") |> query_to_pragma_result()
  end

  defp process_list_result(key, rows) do
    # This logic can be refined later if needed, but for now it's a direct move.
    case key do
      :collation_list ->
        Enum.map(rows, fn [seq, name] -> %{seq: seq, name: name} end)

      :integrity_check ->
        values_only(rows)

      :quick_check ->
        values_only(rows)

      # For single-column results like `foreign_key_check`, `optimize`, etc.
      # this flattens [[v1], [v2]] to [v1, v2].
      _ when is_list(rows) and rows != [] and length(hd(rows)) == 1 ->
        values_only(rows)

      # Default for multi-column lists (table_info, foreign_key_list)
      _ ->
        rows
    end
  end

  defp map_special_int_to_atom(:auto_vacuum, value), do: get_auto_vacuum(value)
  defp map_special_int_to_atom(:secure_delete, value), do: get_secure_delete(value)
  defp map_special_int_to_atom(:synchronous, value), do: get_synchronous(value)
  defp map_special_int_to_atom(:temp_store, value), do: get_temp_store(value)

  @spec index_list(reference(), name(), pragma_opts()) :: pragma_result()
  def index_list(db, name, opts \\ []) do
    get(db, :index_list, name, opts)
  end

  @spec index_info(reference(), name(), pragma_opts()) :: pragma_result()
  def index_info(db, name, opts \\ []) do
    get(db, :index_info, name, opts)
  end

  @spec index_xinfo(reference(), name(), pragma_opts()) :: pragma_result()
  def index_xinfo(db, name, opts \\ []) do
    get(db, :index_xinfo, name, opts)
  end

  @spec table_info(reference(), name(), pragma_opts()) :: pragma_result()
  def table_info(db, name, opts \\ []) do
    get(db, :table_info, name, opts)
  end

  @spec table_xinfo(reference(), name(), pragma_opts()) :: pragma_result()
  def table_xinfo(db, name, opts \\ []) do
    get(db, :table_xinfo, name, opts)
  end

  @doc ~S"""
  Changes a PRAGMA's value.
  """
  @spec put(reference(), pragma_key(), pragma_value()) :: :ok | {:error, Xqlite.error()}
  def put(db, key, val) when is_atom(key) do
    do_put(db, key, val)
  end

  def put(db, key, val) when is_binary(key) do
    # We must convert to an atom to perform the validation lookup.
    # If the string doesn't convert to a known atom, the validation will
    # correctly pass it through to the NIF.
    do_put(db, String.to_atom(key), val)
  end

  defp do_put(db, key_atom, val) do
    if valid_pragma_value?(key_atom, val) do
      XqliteNIF.set_pragma(db, to_string(key_atom), val)
    else
      {:error, {:invalid_pragma_value, %{pragma: key_atom, value: val}}}
    end
  end

  # Pre-flight check for an invalid PRAGMA value. This is done because SQLite silently
  # ignores invalid values. We'd like to have some more loud failures.
  defp valid_pragma_value?(key, val) do
    spec = Map.get(@valid_write_arg_values, key)

    case {spec, val} do
      {nil, _any_val} ->
        # If we have no validation spec for this pragma, we assume it's valid
        # and let SQLite handle it. This prevents us from breaking on new/unknown pragmas.
        true

      {^spec, v} when is_boolean(v) ->
        # Handle boolean values. SQLite uses 0 for false, 1 for true.
        # This check is robust for any spec that is a Range (e.g., @bool, @i32).
        if(v, do: 1, else: 0) in spec

      {^spec, v} when is_list(spec) ->
        # Spec is a list of allowed values (e.g., ["NORMAL", "EXCLUSIVE"])
        v in spec

      {^spec, v} when is_struct(spec, Range) and is_integer(v) ->
        # Spec is a range of allowed integers (e.g., 0..2 or a signed range)
        v in spec

      # Catch-all for any other combination is considered invalid.
      _ ->
        false
    end
  end

  @spec get_auto_vacuum(auto_vacuum_key()) :: auto_vacuum_value()
  def get_auto_vacuum(0), do: :none
  def get_auto_vacuum(1), do: :full
  def get_auto_vacuum(2), do: :incremental

  @spec get_secure_delete(secure_delete_key()) :: secure_delete_value()
  def get_secure_delete(0), do: false
  def get_secure_delete(1), do: true
  def get_secure_delete(2), do: :fast

  @spec get_synchronous(synchronous_key()) :: synchronous_value()
  def get_synchronous(0), do: :off
  def get_synchronous(1), do: :normal
  def get_synchronous(2), do: :full
  def get_synchronous(3), do: :extra

  @spec get_temp_store(temp_store_key()) :: temp_store_value()
  def get_temp_store(0), do: :default
  def get_temp_store(1), do: :file
  def get_temp_store(2), do: :memory

  defp values_only(r) do
    r
    |> Enum.map(fn
      [{_k, v}] -> v
      [v] -> v
    end)
  end
end

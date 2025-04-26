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
    auto_vacuum: [r: {0, true, :int}, w: {true, :int, :nothing}],
    automatic_index: [r: {0, false, :bool}, w: {false, :bool, :nothing}],
    busy_timeout: [r: {0, false, :int}, w: {false, :int, :int}],
    cache_size: [r: {0, true, :int}, w: {true, :int, :nothing}],
    cache_spill: [r: {0, false, :int}, w: {false, :bool, :nothing}, w: {true, :int, :nothing}],
    case_sensitive_like: [w: {false, :bool, :nothing}],
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
  @u32 0..0x7FFFFFFF
  @nonzero_u32 1..0x7FFFFFFF
  @bool 0..1

  @valid_write_arg_values %{
    application_id: @i32,
    auto_vacuum: 0..2,
    automatic_index: @bool,
    busy_timeout: @u32,
    cache_size: @i32,
    cache_spill: @u32,
    case_sensitive_like: @bool,
    cell_size_check: @bool,
    checkpoint_fullfsync: @bool,
    defer_foreign_keys: @bool,
    encoding: ~w(UTF-8 UTF-16 UTF-16le UTF-16be),
    foreign_keys: @bool,
    fullfsync: @bool,
    hard_heap_limit: @u32,
    ignore_check_constraints: @bool,
    integrity_check: @nonzero_u32,
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
    user_version: @i32,
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
  A convenience wrapper to make the result of a `XqliteNIF.raw_query/3` call to
  a format that is required by the `result` processor function.
  Note that we deliberately assert strongly on the type of success value as
  any other would be a critical bug in this library.
  """
  def raw_query_to_pragma_result({:ok, map}) when is_map(map) do
    {:ok, Map.get(map, :rows)}
  end

  def raw_query_to_pragma_result({:error, _anything} = err), do: err

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

  def get(db, key, list, _opts) when is_list(list) do
    get0(db, key, list)
  end

  def get(db, key, arg, opts) when is_list(opts) do
    get1(db, key, arg, opts)
  end

  @spec get0(reference(), pragma_key(), pragma_opts()) :: pragma_get_result()
  defp get0(conn, key, _opts) do
    XqliteNIF.raw_query(conn, "PRAGMA #{key};")
    |> raw_query_to_pragma_result()
    |> result(key)
  end

  @spec get1(reference(), pragma_key(), pragma_key(), pragma_opts()) ::
          pragma_get_result()
  defp get1(conn, key, arg, opts) when is_atom(key) and is_atom(arg) do
    get1(conn, Atom.to_string(key), Atom.to_string(arg), opts)
  end

  defp get1(conn, key, arg, opts) when is_atom(key) and is_binary(arg) do
    get1(conn, Atom.to_string(key), arg, opts)
  end

  defp get1(conn, key, arg, opts) when is_binary(key) and is_atom(arg) do
    get1(conn, key, Atom.to_string(arg), opts)
  end

  defp get1(conn, key, arg, _opts) do
    XqliteNIF.raw_query(conn, "PRAGMA #{key}(#{arg});")
    |> raw_query_to_pragma_result()
    |> result(key)
  end

  @spec index_list(reference(), name(), pragma_opts()) :: pragma_result()
  def index_list(db, name, opts \\ []) do
    get1(db, "index_list", name, opts)
  end

  @spec index_info(reference(), name(), pragma_opts()) :: pragma_result()
  def index_info(db, name, opts \\ []) do
    get1(db, "index_info", name, opts)
  end

  @spec index_xinfo(reference(), name(), pragma_opts()) :: pragma_result()
  def index_xinfo(db, name, opts \\ []) do
    get1(db, "index_xinfo", name, opts)
  end

  @spec table_info(reference(), name(), pragma_opts()) :: pragma_result()
  def table_info(db, name, opts \\ []) do
    get1(db, "table_info", name, opts)
  end

  @spec table_xinfo(reference(), name(), pragma_opts()) :: pragma_result()
  def table_xinfo(db, name, opts \\ []) do
    get1(db, "table_xinfo", name, opts)
  end

  @doc ~S"""
  Changes a PRAGMA's value.
  """
  @spec put(reference(), pragma_key(), pragma_value()) :: pragma_result()
  def put(db, key, val) when is_atom(key) do
    put(db, Atom.to_string(key), val)
  end

  def put(db, key, val) when is_binary(key) do
    XqliteNIF.raw_pragma_write_and_read(db, key, val)
    |> result(key)
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

  @spec result(pragma_result(), pragma_key()) :: pragma_result()
  defp result({:error, _} = e, _k), do: e
  defp result({:error, _, _} = e, _k), do: e
  defp result({:ok, :no_value}, _k), do: :ok
  defp result({:ok, "ok"}, _k), do: :ok

  defp result({:ok, v}, _k) when is_integer(v) or is_float(v) or is_binary(v),
    do: {:ok, v}

  defp result({:ok, [[{k, v}]]}, k), do: {:ok, single(String.to_atom(k), v)}
  defp result({:ok, [[v]]}, k) when is_atom(k), do: {:ok, single(k, v)}
  defp result({:ok, [[v]]}, k) when is_binary(k), do: {:ok, single(String.to_atom(k), v)}
  defp result({:ok, vv}, k) when is_atom(k) and is_list(vv), do: {:ok, multiple(k, vv)}

  defp result({:ok, vv}, k) when is_binary(k) and is_list(vv),
    do: {:ok, multiple(String.to_atom(k), vv)}

  defp result(:ok, _k), do: :ok

  # Generate pragma getter functions that convert a 0/1 integer result to a boolean
  # or transform special integer values to atoms.
  @spec single(pragma_key(), pragma_result()) :: pragma_result()
  @returning_boolean
  |> Enum.each(fn key ->
    defp single(unquote(key), value) do
      int2bool(value)
    end
  end)

  defp single(:auto_vacuum, v), do: get_auto_vacuum(v)
  defp single(:secure_delete, v), do: get_secure_delete(v)
  defp single(:synchronous, v), do: get_synchronous(v)
  defp single(:temp_store, v), do: get_temp_store(v)
  defp single(_key, value), do: value

  @spec multiple(pragma_key(), pragma_result()) :: pragma_result()
  defp multiple(:collation_list, vv) do
    Enum.map(vv, fn
      [{"seq", i}, {"name", s}] -> [{:seq, i}, {:name, s}] |> Map.new()
      [i, s] -> Map.new([{i, s}])
    end)
  end

  defp multiple(:compile_options, vv), do: values_only(vv)
  defp multiple(:integrity_check, vv), do: values_only(vv)
  defp multiple(_, vv), do: vv

  defp values_only(r) do
    r
    |> Enum.map(fn
      [{_k, v}] -> v
      [v] -> v
    end)
  end
end

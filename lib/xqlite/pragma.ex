defmodule Xqlite.Pragma do
  @moduledoc ~S"""
  Deals with [Sqlite pragmas](https://www.sqlite.org/pragma.html).

  This module deliberately omits the PRAGMAs that are deprecated, or are used with non-standard
  sqlite compile options, or are intended for testing sqlite.
  """

  import Xqlite, only: [int2bool: 1]
  import Xqlite.Conn, only: [is_conn: 1]

  @doc """
  Given the contents of the `https://www.sqlite.org/pragma.html` URL passed to this
  function, retrieve a list of supported sqlite3 pragma names.
  """
  @spec extract_supported_pragmas(String.t()) :: [String.t()]
  def extract_supported_pragmas(html) when is_binary(html) do
    matches =
      html
      |> Floki.parse_document()
      |> Floki.find("/html/body/script")
      |> Enum.filter(fn {"script", [], texts} ->
        Enum.any?(texts, &Regex.match?(~r/\s*var\s*[a-zA-Z0-9_]+\s*=\s*\[\s*\{.+/misu, &1))
      end)

    case matches do
      [] ->
        []

      [{"script", [], texts}] ->
        text = Enum.join(texts, "\n")

        results =
          Regex.named_captures(
            ~r/\s*var\s*[a-zA-Z0-9_]+\s*=\s*(?<json>\[\s*\{.+\}\s*\])\s*;/misu,
            text
          )

        results
        |> Map.get("json")
        |> Jason.decode!()
        |> Enum.filter(fn
          # The pragmas with %{s: 0} are the ones that are recommended to be used;
          # the rest are either deprecated, used for debugging, or require special builds.
          %{"s" => 0, "u" => _, "x" => _} -> true
          _ -> false
        end)
        |> Enum.map(fn %{"s" => 0, "u" => _, "x" => name} -> name end)
    end
  end

  # --- Types.

  @type name :: String.t()
  @type pragma_opts :: keyword()
  @type pragma_key :: String.t() | atom()
  @type pragma_value :: String.t() | integer()
  @type pragma_result :: any()
  @type pragma_get_result :: {:ok, list()} | {:error, String.t()}
  @type pragma_arg_type :: :blob | :bool | :int | :list | :nothing | :real | :text
  @type auto_vacuum_key :: 1 | 2 | 3
  @type auto_vacuum_value :: :none | :full | :incremental
  @type secure_delete_key :: 0 | 1 | 2
  @type secure_delete_value :: true | false | :fast
  @type synchronous_key :: 0 | 1 | 2 | 3
  @type synchronous_value :: :off | :normal | :full | :extra
  @type temp_store_key :: 0 | 1 | 2
  @type temp_store_value :: :default | :file | :memory

  # --- Guards.

  defguard is_pragma_opts(x) when is_list(x)
  defguard is_pragma_key(x) when is_binary(x) or is_atom(x)
  defguard is_pragma_value(x) when is_binary(x) or is_atom(x) or is_integer(x) or is_boolean(x)

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
      r: {0, true, :text},
      r: {0, true, :list},
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
      r: {0, true, :text},
      r: {0, true, :list},
      r: {1, true, :int, :text},
      r: {1, true, :int, :list}
    ],
    read_uncommitted: [r: {0, false, :bool}, w: {false, :bool, :nothing}],
    recursive_triggers: [r: {0, false, :bool}, w: {false, :bool, :nothing}],
    reverse_unordered_selects: [r: {0, false, :bool}, w: {false, :bool, :nothing}],
    schema_version: [r: {0, true, :int}, w: {true, :int, :nothing}],
    secure_delete: [r: {0, true, :int}, w: {true, :int, :int}],
    shrink_memory: [r: {0, false, :nothing}],
    soft_heap_limit: [r: {0, false, :int}, w: {false, :int, :int}],
    stats: [r: {0, false, :list}],
    # Int and text can be passed as parameter when setting, query always returns int
    synchronous: [r: {0, true, :int}, w: {true, :int, :nothing}, w: {true, :text, :nothing}],
    table_info: [r: {1, true, :text, :list}],
    table_xinfo: [r: {1, true, :text, :list}],
    # Int and text can be passed as parameter when setting, query always returns int
    temp_store: [r: {0, false, :int}, w: {false, :int, :nothing}, w: {false, :text, :nothing}],
    temp_store_directory: [r: {0, false, :text}, w: {false, :text, :nothing}],
    threads: [r: {0, false, :int}, w: {false, :int, :int}],
    trusted_schema: [r: {0, false, :bool}, w: {false, :bool, :nothing}],
    user_version: [r: {0, true, :int}, w: {true, :int, :nothing}],
    wal_autocheckpoint: [r: {0, false, :int}, w: {false, :int, :int}],
    wal_checkpoint: [r: {0, true, :list}, r: {1, true, :text, :list}],
    writable_schema: [r: {0, false, :bool}, w: {false, :bool, :nothing}]
  }

  @readable_with_zero_params @schema
                             |> Stream.filter(fn {_name, kw} ->
                               kw
                               |> Keyword.get_values(:r)
                               |> Enum.any?(fn x -> match?({0, _, _}, x) end)
                             end)
                             |> Stream.map(fn {name, _kw} -> name end)
                             |> Enum.sort()

  @readable_with_one_param @schema
                           |> Stream.filter(fn {_name, kw} ->
                             kw
                             |> Keyword.get_values(:r)
                             |> Enum.any?(fn x -> match?({1, _, _, _}, x) end)
                           end)
                           |> Stream.map(fn {name, _kw} -> name end)
                           |> Enum.sort()

  @writable_with_one_param @schema
                           |> Stream.filter(fn {_name, kw} ->
                             kw
                             |> Keyword.has_key?(:w)
                           end)
                           |> Stream.map(fn {name, _kw} -> name end)
                           |> Enum.sort()

  @all @schema |> Map.keys() |> Enum.sort()

  @returning_boolean @schema
                     |> Stream.filter(fn {_name, kw} ->
                       kw
                       |> Enum.any?(fn
                         {:r, {0, _, :bool}} -> true
                         {:r, {1, _, _, :bool}} -> true
                         {:w, {_, _, :bool}} -> true
                         _ -> false
                       end)
                     end)
                     |> Stream.map(fn {name, _kw} -> name end)
                     |> Enum.sort()

  @doc ~S"""
  Returns a map with keys equal to all supported PRAGMAs, and the values being detailed
  machine description of the read/write modes of each PRAGMA (contains number of read
  parameters, read/write parameter types, whether a schema/database prefix is allowed,
  and the return type).
  """
  def schema(), do: @schema

  @doc ~S"""
  Returns the names of all PRAGMAs that are supported by this library.
  """
  def all(), do: @all

  @doc ~S"""
  Returns the names of all readable PRAGMAs that don't require parameters.
  """
  def readable_with_zero_params(), do: @readable_with_zero_params

  @doc ~S"""
  Returns the names of all readable PRAGMAs that require one parameter.
  """
  def readable_with_one_param(), do: @readable_with_one_param

  @doc ~S"""
  Returns the names of all writable PRAGMAs that require one parameter.
  """
  def writable_with_one_param(), do: @writable_with_one_param

  @doc ~S"""
  Returns the names of all pragmas, readable and writable, that are of boolean type.
  """
  def returning_boolean(), do: @returning_boolean

  @doc ~S"""
  Fetches a PRAGMA's value, optionally specifying an extra parameter:
  - `get(db, :auto_vacuum)` is a PRAGMA that does _not_ require an extra parameter.
  - `get(db, :table_info, :users)` is a PRAGMA that does require an extra parameter.

  The last parameter are options:
  - `:db_name` - must be a string. The values `"main"` and `"temp"` are treated specially,
    as in  instruct sqlite to use the main (originally opened) database or a temporary DB
    respectively. Any other value refers to a name of an ATTACH-ed database. This function
    will fail if there is no ATTACH-ed database with the specified name.
  """
  @spec get(Xqlite.Conn.conn(), pragma_key(), pragma_key() | pragma_opts(), pragma_opts()) ::
          pragma_get_result()
  def get(db, key, param_or_opts \\ [], opts \\ [])

  def get(db, key, param_or_opts, _opts)
      when is_conn(db) and is_pragma_key(key) and is_list(param_or_opts) do
    get0(db, key, param_or_opts)
  end

  def get(db, key, param_or_opts, opts)
      when is_conn(db) and is_pragma_key(key) and is_pragma_key(param_or_opts) and
             is_list(opts) do
    get1(db, key, param_or_opts, opts)
  end

  @spec get0(Xqlite.Conn.conn(), pragma_key(), pragma_opts()) :: pragma_get_result()
  defp get0(conn, key, opts) when is_conn(conn) and is_atom(key) and is_pragma_opts(opts) do
    get0(conn, Atom.to_string(key), opts)
  end

  defp get0(conn, key, opts) when is_conn(conn) and is_binary(key) and is_pragma_opts(opts) do
    XqliteNIF.pragma_get0(conn, key, opts)
    |> result(key)
  end

  @spec get1(Xqlite.Conn.conn(), pragma_key(), pragma_key(), pragma_opts()) ::
          pragma_get_result()
  defp get1(conn, key, param, opts)
       when is_conn(conn) and is_atom(key) and is_atom(param) and is_pragma_opts(opts) do
    get1(conn, Atom.to_string(key), Atom.to_string(param), opts)
  end

  defp get1(conn, key, param, opts)
       when is_conn(conn) and is_atom(key) and is_binary(param) and is_pragma_opts(opts) do
    get1(conn, Atom.to_string(key), param, opts)
  end

  defp get1(conn, key, param, opts)
       when is_conn(conn) and is_binary(key) and is_atom(param) and is_pragma_opts(opts) do
    get1(conn, key, Atom.to_string(param), opts)
  end

  defp get1(conn, key, param, opts)
       when is_conn(conn) and is_binary(key) and is_binary(param) and is_pragma_opts(opts) do
    XqliteNIF.pragma_get1(conn, key, param, opts)
    |> result(key)
  end

  @spec index_list(Xqlite.conn(), name(), pragma_opts()) :: pragma_result()
  def index_list(db, name, opts \\ [])
      when is_conn(db) and is_binary(name) and is_pragma_opts(opts) do
    get1(db, "index_list", name, opts)
  end

  @spec index_info(Xqlite.conn(), name(), pragma_opts()) :: pragma_result()
  def index_info(db, name, opts \\ [])
      when is_conn(db) and is_binary(name) and is_pragma_opts(opts) do
    get1(db, "index_info", name, opts)
  end

  @spec index_xinfo(Xqlite.conn(), name(), pragma_opts()) :: pragma_result()
  def index_xinfo(db, name, opts \\ [])
      when is_conn(db) and is_binary(name) and is_pragma_opts(opts) do
    get1(db, "index_xinfo", name, opts)
  end

  @spec table_info(Xqlite.conn(), name(), pragma_opts()) :: pragma_result()
  def table_info(db, name, opts \\ [])
      when is_conn(db) and is_binary(name) and is_pragma_opts(opts) do
    get1(db, "table_info", name, opts)
  end

  @spec table_xinfo(Xqlite.conn(), name(), pragma_opts()) :: pragma_result()
  def table_xinfo(db, name, opts \\ [])
      when is_conn(db) and is_binary(name) and is_pragma_opts(opts) do
    get1(db, "table_xinfo", name, opts)
  end

  @doc ~S"""
  Changes a PRAGMA's value.
  """
  @spec put(Xqlite.conn(), pragma_key(), pragma_value()) :: pragma_result()
  def put(db, key, val)
      when is_conn(db) and is_atom(key) and is_pragma_value(val) do
    put(db, Atom.to_string(key), val)
  end

  def put(db, key, val)
      when is_conn(db) and is_binary(key) and is_pragma_value(val) do
    XqliteNIF.pragma_put(db, key, val, [])
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
  defp result(:ok, _k), do: :ok
  defp result({:ok, [[{k, v}]]}, k), do: {:ok, single(String.to_atom(k), v)}
  defp result({:ok, vv}, k) when is_list(vv), do: {:ok, multiple(String.to_atom(k), vv)}

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
  defp multiple(:collation_list, vv),
    do: Enum.map(vv, fn [{"seq", i}, {"name", s}] -> [{:seq, i}, {:name, s}] |> Map.new() end)

  defp multiple(:compile_options, vv), do: values_only(vv)
  defp multiple(:integrity_check, vv), do: values_only(vv)
  defp multiple(_, vv), do: vv

  defp values_only(r), do: r |> Enum.map(fn [{_k, v}] -> v end)
end

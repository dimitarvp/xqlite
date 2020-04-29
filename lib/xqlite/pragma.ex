defmodule Xqlite.Pragma do
  @moduledoc ~S"""
  Deals with [Sqlite pragmas](https://www.sqlite.org/pragma.html).
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

  @supported_with_zero_params ~w(
    application_id
    auto_vacuum
    automatic_index
    busy_timeout
    cache_size
    cache_spill
    case_sensitive_like
    cell_size_check
    checkpoint_fullfsync
    collation_list
    compile_options
    data_version
    database_list
    defer_foreign_keys
    encoding
    foreign_key_check
    foreign_key_list
    foreign_keys
    freelist_count
    fullfsync
    function_list
    ignore_check_constraints
    incremental_vacuum
    index_info
    index_list
    index_xinfo
    integrity_check
    journal_mode
    journal_size_limit
    legacy_alter_table
    legacy_file_format
    locking_mode
    max_page_count
    mmap_size
    module_list
    optimize
    page_count
    page_size
    pragma_list
    query_only
    quick_check
    read_uncommitted
    recursive_triggers
    reverse_unordered_selects
    secure_delete
    shrink_memory
    soft_heap_limit
    synchronous
    table_info
    table_xinfo
    temp_store
    threads
    user_version
    wal_autocheckpoint
    wal_checkpoint
  )a

  @booleans ~w(
    automatic_index
    case_sensitive_like
    cell_size_check
    checkpoint_fullfsync
    defer_foreign_keys
    foreign_keys
    full_column_names
    fullfsync
    ignore_check_constraints
    legacy_alter_table
    legacy_file_format
    query_only
    read_uncommitted
    recursive_triggers
    reverse_unordered_selects
    writable_schema
  )a

  @doc ~S"""
  Returns all pragma keys except those that are deprecated, or are used with
  non-standard Sqlite compile options, or are intended for testing Sqlite.
  """
  def supported_with_zero_params(), do: @supported_with_zero_params

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

  @spec index_list(Xqlite.conn(), name(), name(), pragma_opts()) :: pragma_result()
  def index_list(db, schema, name, opts \\ [])
      when is_conn(db) and is_binary(schema) and is_binary(name) and is_pragma_opts(opts) do
    directive = maybe_prefix_with_schema(schema, "index_list")
    get1(db, directive, name, opts)
  end

  @spec index_info(Xqlite.conn(), name(), name(), pragma_opts()) :: pragma_result()
  def index_info(db, schema, name, opts \\ [])
      when is_conn(db) and is_binary(schema) and is_binary(name) and is_pragma_opts(opts) do
    directive = maybe_prefix_with_schema(schema, "index_info")
    get1(db, directive, name, opts)
  end

  @spec index_xinfo(Xqlite.conn(), name(), name(), pragma_opts()) :: pragma_result()
  def index_xinfo(db, schema, name, opts \\ [])
      when is_conn(db) and is_binary(schema) and is_binary(name) and is_pragma_opts(opts) do
    directive = maybe_prefix_with_schema(schema, "index_xinfo")
    get1(db, directive, name, opts)
  end

  @spec table_info(Xqlite.conn(), name(), name(), pragma_opts()) :: pragma_result()
  def table_info(db, schema, name, opts \\ [])
      when is_conn(db) and is_binary(schema) and is_binary(name) and is_pragma_opts(opts) do
    directive = maybe_prefix_with_schema(schema, "table_info")
    get1(db, directive, name, opts)
  end

  @spec table_xinfo(Xqlite.conn(), name(), name(), pragma_opts()) :: pragma_result()
  def table_xinfo(db, schema, name, opts \\ [])
      when is_conn(db) and is_binary(schema) and is_binary(name) and is_pragma_opts(opts) do
    directive = maybe_prefix_with_schema(schema, "table_xinfo")
    get1(db, directive, name, opts)
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

  @spec result(pragma_result(), pragma_key()) :: pragma_result()
  defp result({:error, _} = e, _k), do: e
  defp result({:error, _, _} = e, _k), do: e
  defp result(:ok, _k), do: :ok
  defp result({:ok, [[{k, v}]]}, k), do: {:ok, single(String.to_atom(k), v)}
  defp result({:ok, vv}, k) when is_list(vv), do: {:ok, multiple(String.to_atom(k), vv)}

  defp maybe_prefix_with_schema("", t) when is_binary(t), do: t
  defp maybe_prefix_with_schema(s, t) when is_binary(s) and is_binary(t), do: "'#{s}'.#{t}"

  # Generate pragma getter functions that convert a 0/1 integer result
  # to a boolean.
  @spec single(pragma_key(), pragma_result()) :: pragma_result()
  @booleans
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

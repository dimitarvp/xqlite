defmodule Xqlite.Pragma do
  @moduledoc ~S"""
  Deals with [Sqlite pragmas](https://www.sqlite.org/pragma.html).
  """

  import Xqlite, only: [int2bool: 1, is_conn: 1]

  @doc """
  Given the contents of the `https://www.sqlite.org/pragma.html` URL passed to this
  function, retrieve a list of supported sqlite3 pragma names.
  """
  @spec list_of_pragmas(String.t()) :: [String.t()]
  def list_of_pragmas(html) when is_binary(html) do
    matches =
      html
      |> Floki.parse()
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

  @type name :: String.t()
  @type pragma_key :: String.t() | atom()
  @type pragma_value :: String.t() | integer()
  @type pragma_result :: term()
  @type auto_vacuum_key :: 1 | 2 | 3
  @type auto_vacuum_value :: :none | :full | :incremental
  @type secure_delete_key :: 0 | 1 | 2
  @type secure_delete_value :: true | false | :fast
  @type synchronous_key :: 0 | 1 | 2 | 3
  @type synchronous_value :: :off | :normal | :full | :extra
  @type temp_store_key :: 0 | 1 | 2
  @type temp_store_value :: :default | :file | :memory

  @supported ~w(
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

  defguard is_pragma_key(x) when is_binary(x) or is_atom(x)
  defguard is_pragma_value(x) when is_binary(x) or is_atom(x) or is_integer(x) or is_boolean(x)

  @doc ~S"""
  Returns all pragma keys except those that are deprecated, or are used with
  non-standard Sqlite compile options, or are intended for testing Sqlite.
  """
  def supported(), do: @supported

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

  @spec raw(Xqlite.conn(), pragma_key()) :: pragma_result()
  def raw(db, key)
      when is_conn(db) and is_pragma_key(key) do
    Sqlitex.query!(db, "pragma #{key};")
  end

  @spec index_info(Xqlite.conn(), name(), name()) :: pragma_result()
  def index_info(db, schema, index_name)
      when is_conn(db) and is_binary(schema) and is_binary(index_name) do
    raw(db, "'#{schema}'.index_info('#{index_name}')")
  end

  @spec index_list(Xqlite.conn(), name(), name()) :: pragma_result()
  def index_list(db, schema, table_name)
      when is_conn(db) and is_binary(schema) and is_binary(table_name) do
    raw(db, "'#{schema}'.index_list('#{table_name}')")
  end

  @spec index_xinfo(Xqlite.conn(), name(), name()) :: pragma_result()
  def index_xinfo(db, schema, index_name)
      when is_conn(db) and is_binary(schema) and is_binary(index_name) do
    raw(db, "'#{schema}'.index_xinfo('#{index_name}')")
  end

  @spec table_info(Xqlite.conn(), name(), name()) :: pragma_result()
  def table_info(db, schema, table_name)
      when is_conn(db) and is_binary(schema) and is_binary(table_name) do
    raw(db, "'#{schema}'.table_info('#{table_name}')")
  end

  @spec table_xinfo(Xqlite.conn(), name(), name()) :: pragma_result()
  def table_xinfo(db, schema, table_name)
      when is_conn(db) and is_binary(schema) and is_binary(table_name) do
    raw(db, "'#{schema}'.table_xinfo('#{table_name}')")
  end

  @doc ~S"""
  Executes pragma (read or write).
  """
  @spec exec(Xqlite.conn(), pragma_key()) :: pragma_result()
  def exec(db, key)
      when is_conn(db) and is_pragma_key(key) do
    case raw(db, key) do
      [[{^key, value}]] ->
        sval(key, value)

      values when is_list(values) ->
        mval(key, values)
    end
  end

  @doc ~S"""
  Reads a pragma. Simple wrapper around `exec/2` without any attempt to sanitise input,
  provided just for code reading convenience. You can easily call this function like f.ex.
  `get(db, "secure_delete = fast")` and it will act exactly like
  `put(db, :secure_delete, "fast")`.
  """
  @spec get(Xqlite.conn(), pragma_key()) :: pragma_result()
  def get(db, key)
      when is_conn(db) and is_pragma_key(key) do
    exec(db, key)
  end

  @doc ~S"""
  Changes a pragma's value.
  """
  @spec put(Xqlite.conn(), pragma_key(), pragma_value()) :: pragma_result()
  def put(db, key, val)
      when is_conn(db) and is_pragma_key(key) and is_pragma_value(val) do
    exec(db, "#{key} = #{val}")
  end

  # Generate pragma getter functions that convert a 0/1 integer result
  # to a boolean.
  @spec sval(pragma_key(), pragma_result()) :: pragma_result()
  @booleans
  |> Enum.each(fn key ->
    def sval(unquote(key), value) do
      int2bool(value)
    end
  end)

  def sval(:auto_vacuum, v), do: get_auto_vacuum(v)
  def sval(:secure_delete, v), do: get_secure_delete(v)
  def sval(:synchronous, v), do: get_synchronous(v)
  def sval(:temp_store, v), do: get_temp_store(v)
  def sval(_key, value), do: value

  @spec mval(pragma_key(), pragma_result()) :: pragma_result()
  def mval(:compile_options, vv), do: values_only(vv)
  def mval(:integrity_check, vv), do: values_only(vv)
  def mval(_, vv), do: vv

  defp values_only(r), do: r |> Enum.map(fn [{_k, v}] -> v end)
end

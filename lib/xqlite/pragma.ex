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

  # ── Validation ranges ──────────────────────────────────────────────────

  @signed_i32 -2_147_483_648..0x7FFFFFFF
  @u32 0..0x7FFFFFFF
  @nonzero_u32 1..0x7FFFFFFF
  @bool 0..1

  # ── Schema ─────────────────────────────────────────────────────────────
  #
  # Each pragma is described by a %PragmaSpec{} struct that carries
  # everything needed for dispatch, validation, and post-processing:
  #
  #   return_type    – what GET returns (:int, :text, :bool, :list, :nothing)
  #   read_arities   – which arities support GET ([0], [1], [0, 1], [])
  #   schema_prefix  – whether PRAGMA db_name.pragma is allowed
  #   writable       – whether SET is supported
  #   valid_values   – pre-flight validation for SET (Range, list, or nil)
  #   int_mapping    – maps raw int GET results to atoms (%{0 => :none} etc.)

  @schema %{
    # ── Integer PRAGMAs ────────────────────────────────────────────────
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
      valid_values: @signed_i32
    },

    # ── Integer PRAGMAs with int→atom mapping ──────────────────────────
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

    # ── Boolean PRAGMAs ────────────────────────────────────────────────
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

    # ── Text PRAGMAs ──────────────────────────────────────────────────
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

    # ── List PRAGMAs ──────────────────────────────────────────────────
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

    # ── Nothing PRAGMAs ───────────────────────────────────────────────
    shrink_memory: %PragmaSpec{return_type: :nothing, read_arities: [0]}
  }

  # ── Derived module attributes ──────────────────────────────────────────

  @all @schema |> Map.keys() |> Enum.sort()

  @readable_with_zero_args @schema
                           |> Enum.filter(fn {_, s} -> 0 in s.read_arities end)
                           |> Enum.map(&elem(&1, 0))
                           |> Enum.sort()

  @readable_with_one_arg @schema
                         |> Enum.filter(fn {_, s} -> 1 in s.read_arities end)
                         |> Enum.map(&elem(&1, 0))
                         |> Enum.sort()

  @writable @schema
            |> Enum.filter(fn {_, s} -> s.writable end)
            |> Enum.map(&elem(&1, 0))
            |> Enum.sort()

  @returning_boolean @schema
                     |> Enum.filter(fn {_, s} -> s.return_type == :bool end)
                     |> Enum.map(&elem(&1, 0))
                     |> Enum.sort()

  @returning_int @schema
                 |> Enum.filter(fn {_, s} -> s.return_type == :int end)
                 |> Enum.map(&elem(&1, 0))
                 |> Enum.sort()

  @returning_text @schema
                  |> Enum.filter(fn {_, s} -> s.return_type == :text end)
                  |> Enum.map(&elem(&1, 0))
                  |> Enum.sort()

  @returning_list @schema
                  |> Enum.filter(fn {_, s} -> s.return_type == :list end)
                  |> Enum.map(&elem(&1, 0))
                  |> Enum.sort()

  @returning_nothing @schema
                     |> Enum.filter(fn {_, s} -> s.return_type == :nothing end)
                     |> Enum.map(&elem(&1, 0))
                     |> Enum.sort()

  @valid_write_arg_values @schema
                          |> Enum.filter(fn {_, s} -> s.writable and s.valid_values != nil end)
                          |> Map.new(fn {name, s} -> {name, s.valid_values} end)

  # ── Public schema query functions ──────────────────────────────────────

  @doc ~S"""
  Returns a map of all supported PRAGMAs keyed by name, with `%PragmaSpec{}`
  structs describing each PRAGMA's capabilities.
  """
  @spec schema() :: %{atom() => PragmaSpec.t()}
  def schema(), do: @schema

  @doc ~S"""
  Returns a map of writable PRAGMAs to their allowed value specs.
  """
  @spec valid_write_arg_values() :: %{atom() => Range.t() | list()}
  def valid_write_arg_values(), do: @valid_write_arg_values

  @doc "Returns the names of all PRAGMAs supported by this library."
  @spec all() :: [atom()]
  def all(), do: @all

  @doc "Returns the names of all readable PRAGMAs that don't require an argument."
  @spec readable_with_zero_args() :: [atom()]
  def readable_with_zero_args(), do: @readable_with_zero_args

  @doc "Returns the names of all readable PRAGMAs that require one argument."
  @spec readable_with_one_arg() :: [atom()]
  def readable_with_one_arg(), do: @readable_with_one_arg

  @doc "Returns the names of all writable PRAGMAs."
  @spec writable() :: [atom()]
  def writable(), do: @writable

  @doc "Returns the names of all pragmas that return a boolean."
  @spec returning_boolean() :: [atom()]
  def returning_boolean(), do: @returning_boolean

  @doc "Returns the names of all pragmas that return an integer."
  @spec returning_int() :: [atom()]
  def returning_int(), do: @returning_int

  @doc "Returns the names of all pragmas that return text."
  @spec returning_text() :: [atom()]
  def returning_text(), do: @returning_text

  @doc "Returns the names of all pragmas that return a list."
  @spec returning_list() :: [atom()]
  def returning_list(), do: @returning_list

  @doc "Returns the names of all pragmas that return nothing."
  @spec returning_nothing() :: [atom()]
  def returning_nothing(), do: @returning_nothing

  @doc ~S"""
  A convenience wrapper to extract the `:rows` from a successful `XqliteNIF.query/3` call.
  """
  @spec query_to_pragma_result({:ok, Xqlite.query_result()} | Xqlite.error()) ::
          list_result()
  def query_to_pragma_result({:ok, %{rows: rows}}), do: {:ok, rows}
  def query_to_pragma_result({:error, _} = err), do: err

  # ── GET ────────────────────────────────────────────────────────────────

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
    if key in @readable_with_one_arg do
      do_get_with_arg(db, key, arg_list, opts)
    else
      do_get_no_arg(db, key, arg_list ++ opts)
    end
  end

  # Unified dispatch: look up the spec struct, branch on its fields.
  defp do_get_no_arg(db, key, opts) do
    case Map.get(@schema, key) do
      nil -> {:error, {:unknown_pragma, key}}
      spec -> dispatch_get(db, key, spec, opts)
    end
  end

  # int_mapping takes priority (these pragmas have return_type: :int but
  # their raw integer result gets mapped to a descriptive atom).
  defp dispatch_get(db, key, %PragmaSpec{int_mapping: mapping}, opts)
       when is_map(mapping) do
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
    with {:ok, rows} <- do_query(db, key, arg, opts) do
      {:ok, process_list_result(key, rows)}
    end
  end

  # ── Convenience getters ────────────────────────────────────────────────

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

  # ── PUT ────────────────────────────────────────────────────────────────

  @doc ~S"""
  Changes a PRAGMA's value.

  ## Options

    * `:db_name` (string) - Target a specific attached database schema.
      `"main"` and `"temp"` are built-in; other values refer to ATTACH-ed databases.
  """
  @spec put(Xqlite.conn(), pragma_key(), pragma_value(), pragma_opts()) ::
          {:ok, term()} | Xqlite.error()
  def put(db, key, val, opts \\ [])

  def put(db, key, val, opts) when is_atom(key) do
    do_put(db, key, val, opts)
  end

  def put(db, key, val, opts) when is_binary(key) do
    do_put(db, String.to_existing_atom(key), val, opts)
  rescue
    ArgumentError -> {:error, {:invalid_pragma_name, key}}
  end

  defp do_put(db, key_atom, val, opts) do
    spec = Map.get(@schema, key_atom)

    if valid_pragma_value?(spec, val) do
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
    else
      {:error, {:invalid_pragma_value, %{pragma: key_atom, value: val}}}
    end
  end

  # ── Private helpers ────────────────────────────────────────────────────

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

  defp quote_name(name) do
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

  defp format_pragma_value(val) when is_binary(val), do: "'#{val}'"
  defp format_pragma_value(val) when is_integer(val), do: Integer.to_string(val)
  defp format_pragma_value(true), do: "1"
  defp format_pragma_value(false), do: "0"
  defp format_pragma_value(:on), do: "ON"
  defp format_pragma_value(:off), do: "OFF"
  defp format_pragma_value(val) when is_atom(val), do: Atom.to_string(val)

  # Validates a SET value against the spec. nil spec (unknown pragma) passes through.
  defp valid_pragma_value?(nil, _val), do: true
  defp valid_pragma_value?(%PragmaSpec{valid_values: nil}, _val), do: true

  defp valid_pragma_value?(%PragmaSpec{valid_values: spec}, val) when is_boolean(val) do
    if(val, do: 1, else: 0) in spec
  end

  defp valid_pragma_value?(%PragmaSpec{valid_values: spec}, val) when is_list(spec) do
    val in spec
  end

  defp valid_pragma_value?(%PragmaSpec{valid_values: spec}, val)
       when is_struct(spec, Range) and is_integer(val) do
    val in spec
  end

  defp valid_pragma_value?(_spec, _val), do: false

  @spec int2bool(0 | 1) :: boolean()
  defp int2bool(0), do: false
  defp int2bool(1), do: true
end

defmodule Xqlite.Config do
  @moduledoc ~S"""
  This module:
  - Defines a structure that contains a configuration for an sqlite connection.
  - Provides functions for reading from a keyword list of options, falling back
    to the defaults contained in this file.
  - Provides functions to modify a keyword list of options.
  """

  # Default is an anonymous in-memory database.
  @default_db_name ":memory:"

  # Default timeout for any Sqlite3 command, including opening and closing.
  @default_exec_timeout 5_000

  # Default size of the batch of records we will ask Sqlite3 to give us
  # when expecting large amounts of records to be returned.
  @default_batch_size 5_000

  # Default timeout for any `GenServer` commands to supervised Sqlite3 processes.
  @default_genserver_timeout 5_000

  @type text :: String.t() | charlist()
  @type db_name :: text()
  @type size :: pos_integer()
  @type opts :: keyword()
  @type key :: atom()
  @type value :: db_name() | size() | timeout()
  @type t :: %__MODULE__{batch_size: size(), db_name: text(), exec_timeout: timeout(), genserver_timeout: timeout()}

  defguard is_db_name(x) when is_list(x) or is_binary(x)
  defguard is_timeout(x) when (is_atom(x) and x == :infinity) or (is_integer(x) and x >= 0)
  defguard is_size(x) when is_integer(x) and x > 0
  defguard is_opts(x) when is_list(x)
  defguard is_key(x) when is_atom(x) and x in ~w(db_name batch_size exec_timeout genserver_timeout)a
  defguard is_value(x) when is_db_name(x) or is_timeout(x) or is_size(x)

  @spec default_batch_size() :: size()
  def default_batch_size(), do: @default_batch_size

  @spec default_db_name() :: db_name()
  def default_db_name(), do: @default_db_name

  @spec default_exec_timeout() :: timeout()
  def default_exec_timeout(), do: @default_exec_timeout

  @spec default_genserver_timeout() :: timeout()
  def default_genserver_timeout(), do: @default_genserver_timeout

  defstruct [
    batch_size: @default_batch_size,
    db_name: @default_db_name,
    exec_timeout: @default_exec_timeout,
    genserver_timeout: @default_genserver_timeout
  ]

  @spec default() :: t()
  def default(), do: %__MODULE__{}

  @spec get(opts(), key()) :: value()
  def get(opts, key) when is_opts(opts) and is_key(key) do
    Keyword.get(opts, key, Map.get(default(), key))
  end

  @spec get_batch_size(opts()) :: size()
  def get_batch_size(opts \\ []), do: get(opts, :batch_size)

  @spec get_db_name(opts()) :: db_name()
  def get_db_name(opts \\ []), do: get(opts, :db_name)

  @spec get_exec_timeout(opts()) :: timeout()
  def get_exec_timeout(opts \\ []), do: get(opts, :exec_timeout)

  @spec get_genserver_timeout(opts()) :: timeout()
  def get_genserver_timeout(opts \\ []), do: get(opts, :genserver_timeout)

  @spec put(opts(), key(), value()) :: opts()
  def put(opts, key, value) when is_opts(opts) and is_key(key) and is_value(value) do
    Keyword.put(opts, key, value)
  end

  @spec put_batch_size(opts(), size()) :: opts()
  def put_batch_size(opts, n) when is_opts(opts) and is_size(n) do
    put(opts, :batch_size, n)
  end

  @spec put_db_name(opts(), db_name()) :: opts()
  def put_db_name(opts, db_name) when is_opts(opts) and is_db_name(db_name) do
    put(opts, :db_name, db_name)
  end

  @spec put_exec_timeout(opts(), timeout()) :: opts()
  def put_exec_timeout(opts, t) when is_opts(opts) and is_timeout(t) do
    put(opts, :exec_timeout, t)
  end

  @spec put_genserver_timeout(opts(), timeout()) :: opts()
  def put_genserver_timeout(opts, t) when is_opts(opts) and is_timeout(t) do
    put(opts, :genserver_timeout, t)
  end
end

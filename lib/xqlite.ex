defmodule Xqlite do
  @moduledoc ~S"""
  This is the central module of this library. All sqlite operations can be
  performed from here.

  TODO: Add something more useful than a summary.
  """

  alias Xqlite.Config

  @type conn :: {:connection, reference(), reference()}
  @type open_result :: conn | {:error, term()}

  defguard is_conn(x)
           when is_tuple(x) and elem(x, 0) == :connection and is_reference(elem(x, 1)) and
                  (is_reference(elem(x, 2)) or is_binary(elem(x, 2)))

  @spec int2bool(0 | 1) :: true | false
  def int2bool(0), do: false
  def int2bool(1), do: true

  @spec open(Config.db_name(), keyword()) :: open_result()
  @doc """
  Opens a handle to an sqlite3 database.
  """
  def open(path, cfg \\ Config.default())

  def open(path, cfg) when is_binary(path), do: String.to_charlist(path) |> open(cfg)

  def open(path, cfg) when is_list(path) do
    :esqlite3.open(path, Config.get_exec_timeout(cfg))
  end

  @spec close(conn(), keyword()) :: :ok
  @doc """
  Closes the handle to the sqlite3 database.
  """
  def close(db, cfg \\ Config.default())

  def close(db, cfg) do
    :esqlite3.close(db, Config.get_exec_timeout(cfg))
  end
end

defmodule Xqlite do
  @moduledoc ~S"""
  This is the central module of this library. All sqlite operations can be
  performed from here.

  TODO: Add something more useful than a summary.
  """

  # --- Types.

  @type conn :: {:connection, reference(), reference()}
  @type opts :: keyword()
  @type db_name :: String.t() | charlist()
  @type driver :: module()
  @type open_result :: conn | {:error, any()}
  @type close_result :: :ok | {:error, any()}

  # --- Guards.

  defguard is_conn(x)
           when is_tuple(x) and elem(x, 0) == :connection and is_reference(elem(x, 1)) and
                  is_reference(elem(x, 2))

  defguard is_opts(x) when is_list(x)
  defguard is_db_name(x) when is_binary(x) or is_list(x)
  defguard is_driver(x) when is_atom(x)

  # --- Functions.

  def unnamed_memory_db(), do: ":memory:"

  @spec int2bool(0 | 1) :: true | false
  def int2bool(0), do: false
  def int2bool(1), do: true

  @spec open(db_name(), driver(), opts()) :: open_result()
  def open(db_name, driver \\ Xqlite.Esqlite3, opts \\ [])

  def open(db_name, driver, opts)
      when is_db_name(db_name) and is_driver(driver) and is_opts(opts) do
    driver.open(db_name, opts)
  end

  @spec close(conn(), driver(), opts()) :: close_result()
  def close(conn, driver \\ Xqlite.Esqlite3, opts \\ [])

  def close(conn, driver, opts) when is_conn(conn) and is_driver(driver) and is_opts(opts) do
    driver.close(conn, opts)
  end
end

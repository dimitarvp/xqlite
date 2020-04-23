defmodule Xqlite do
  @moduledoc ~S"""
  This is the central module of this library. All sqlite operations can be
  performed from here.

  TODO: Add something more useful than a summary.
  """

  # --- Types.

  @type conn :: {:connection, reference(), reference()}
  @type opts :: keyword()
  @type db_name :: String.t()
  @type open_result :: conn | {:error, any()}
  @type close_result :: :ok | {:error, any()}

  # --- Guards.

  defguard is_conn(x) when is_reference(x)
  defguard is_opts(x) when is_list(x)
  defguard is_db_name(x) when is_binary(x)

  # --- Functions.

  def unnamed_memory_db(), do: ":memory:"

  @spec int2bool(0 | 1) :: true | false
  def int2bool(0), do: false
  def int2bool(1), do: true

  @spec open(db_name(), opts()) :: open_result()
  def open(db_name, opts \\ [])

  def open(db_name, opts)
      when is_db_name(db_name) and is_opts(opts) do
    XqliteNIF.open(db_name, opts)
  end

  @spec close(conn()) :: close_result()
  def close(conn)

  def close(conn) when is_conn(conn) do
    XqliteNIF.close(conn)
  end
end

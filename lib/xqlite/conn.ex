defmodule Xqlite.Conn do
  @moduledoc ~S"""
  Functions dealing with an sqlite connection.
  """

  # --- Types.

  @type conn :: reference()
  @type db_name :: String.t()
  @type opts :: keyword()
  @type open_result :: {:ok, conn} | {:error, String.t()}
  @type close_result :: :ok | {:error, :cannot_close, String.t()} | {:error, :already_closed}

  # --- Guards.

  defguard is_conn(x) when is_reference(x)
  defguard is_conn_opts(x) when is_list(x)
  defguard is_db_name(x) when is_binary(x)

  # --- Functions.

  @spec open(db_name(), opts()) :: open_result()
  def open(db_name, opts \\ [])

  def open(db_name, opts)
      when is_db_name(db_name) and is_conn_opts(opts) do
    XqliteNIF.open(db_name, opts)
  end

  @spec close(conn()) :: close_result()
  def close(conn)

  def close(conn) when is_conn(conn) do
    XqliteNIF.close(conn)
  end
end

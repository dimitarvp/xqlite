defmodule Xqlite.Conn do
  @moduledoc false

  @type conn :: reference()
  @type db_name :: String.t()
  @type open_result :: {:ok, conn} | {:error, String.t()}
  @type close_result :: {:ok, true}

  defguard is_conn(x) when is_reference(x)
  defguard is_conn_opts(x) when is_list(x)
  defguard is_db_name(x) when is_binary(x)
end

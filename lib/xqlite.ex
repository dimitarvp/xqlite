defmodule Xqlite do
  @moduledoc ~S"""
  This is the central module of this library. All sqlite operations can be performed from here.
  Note that they delegate to other modules which you can also use directly.
  """

  def anon_db(), do: ":memory:"

  @spec int2bool(0 | 1) :: true | false
  def int2bool(0), do: false
  def int2bool(1), do: true

  @type conn :: reference()
  @type db_name :: String.t()
  @type opts :: keyword()
  @type open_result :: {:ok, conn} | {:error, String.t()}
  @type close_result :: {:ok, true}

  defguard is_conn(x) when is_reference(x)
  defguard is_conn_opts(x) when is_list(x)
  defguard is_db_name(x) when is_binary(x)
end

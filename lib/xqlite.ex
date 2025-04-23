defmodule Xqlite do
  @moduledoc ~S"""
  This is the central module of this library. All SQLite operations can be performed from here.
  Note that they delegate to other modules which you can also use directly.
  """

  @spec int2bool(0 | 1) :: true | false
  def int2bool(0), do: false
  def int2bool(1), do: true
end

defmodule Xqlite do
  @moduledoc ~S"""
  This is the central module of this library. All sqlite operations can be
  performed from here.

  TODO: Add something more useful than a summary.
  """

  @type conn :: {:connection, reference(), reference()}

  defguard is_conn(x)
           when is_tuple(x) and elem(x, 0) == :connection and is_reference(elem(x, 1)) and
                  (is_reference(elem(x, 2)) or is_binary(elem(x, 2)))

  @spec int2bool(0 | 1) :: true | false
  def int2bool(0), do: false
  def int2bool(1), do: true
end

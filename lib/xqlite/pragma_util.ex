defmodule Xqlite.PragmaUtil do
  @moduledoc ~S"""
  A module with zero dependencies on the rest of the modules in this library.
  Used to reduce boilerplate and slice and dice the pragmas collection (also used in tests).
  """

  @type name :: atom()
  @type spec :: keyword()
  @type arg_type :: :blob | :bool | :int | :list | :nothing | :real | :text
  @type pragma :: {name(), spec()}
  @type pragmas :: %{required(name()) => spec()}
  @type filter :: (pragma() -> boolean())

  defguard is_name(x) when is_atom(x)
  defguard is_spec(x) when is_list(x)
  defguard is_arg_type(x) when x in [:blob, :bool, :int, :list, :nothing, :real, :text]
  defguard is_pragma(x) when is_tuple(x) and is_name(elem(x, 0)) and is_spec(elem(x, 1))
  defguard is_pragmas(x) when is_map(x)
  defguard is_filter(x) when is_function(x, 1)

  @spec readable?(pragma()) :: boolean()
  def readable?({_n, s} = p) when is_pragma(p), do: Keyword.has_key?(s, :r)

  @spec readable_with_zero_args?(pragma()) :: boolean()
  def readable_with_zero_args?({_n, s} = p) when is_pragma(p) do
    s
    |> Keyword.get_values(:r)
    |> Enum.any?(fn x -> match?({0, _, _}, x) end)
  end

  @spec readable_with_one_arg?(pragma()) :: boolean()
  def readable_with_one_arg?({_n, s} = p) when is_pragma(p) do
    s
    |> Keyword.get_values(:r)
    |> Enum.any?(fn x -> match?({1, _, _, _}, x) end)
  end

  @spec writable?(pragma()) :: boolean()
  def writable?({_n, s} = p) when is_pragma(p), do: Keyword.has_key?(s, :w)

  @spec returns_type?(pragma(), arg_type()) :: boolean()
  def returns_type?({_n, s} = p, t) when is_pragma(p) and is_arg_type(t) do
    Enum.any?(s, fn
      {:r, {0, _, ^t}} -> true
      {:r, {1, _, _, ^t}} -> true
      {:w, {_, _, ^t}} -> true
      _ -> false
    end)
  end

  @spec of_type(pragmas(), arg_type()) :: [name()]
  def of_type(pragmas, type) when is_pragmas(pragmas) and is_arg_type(type) do
    filter(pragmas, fn pragma -> returns_type?(pragma, type) end)
  end

  @spec filter(pragmas(), filter()) :: [name()]
  def filter(pragmas, func) when is_pragmas(pragmas) and is_filter(func) do
    pragmas
    |> Stream.filter(fn pragma -> func.(pragma) end)
    |> Stream.map(fn {name, _spec} -> name end)
    |> Enum.sort()
  end
end

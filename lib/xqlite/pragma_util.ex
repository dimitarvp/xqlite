defmodule Xqlite.PragmaUtil do
  @moduledoc ~S"""
  A module with zero dependencies on the rest of the modules in this library.
  Used to reduce boilerplate and slice and dice the pragma collection.
  """

  @type name :: atom()
  @type spec :: keyword()
  @type arg_type :: :blob | :bool | :int | :list | :nothing | :real | :text
  @type pragma :: {name(), spec()}
  @type pragma_specs :: %{required(name()) => spec()}
  @type filter :: (pragma() -> boolean())

  defguard is_name(x) when is_atom(x)
  defguard is_spec(x) when is_list(x)
  defguard is_arg_type(x) when x in [:blob, :bool, :int, :list, :nothing, :real, :text]
  defguard is_pragma(x) when is_tuple(x) and is_name(elem(x, 0)) and is_spec(elem(x, 1))
  defguard is_pragma_specs(x) when is_map(x)
  defguard is_filter(x) when is_function(x, 1)

  @spec readable?(pragma()) :: boolean()
  def readable?({_name, spec} = pragma) when is_pragma(pragma), do: Keyword.has_key?(spec, :r)

  @spec readable_with_zero_args?(pragma()) :: boolean()
  def readable_with_zero_args?({_name, spec} = pragma) when is_pragma(pragma) do
    spec
    |> Keyword.get_values(:r)
    |> Enum.any?(fn pragma_return -> match?({0, _, _}, pragma_return) end)
  end

  @spec readable_with_one_arg?(pragma()) :: boolean()
  def readable_with_one_arg?({_name, spec} = pragma) when is_pragma(pragma) do
    spec
    |> Keyword.get_values(:r)
    |> Enum.any?(fn pragma_return -> match?({1, _, _, _}, pragma_return) end)
  end

  @spec writable?(pragma()) :: boolean()
  def writable?({_name, spec} = pragma) when is_pragma(pragma), do: Keyword.has_key?(spec, :w)

  @spec returns_type?(pragma(), arg_type()) :: boolean()
  def returns_type?({_name, spec} = pragma, type)
      when is_pragma(pragma) and is_arg_type(type) do
    Enum.any?(spec, fn
      {:r, {0, _, ^type}} -> true
      {:r, {1, _, _, ^type}} -> true
      {:w, {_, _, ^type}} -> true
      _ -> false
    end)
  end

  @spec of_type(pragma_specs(), arg_type()) :: [name()]
  def of_type(pragma_specs, type) when is_pragma_specs(pragma_specs) and is_arg_type(type) do
    filter(pragma_specs, fn pragma -> returns_type?(pragma, type) end)
  end

  @spec filter(pragma_specs(), filter()) :: [name()]
  def filter(pragma_specs, func) when is_pragma_specs(pragma_specs) and is_filter(func) do
    pragma_specs
    |> Stream.filter(fn pragma -> func.(pragma) end)
    |> Stream.map(fn {name, _spec} -> name end)
    |> Enum.sort()
  end
end

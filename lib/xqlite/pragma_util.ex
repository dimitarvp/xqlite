defmodule Xqlite.PragmaUtil do
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

  defdelegate writable_with_one_arg?(p), to: __MODULE__, as: :writable?

  @spec returns_type?(pragma(), arg_type()) :: boolean()
  def returns_type?({_n, s} = p, t) when is_pragma(p) and is_arg_type(t) do
    Enum.any?(s, fn
      {:r, {0, _, ^t}} -> true
      {:r, {1, _, _, ^t}} -> true
      {:w, {_, _, ^t}} -> true
      _ -> false
    end)
  end

  def returns_bool?(p) when is_pragma(p), do: returns_type?(p, :bool)
  def returns_int?(p) when is_pragma(p), do: returns_type?(p, :int)
  def returns_list?(p) when is_pragma(p), do: returns_type?(p, :list)
  def returns_text?(p) when is_pragma(p), do: returns_type?(p, :text)
  def returns_nothing?(p) when is_pragma(p), do: returns_type?(p, :nothing)

  @spec of_type(pragmas(), filter()) :: [atom()]
  def of_type(m, t) when is_pragmas(m) and is_arg_type(t) do
    filter(m, fn p -> returns_type?(p, t) end)
  end

  @spec filter(pragmas(), filter()) :: [atom()]
  def filter(m, f1) when is_pragmas(m) and is_filter(f1) do
    m
    |> Stream.filter(fn p -> f1.(p) end)
    |> Stream.map(fn {n, _s} -> n end)
    |> Enum.sort()
  end
end

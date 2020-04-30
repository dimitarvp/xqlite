defmodule Xqlite.Util do
  def readable_pragma_with_zero_args?({_name, kw}) when is_list(kw) do
    kw
    |> Keyword.get_values(:r)
    |> Enum.any?(fn x -> match?({0, _, _}, x) end)
  end

  def readable_pragma_with_one_arg?({_name, kw}) when is_list(kw) do
    kw
    |> Keyword.get_values(:r)
    |> Enum.any?(fn x -> match?({1, _, _, _}, x) end)
  end

  def writable_pragma_with_one_arg?({_name, kw}) when is_list(kw) do
    kw
    |> Keyword.has_key?(:w)
  end

  def pragmas_of_type(%{} = m, t) when is_atom(t) do
    m
    |> Stream.filter(fn {_name, kw} ->
      kw
      |> Enum.any?(fn
        {:r, {0, _, ^t}} -> true
        {:r, {1, _, _, ^t}} -> true
        {:w, {_, _, ^t}} -> true
        _ -> false
      end)
    end)
    |> Stream.map(fn {name, _kw} -> name end)
    |> Enum.sort()
  end

  def filter_pragmas(%{} = m, filter) when is_function(filter, 1) do
    m
    |> Stream.filter(fn {name, kw} -> filter.({name, kw}) end)
    |> Stream.map(fn {name, _kw} -> name end)
    |> Enum.sort()
  end
end

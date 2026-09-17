defmodule Xqlite.ReadmeCensusTest do
  @moduledoc """
  Every number the README counts is read back out of the code.

  The README states four counts — typed error reasons, constraint subtypes,
  typed and writable PRAGMAs, and built-in type extensions. Each of them
  drifts the moment a member is added, and a reader has no way to tell. This
  test extracts each number from the README's own sentence and compares it
  with the source it describes: the two unions through `Code.Typespec`, the
  two PRAGMA lists through `Xqlite.Pragma`, and the extension modules by
  parsing the files that define them.
  """

  use ExUnit.Case, async: true

  @number_words %{
    "one" => 1,
    "two" => 2,
    "three" => 3,
    "four" => 4,
    "five" => 5,
    "six" => 6,
    "seven" => 7,
    "eight" => 8,
    "nine" => 9,
    "ten" => 10,
    "eleven" => 11,
    "twelve" => 12,
    "thirteen" => 13,
    "fourteen" => 14,
    "fifteen" => 15,
    "sixteen" => 16,
    "seventeen" => 17,
    "eighteen" => 18,
    "nineteen" => 19,
    "twenty" => 20
  }

  test "the README's count of typed error reasons is the union's size" do
    assert [[_whole, stated]] =
             Regex.scan(~r/(\d+) typed reason variants/, readme())

    assert String.to_integer(stated) == length(union_members(:error_reason))
  end

  test "the README's count of constraint subtypes is the union minus its fallback" do
    assert [[_whole, stated]] =
             Regex.scan(
               ~r/including (\w+) SQLite constraint subtypes plus a generic fallback/,
               readme()
             )

    members = union_members(:constraint_kind)

    assert :constraint_violation in members
    assert Map.get(@number_words, stated) == length(members) - 1
  end

  test "the README's PRAGMA counts are the schema's size and its writable half" do
    assert [[_whole, typed, writable]] =
             Regex.scan(~r/validation for (\d+) PRAGMAs, (\d+) of them writable/, readme())

    assert String.to_integer(typed) == length(Xqlite.Pragma.all())
    assert String.to_integer(writable) == length(Xqlite.Pragma.writable())
  end

  test "the README's count of built-in type extensions is the number of modules" do
    assert [[_whole, stated]] =
             Regex.scan(~r|bidirectional encode/decode; (\w+) built in|, readme())

    assert Map.get(@number_words, stated) == length(extension_modules())
  end

  defp readme do
    assert {:ok, text} = File.read(Path.join([__DIR__, "..", "README.md"]))
    String.replace(text, "\r\n", "\n")
  end

  defp union_members(name) do
    assert {:ok, types} = Code.Typespec.fetch_types(Xqlite)
    assert {:type, {^name, form, []}} = Enum.find(types, &named?(&1, name))
    assert {:type, _line, :union, alternatives} = form
    Enum.map(alternatives, &member_name/1)
  end

  defp named?({:type, {name, _form, _args}}, name), do: true
  defp named?(_entry, _name), do: false

  defp member_name({:atom, _line, value}), do: value
  defp member_name(other), do: other

  defp extension_modules do
    [__DIR__, "..", "lib", "xqlite", "type_extension", "*.ex"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.flat_map(&modules_in/1)
  end

  defp modules_in(path) do
    with {:ok, source} <- File.read(path),
         {:ok, ast} <- Code.string_to_quoted(source) do
      {_ast, names} = Macro.prewalk(ast, [], &collect_module/2)
      names
    else
      _other -> []
    end
  end

  defp collect_module(
         {:defmodule, _meta,
          [{:__aliases__, _alias_meta, [:Xqlite, :TypeExtension, name]} | _]} = node,
         acc
       ), do: {node, [name | acc]}

  defp collect_module(node, acc), do: {node, acc}
end

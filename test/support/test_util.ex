defmodule Xqlite.TestUtil do
  alias XqliteNIF, as: NIF

  # A list of: an ExUnit tag, a `describe` block prefix, and a MFA to open a connection.
  # This data structure is used to generate tests for different DB types.
  @connection_openers [
    {:memory_private, "Private In-memory DB", {NIF, :open_in_memory, []}},
    {:file_temp, "Temporary Disk DB", {NIF, :open_temporary, []}}
  ]

  @tag_to_mfa_map Map.new(@connection_openers, fn {tag, _prefix, mfa} -> {tag, mfa} end)

  @doc """
  Returns a list of connection opener strategies for test generation.
  Each element is `{ex_unit_tag, description_prefix, opener_mfa}`.
  """
  def connection_openers(), do: @connection_openers

  @doc """
  Looks up the opener MFA tuple for a given type tag atom.
  """
  def opener_mfa_for_tag(type_tag) when is_atom(type_tag) do
    Map.fetch!(@tag_to_mfa_map, type_tag)
  end
end

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

  @doc """
  Finds the specific test tag atom (e.g., `:memory_private`, `:file_temp`)
  that will be added to the ExUnit context via `@describetag`.

  ExUnit adds the tag atom as a key with a boolean value (`true`) directly
  into the context map for tests within the tagged `describe` block.
  """
  def find_test_tag!(context) when is_map(context) do
    # Get the list of known tags from our connection openers definition
    known_tags = Enum.map(connection_openers(), fn {tag, _, _} -> tag end)

    # Find the first known tag that exists as a key in the context map
    found_tag = Enum.find(known_tags, fn tag -> Map.has_key?(context, tag) end)

    # Raise an error if no known tag is found in the context (should not happen)
    unless found_tag do
      raise """
      Could not determine current test tag from context.
      Expected one of #{inspect(known_tags)} to be a key in context map.
      Context: #{inspect(context)}
      """
    end

    found_tag
  end
end

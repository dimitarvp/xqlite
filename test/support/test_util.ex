defmodule Xqlite.TestUtil do
  alias XqliteNIF, as: NIF

  # A list of: an ExUnit tag, a `describe` block prefix, and a MFA to open a connection.
  # This data structure is used to generate tests for different DB types.
  @connection_openers [
    {:memory_private, "private in-memory DB", {NIF, :open_in_memory, []}},
    {:file_temp, "temporary file DB", {NIF, :open_temporary, []}}
  ]

  @tag_to_mfa_map Map.new(@connection_openers, fn {tag, _prefix, mfa} -> {tag, mfa} end)

  @doc """
  Returns a list of connection opener strategies for test generation.
  Each element is `{ex_unit_tag, description_prefix, opener_mfa}`.
  """
  def connection_openers(), do: @connection_openers

  @doc """
  Finds the opener MFA tuple based on the tag present in the ExUnit context map.

  Raises an error if a known tag key isn't found in the context.
  """
  def find_opener_mfa!(context) when is_map(context) do
    # Find the first known tag that exists as a key in the context map
    # Get known tags from the source map keys directly
    found_tag = Enum.find(Map.keys(@tag_to_mfa_map), fn tag -> Map.has_key?(context, tag) end)

    # Raise an error if no known tag is found in the context
    unless found_tag do
      raise """
      Could not determine current test tag from context needed to find opener MFA.
      Expected one of #{inspect(Map.keys(@tag_to_mfa_map))} to be a key in context map.
      Context: #{inspect(context)}
      """
    end

    # Lookup and return the MFA using the found tag
    Map.fetch!(@tag_to_mfa_map, found_tag)
  end
end

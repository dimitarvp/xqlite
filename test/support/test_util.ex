defmodule Xqlite.TestUtil do
  alias XqliteNIF, as: NIF

  # A list of: an ExUnit tag, a `describe` block prefix, and a MFA to open a connection.
  # This data structure is used to generate tests for different DB types.
  @connection_openers [
    {:memory_private, "private in-memory DB", {__MODULE__, :open_in_memory, []}},
    {:file_temp, "temporary file DB", {__MODULE__, :open_temporary, []}}
  ]

  @tag_to_mfa_map Map.new(@connection_openers, fn {tag, _prefix, mfa} -> {tag, mfa} end)

  defp open_with_retries(opener_fun, retries_left \\ 10)

  # Base case: no retries left, return the last error.
  defp open_with_retries(_opener_fun, 0) do
    {:error, :ci_setup_failed_after_retries}
  end

  defp open_with_retries(opener_fun, retries_left) do
    # `opener_fun` will be `&NIF.open_in_memory/0` or `&NIF.open_temporary/0`
    case opener_fun.() do
      {:ok, conn} ->
        # Connection opened successfully. Now try to configure it.
        # If PRAGMAs fail, we will treat it as a setup failure and retry.
        with :ok <- NIF.set_pragma(conn, "journal_mode", "DELETE"),
             :ok <- NIF.set_pragma(conn, "foreign_keys", true) do
          # Everything succeeded.
          {:ok, conn}
        else
          _error ->
            # Closing the connection and retrying is the safest path.
            NIF.close(conn)
            # Wait a bit before retrying
            Process.sleep(1000)
            open_with_retries(opener_fun, retries_left - 1)
        end

      {:error, _reason} ->
        # The initial open call failed. Wait and retry.
        Process.sleep(1000)
        open_with_retries(opener_fun, retries_left - 1)
    end
  end

  def open_in_memory(), do: open_with_retries(&NIF.open_in_memory/0)
  def open_temporary(), do: open_with_retries(&NIF.open_temporary/0)

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

  def normalize_test_values(values) do
    Enum.map(values, fn
      {set, expected} -> {set, expected}
      value -> {value, value}
    end)
  end

  def default_verify_values(_context, _set_val, fetched_val, expected_val) do
    fetched_val in List.wrap(expected_val)
  end

  def verify_is_integer(_context, _set_val, fetched_val, _expected_val),
    do: is_integer(fetched_val)

  def verify_is_atom(_context, _set_val, fetched_val, _expected_val), do: is_atom(fetched_val)
  def verify_is_ok_atom(_context, _set_val, fetched_val, _expected_val), do: fetched_val == :ok

  def verify_mmap_size_value(:memory_private, _set_val, actual, _expected_val),
    do: actual == :no_value

  def verify_mmap_size_value(:file_temp, _set_val, actual, _expected_val) do
    is_integer(actual) or actual == :no_value
  end
end

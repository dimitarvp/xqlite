defmodule Xqlite.TestUtil do
  alias XqliteNIF, as: NIF
  require Logger

  # A list of: an ExUnit tag, a `describe` block prefix, and a MFA to open a connection.
  # This data structure is used to generate tests for different DB types.
  @connection_openers [
    {:memory_private, "private in-memory DB", {__MODULE__, :open_in_memory, []}},
    {:file_temp, "temporary file DB", {__MODULE__, :open_temporary, []}}
  ]

  @tag_to_mfa_map Map.new(@connection_openers, fn {tag, _prefix, mfa} -> {tag, mfa} end)

  # Renamed for clarity, as it now does more than just retry opening.
  defp open_and_configure(opener_fun, retries_left \\ 5)

  # Base case: no retries left, return the last error.
  defp open_and_configure(_opener_fun, 0) do
    {:error, :ci_setup_failed_after_retries}
  end

  defp open_and_configure(opener_fun, retries_left) do
    case opener_fun.() do
      {:ok, conn} ->
        # Connection opened successfully. Now try to configure it.
        configure_connection(conn)

      # The initial open call failed. Wait and retry.
      {:error, _reason} ->
        Process.sleep(250)
        open_and_configure(opener_fun, retries_left - 1)
    end
  end

  # Helper to configure an already open connection.
  # It handles the specific CI "out of memory" error gracefully.
  defp configure_connection(conn) do
    with :ok <- set_pragma_with_oom_check(conn, "journal_mode", "DELETE"),
         :ok <- set_pragma_with_oom_check(conn, "foreign_keys", true) do
      # Both PRAGMAs succeeded (or were gracefully skipped).
      {:ok, conn}
    else
      # A non-OOM error occurred during PRAGMA setting. This is unexpected.
      # We could retry the whole process, but for now, let's treat it as a setup failure.
      # This path should not be hit if only the known OOM error occurs.
      {:error, :pragma_setup_failed} = error ->
        NIF.close(conn)
        error
    end
  end

  # This is the core of the new strategy.
  defp set_pragma_with_oom_check(conn, name, value) do
    case NIF.set_pragma(conn, name, value) do
      :ok ->
        :ok

      {:error, {:cannot_execute_pragma, _, reason}} = error ->
        if String.contains?(reason, "out of memory") do
          Logger.warning(
            "CI: PRAGMA #{name}=#{value} failed with 'out of memory'. Proceeding without it."
          )

          # Gracefully skip this error and return :ok to proceed.
          :ok
        else
          # It was a different, unexpected PRAGMA error.
          Logger.error(
            "CI: PRAGMA #{name}=#{value} failed with unexpected error: #{inspect(error)}"
          )

          # Propagate as a hard error.
          {:error, :pragma_setup_failed}
        end

      {:error, _reason} = error ->
        # Any other error shape is also a hard failure.
        Logger.error(
          "CI: PRAGMA #{name}=#{value} failed with unexpected error: #{inspect(error)}"
        )

        {:error, :pragma_setup_failed}
    end
  end

  def open_in_memory(), do: open_and_configure(&NIF.open_in_memory/0)
  def open_temporary(), do: open_and_configure(&NIF.open_temporary/0)

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

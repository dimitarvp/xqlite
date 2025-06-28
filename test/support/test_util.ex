defmodule Xqlite.TestUtil do
  alias XqliteNIF, as: NIF
  require Logger

  @connection_openers [
    {:memory_private, "private in-memory DB", {__MODULE__, :open_in_memory, []}},
    {:file_temp, "temporary file DB", {__MODULE__, :open_temporary, []}}
  ]

  @tag_to_mfa_map Map.new(@connection_openers, fn {tag, _prefix, mfa} -> {tag, mfa} end)

  defp open_and_configure(opener_fun, retries_left \\ 3) do
    if retries_left <= 0 do
      {:error, :ci_setup_failed_after_retries}
    else
      case opener_fun.() do
        {:ok, conn} ->
          configure_connection(conn, opener_fun, retries_left - 1)

        {:error, _reason} ->
          Process.sleep(250)
          open_and_configure(opener_fun, retries_left - 1)
      end
    end
  end

  defp configure_connection(conn, opener_fun, retries_left) do
    with :ok <- set_pragma_with_oom_check(conn, "journal_mode", "DELETE"),
         :ok <- set_pragma_with_oom_check(conn, "foreign_keys", true) do
      {:ok, conn}
    else
      # A non-OOM error occurred. This is unexpected. Retry the whole process.
      {:error, :pragma_setup_failed} ->
        NIF.close(conn)
        Process.sleep(250)
        open_and_configure(opener_fun, retries_left)
    end
  end

  defp set_pragma_with_oom_check(conn, name, value) do
    case NIF.set_pragma(conn, name, value) do
      :ok ->
        :ok

      {:error, {:cannot_execute_pragma, _, reason}} = error ->
        if String.contains?(reason, "out of memory") do
          Logger.warning(
            "[Xqlite TestUtil] PRAGMA #{name}=#{value} failed with 'out of memory'. Proceeding without it for this test."
          )

          # Gracefully skip this specific, known CI error.
          :ok
        else
          Logger.error(
            "[Xqlite TestUtil] PRAGMA #{name}=#{value} failed with unexpected error: #{inspect(error)}"
          )

          # Propagate any other error as a hard failure.
          {:error, :pragma_setup_failed}
        end

      {:error, _reason} = error ->
        Logger.error(
          "[Xqlite TestUtil] PRAGMA #{name}=#{value} failed with unexpected error shape: #{inspect(error)}"
        )

        {:error, :pragma_setup_failed}
    end
  end

  def open_in_memory(), do: open_and_configure(&NIF.open_in_memory/0)
  def open_temporary(), do: open_and_configure(&NIF.open_temporary/0)

  def connection_openers(), do: @connection_openers

  def find_opener_mfa!(context) when is_map(context) do
    found_tag = Enum.find(Map.keys(@tag_to_mfa_map), &Map.has_key?(context, &1))

    unless found_tag do
      raise """
      Could not determine current test tag from context needed to find opener MFA.
      Expected one of #{inspect(Map.keys(@tag_to_mfa_map))} to be a key in context map.
      Context: #{inspect(context)}
      """
    end

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

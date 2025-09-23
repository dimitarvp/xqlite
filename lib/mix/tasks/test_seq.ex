# lib/mix/tasks/test_seq.ex
defmodule Mix.Tasks.Test.Seq do
  use Mix.Task

  @shortdoc "Run tests sequentially, one file at a time"

  def run(args) do
    test_files = find_test_files()

    IO.puts("Found #{length(test_files)} test files")
    IO.puts("Running tests sequentially...")

    failed_files = run_test_files(test_files, args, [])

    if failed_files != [] do
      IO.puts("\nFailed files: #{Enum.join(failed_files, ", ")}")
      System.halt(1)
    else
      IO.puts("\n✓ All tests passed!")
    end
  end

  defp run_test_files([], _args, failed_files), do: failed_files

  defp run_test_files([file | rest], args, failed_files) do
    IO.puts("\n=== Running #{file} ===")

    # Use a different task name to avoid infinite recursion
    case System.cmd("mix", ["test", file] ++ args, into: IO.stream()) do
      {_, 0} ->
        IO.puts("✓ #{file} passed")
        run_test_files(rest, args, failed_files)

      {_, exit_code} ->
        IO.puts("✗ #{file} failed (exit code: #{exit_code})")
        run_test_files(rest, args, [file | failed_files])
    end
  end

  defp find_test_files do
    Path.wildcard("test/**/*_test.exs")
    |> Enum.sort()
  end
end

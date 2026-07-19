defmodule Mix.Tasks.Test.Seq do
  @shortdoc "Run tests sequentially, one file at a time"

  @moduledoc """
  Runs all test files sequentially, each in its own OS process.

  This avoids SQLite's global VFS contention that causes spurious
  "out of memory" errors when test files run in parallel.

  Every file runs with warnings-as-errors: the `:test` alias in
  `mix.exs` adds `--warnings-as-errors` to each child `mix test`
  invocation, so test-file compilation warnings fail that file's run.
  `elixirc_options` only gates `lib/` — test `.exs` files compile at
  test time, so the alias is the only place they can be enforced.

  ## Usage

      mix test.seq
      mix test.seq --trace
      mix test.seq --cover   # per-file .coverdata exports under cover/

  With `--cover`, each file's OS process exports a distinctly named
  `.coverdata` (derived from the file path), so runs don't overwrite
  each other. Merge and publish afterwards, e.g.
  `mix coveralls.github --import-cover cover test/xqlite_test.exs`.
  """

  use Mix.Task

  def run(args) do
    test_files = find_test_files()

    IO.puts("Found #{length(test_files)} test files")
    IO.puts("Running tests sequentially...")

    failed_files = run_test_files(test_files, args, [])

    if failed_files == [] do
      IO.puts("\n✓ All tests passed!")
    else
      IO.puts("\nFailed files: #{Enum.join(failed_files, ", ")}")
      Mix.raise("#{length(failed_files)} test file(s) failed")
    end
  end

  defp run_test_files([], _args, failed_files), do: failed_files

  defp run_test_files([file | rest], args, failed_files) do
    IO.puts("\n=== Running #{file} ===")

    case System.cmd("mix", ["test", file] ++ args ++ coverage_args(args, file),
           into: IO.stream()
         ) do
      {_, 0} ->
        IO.puts("✓ #{file} passed")
        run_test_files(rest, args, failed_files)

      {_, exit_code} ->
        IO.puts("✗ #{file} failed (exit code: #{exit_code})")
        run_test_files(rest, args, [file | failed_files])
    end
  end

  # Distinct export names per file (full-path-derived — bare basenames
  # collide, e.g. test/pragma_test.exs vs test/nif/pragma_test.exs).
  defp coverage_args(args, file) do
    if "--cover" in args do
      ["--export-coverage", String.replace(Path.rootname(file), ["/", "\\"], "_")]
    else
      []
    end
  end

  defp find_test_files do
    Path.wildcard("test/**/*_test.exs")
    |> Enum.sort()
  end
end

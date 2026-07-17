defmodule Mix.Tasks.Verify do
  @shortdoc "Run all CI checks locally before committing"

  @moduledoc """
  Runs all checks that CI will enforce, in fast-to-slow order.

  Stops on the first failure. Designed to be run before every commit
  to avoid pushing code that will fail CI.

  ## Steps

  1. Elixir formatting (`mix format --check-formatted`)
  2. Rust formatting (`cargo fmt --check`)
  3. Elixir compilation with warnings as errors
  4. Dependency vulnerability audit (`mix deps.audit`)
  5. Sobelow static security analysis (`mix sobelow`)
  6. Rust clippy with denied warnings
  7. Rust unit tests (`cargo test`)
  8. Dialyzer type checks
  9. Full Elixir test suite (`mix test.seq`)

  ## Usage

      mix verify
  """

  use Mix.Task

  @cargo_dir "native/xqlitenif"

  # GHSA-rhv4-8758-jx7v: decimal < 3.0 unbounded-exponent DoS. decimal 3.x
  # is unreachable while jason 1.4 constrains it to `~> 1.0 or ~> 2.0`;
  # xqlite's Decimal type extension is encode-only (decode is :skip), so
  # the vulnerable parse path never sees database input. Remove when jason
  # allows decimal 3 (or the JSON extension moves to core JSON).
  @ignored_advisories "GHSA-rhv4-8758-jx7v"

  @steps [
    {"Elixir formatting", &__MODULE__.check_elixir_format/0},
    {"Rust formatting", &__MODULE__.check_rust_format/0},
    {"Elixir compilation (warnings as errors)", &__MODULE__.check_elixir_compile/0},
    {"Dependency audit", &__MODULE__.check_deps_audit/0},
    {"Sobelow static analysis", &__MODULE__.check_sobelow/0},
    {"Rust clippy", &__MODULE__.check_rust_clippy/0},
    {"Rust tests", &__MODULE__.check_rust_tests/0},
    {"Dialyzer", &__MODULE__.check_dialyzer/0},
    {"Elixir tests", &__MODULE__.check_tests/0}
  ]

  def run(_args) do
    total = length(@steps)

    result =
      @steps
      |> Enum.with_index(1)
      |> Enum.reduce_while(:ok, fn {{label, check_fn}, idx}, :ok ->
        IO.puts("\n[#{idx}/#{total}] #{label}")

        case check_fn.() do
          :ok ->
            IO.puts("  ✓ passed")
            {:cont, :ok}

          {:error, exit_code} ->
            IO.puts("  ✗ failed (exit code: #{exit_code})")
            {:halt, {:error, label}}
        end
      end)

    case result do
      :ok ->
        IO.puts("\n✓ All checks passed. Safe to commit.")

      {:error, failed_step} ->
        Mix.raise("verify failed at: #{failed_step}")
    end
  end

  def check_elixir_format do
    run_cmd("mix", ["format", "--check-formatted"])
  end

  def check_rust_format do
    run_cargo(["fmt", "--", "--check"])
  end

  def check_elixir_compile do
    run_cmd("mix", ["compile", "--warnings-as-errors"])
  end

  def check_deps_audit do
    run_cmd("mix", ["deps.audit", "--ignore-advisory-ids", @ignored_advisories])
  end

  def check_sobelow do
    run_cmd("mix", ["sobelow", "--exit", "low"])
  end

  def check_rust_clippy do
    run_cargo(["clippy", "--", "-D", "warnings"])
  end

  def check_rust_tests do
    run_cargo(["test"])
  end

  def check_dialyzer do
    run_cmd("mix", ["dialyzer"])
  end

  def check_tests do
    run_cmd("mix", ["test.seq"])
  end

  defp run_cmd(cmd, args) do
    case System.cmd(cmd, args, into: IO.stream(), stderr_to_stdout: true) do
      {_, 0} -> :ok
      {_, exit_code} -> {:error, exit_code}
    end
  end

  # All cargo commands run with cwd set to the crate directory so that the
  # crate's `.cargo/config.toml` is picked up (e.g., `LIBSQLITE3_FLAGS` for
  # `SQLITE_ENABLE_STMT_SCANSTATUS`). Cargo walks up from cwd to find the
  # config; invoking via `--manifest-path` from the repo root does not.
  defp run_cargo(args) do
    case System.cmd("cargo", args, cd: @cargo_dir, into: IO.stream(), stderr_to_stdout: true) do
      {_, 0} -> :ok
      {_, exit_code} -> {:error, exit_code}
    end
  end
end

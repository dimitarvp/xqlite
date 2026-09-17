defmodule Xqlite.PanicStrategyScriptTest do
  @moduledoc """
  `scripts/panic_strategy.exs` reads the libraries it is handed and says
  whether a Rust panic in them unwinds. rustler turns a panic into a
  catchable `:nif_panicked` only while panics unwind, so a build that aborts
  instead takes the whole virtual machine down with it.

  The script judges what it is given rather than looking around for a
  library, and it fails when it cannot read symbols at all: a check that
  passes without having checked anything is worse than no check.
  """

  use ExUnit.Case, async: true

  @script "scripts/panic_strategy.exs"

  test "no argument at all is a usage error" do
    assert {output, 2} = run([])
    assert output =~ @script
  end

  test "a path that is not a file fails" do
    missing = Path.join(System.tmp_dir!(), "xqlite_no_such_library.so")
    refute File.exists?(missing)

    assert {output, 1} = run([missing])
    assert output =~ missing
  end

  test "the library the virtual machine loaded passes, and is named" do
    library = loaded_library()

    assert {output, 0} = run([library])
    assert output =~ library
  end

  test "a symbol tool that is not on the machine fails the check" do
    env = [{"XQLITE_SYMBOL_TOOL", "xqlite_no_such_symbol_tool"}]

    assert {output, 1} = run([loaded_library()], env)
    assert output =~ "nm"
    assert output =~ "llvm-nm"
    assert output =~ "rustup component add llvm-tools"
  end

  # A .dll is read through its import table rather than its symbol table, so
  # its family names its own tools when none of them is on the machine. The
  # file only has to exist and be named like a DLL; nothing reads it here.
  test "a missing tool for the Windows library family names that family's tools" do
    library = Path.join(System.tmp_dir!(), "xqlite_family_probe.dll")
    File.write!(library, "not a library, only a name")
    on_exit(fn -> File.rm(library) end)

    env = [{"XQLITE_SYMBOL_TOOL", "xqlite_no_such_symbol_tool"}]

    assert {output, 1} = run([library], env)
    assert output =~ "objdump"
    assert output =~ "llvm-objdump"
    assert output =~ "rustup component add llvm-tools"
  end

  # A tool that runs but reads nothing the check understands must fail it, and
  # say which tool it used. `elixir` itself is the stand-in: every platform the
  # suite runs on has it, and it answers nothing about a library.
  test "a symbol tool that reads nothing useful fails the check, and is named" do
    tool = System.find_executable("elixir")
    assert is_binary(tool)

    assert {output, 1} = run([loaded_library()], [{"XQLITE_SYMBOL_TOOL", tool}])
    assert output =~ tool
    assert output =~ loaded_library()
    assert output =~ "nothing was checked"
  end

  defp run(arguments, env \\ []) do
    System.cmd("elixir", [@script | arguments], env: env, stderr_to_stdout: true)
  end

  defp loaded_library do
    priv = :code.priv_dir(:xqlite)

    assert [library | _rest] =
             priv
             |> to_string()
             |> Path.join("native/xqlitenif.{so,dll}")
             |> Path.wildcard()

    library
  end
end

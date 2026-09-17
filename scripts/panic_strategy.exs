# Answers whether the built NIF library still unwinds on a Rust panic.
#
# rustler wraps every NIF — argument decoding included — in `catch_unwind`, so
# a panic becomes a catchable `:nif_panicked` instead of killing the VM. That
# guard only works while panics unwind, and a machine-wide cargo profile can
# turn unwinding off without changing a line of this repository. The library
# that links the unwinding runtime has `_Unwind_RaiseException` among its
# undefined symbols; the one built with `panic = "abort"` does not.
#
# Reads the artifact in front of it, so it speaks for this machine's build
# only. Where the tool that lists symbols is missing, it says so and passes.

defmodule PanicStrategy do
  @symbol "_Unwind_RaiseException"
  @tools ["nm", "llvm-nm"]

  def main do
    with {:ok, library} <- library(),
         {:ok, tool} <- symbol_tool() do
      check(tool, library)
    else
      {:error, :no_library} ->
        fail("no built NIF library found — build the crate first")

      {:error, :no_tool} ->
        pass("neither nm nor llvm-nm is on this machine; the panic strategy was not read")
    end
  end

  defp library do
    ["_build/*/lib/xqlite/priv/native/*", "native/xqlitenif/target/release/libxqlitenif.*"]
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.filter(fn path -> Path.extname(path) in [".so", ".dylib", ".dll"] end)
    |> Enum.sort_by(&File.stat!(&1).mtime, :desc)
    |> List.first()
    |> found()
  end

  defp found(nil), do: {:error, :no_library}
  defp found(path), do: {:ok, path}

  defp symbol_tool do
    case Enum.find(@tools, &System.find_executable/1) do
      nil -> {:error, :no_tool}
      tool -> {:ok, tool}
    end
  end

  defp check(tool, library) do
    case System.cmd(tool, ["-u", library], stderr_to_stdout: true) do
      {output, 0} -> verdict(library, String.contains?(output, @symbol))
      {output, code} -> fail("#{tool} failed on #{library} (exit #{code}): #{output}")
    end
  end

  defp verdict(library, true), do: pass("#{library} unwinds on a panic")

  defp verdict(library, false) do
    fail("""
    #{library} aborts on a panic instead of unwinding.

    rustler's guard cannot catch a panic in a build like this: the calling
    process does not get :nif_panicked, the whole VM dies. Check that
    native/xqlitenif/.cargo/config.toml still pins `panic = "unwind"` under
    [profile.release] and [profile.dev], and that nothing on this machine
    overrides it, then build again.
    """)
  end

  defp pass(message) do
    IO.puts("panic strategy: #{message}")
    System.halt(0)
  end

  defp fail(message) do
    IO.puts(:stderr, "panic strategy: #{message}")
    System.halt(1)
  end
end

PanicStrategy.main()

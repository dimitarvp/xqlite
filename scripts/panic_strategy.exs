# Answers whether the NIF libraries named on the command line still unwind on
# a Rust panic.
#
# rustler wraps every NIF — argument decoding included — in `catch_unwind`, so
# a panic becomes a catchable `:nif_panicked` instead of killing the VM. That
# guard only works while panics unwind, and a machine-wide cargo profile can
# turn unwinding off without changing a line of this repository. The library
# that links the unwinding runtime has `_Unwind_RaiseException` among its
# undefined symbols; the one built with `panic = "abort"` does not.
#
# The caller says which libraries to read, so the answer is about the build it
# cares about and not about whichever file happened to be newest. Without a
# tool that lists symbols this fails: a check that passes having read nothing
# is worse than no check at all.

defmodule PanicStrategy do
  @symbol "_Unwind_RaiseException"
  @tools ["nm", "llvm-nm"]
  @tool_variable "XQLITE_SYMBOL_TOOL"

  def main([]) do
    fail(2, "usage: elixir scripts/panic_strategy.exs <library> [<library> ...]")
  end

  def main(libraries) do
    with {:ok, tool} <- symbol_tool(),
         :ok <- check_each(tool, libraries) do
      System.halt(0)
    else
      {:error, message} -> fail(1, message)
    end
  end

  defp symbol_tool do
    case System.get_env(@tool_variable) do
      nil -> first_tool(@tools)
      named -> first_tool([named])
    end
  end

  defp first_tool(candidates) do
    case Enum.find(candidates, &System.find_executable/1) do
      nil -> {:error, no_tool_message()}
      tool -> {:ok, tool}
    end
  end

  defp no_tool_message do
    """
    no tool to read symbols with.

    This check needs nm or llvm-nm. Install one of them, or name the one to
    use in #{@tool_variable}. The Rust toolchain ships llvm-nm:
    `rustup component add llvm-tools`. Nothing was read, so nothing was
    checked.
    """
  end

  defp check_each(tool, libraries) do
    Enum.reduce_while(libraries, :ok, fn library, _acc ->
      case check(tool, library) do
        :ok -> {:cont, :ok}
        {:error, _message} = error -> {:halt, error}
      end
    end)
  end

  defp check(tool, library) do
    case File.regular?(library) do
      true -> read_symbols(tool, library)
      false -> {:error, "#{library} is not a file"}
    end
  end

  defp read_symbols(tool, library) do
    case System.cmd(tool, ["-u", library], stderr_to_stdout: true) do
      {output, 0} -> verdict(library, String.contains?(output, @symbol))
      {output, code} -> {:error, "#{tool} failed on #{library} (exit #{code}): #{output}"}
    end
  end

  defp verdict(library, true) do
    IO.puts("panic strategy: #{library} unwinds on a panic")
    :ok
  end

  defp verdict(library, false) do
    {:error,
     """
     #{library} aborts on a panic instead of unwinding.

     rustler's guard cannot catch a panic in a build like this: the calling
     process does not get :nif_panicked, the whole VM dies. Check that
     native/xqlitenif/.cargo/config.toml still pins `panic = "unwind"` under
     [profile.release] and [profile.dev], and that nothing on this machine
     overrides it, then build again.
     """}
  end

  defp fail(code, message) do
    IO.puts(:stderr, "panic strategy: #{message}")
    System.halt(code)
  end
end

PanicStrategy.main(System.argv())

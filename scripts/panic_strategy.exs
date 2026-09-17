# Answers whether the NIF libraries named on the command line still unwind on
# a Rust panic.
#
# rustler wraps every NIF — argument decoding included — in `catch_unwind`, so
# a panic becomes a catchable `:nif_panicked` instead of killing the VM. That
# guard only works while panics unwind, and a machine-wide cargo profile can
# turn unwinding off without changing a line of this repository.
#
# What proves unwinding depends on the library family, and the file name says
# which one it is. An ELF or Mach-O library links the unwinding runtime, so
# `_Unwind_RaiseException` is among the undefined symbols `nm -u` lists. A
# Windows `.dll` built with MSVC has no symbol table for `nm` to read and
# unwinds through Windows exceptions instead: the import table `objdump -p`
# prints names `_CxxThrowException` and `__CxxFrameHandler3`.
#
# Each family's tools are looked for on PATH and in the rustup sysroot's bin
# directory, `$(rustc --print sysroot)/lib/rustlib/<host>/bin`, which is where
# `rustup component add llvm-tools` puts llvm-nm and llvm-objdump and is what
# the release workflow reads. XQLITE_SYMBOL_TOOL names the tool to use
# instead, for either family.
#
# The caller says which libraries to read, so the answer is about the build it
# cares about and not about whichever file happened to be newest. Without a
# tool that can read the family this fails: a check that passes having read
# nothing is worse than no check at all.

defmodule PanicStrategy do
  @tool_variable "XQLITE_SYMBOL_TOOL"
  @interesting ["Unwind", "Cxx", "panic"]

  @windows_family %{
    tools: ["llvm-objdump", "objdump"],
    arguments: ["-p"],
    markers: ["_CxxThrowException", "__CxxFrameHandler3"],
    tool_names: "objdump or llvm-objdump"
  }

  @symbol_family %{
    tools: ["nm", "llvm-nm"],
    arguments: ["-u"],
    markers: ["_Unwind_RaiseException"],
    tool_names: "nm or llvm-nm"
  }

  def main([]) do
    fail(2, "usage: elixir scripts/panic_strategy.exs <library> [<library> ...]")
  end

  def main(libraries) do
    case check_each(libraries) do
      :ok -> System.halt(0)
      {:error, message} -> fail(1, message)
    end
  end

  defp check_each(libraries) do
    Enum.reduce_while(libraries, :ok, fn library, _acc ->
      case check(library) do
        :ok -> {:cont, :ok}
        {:error, _message} = error -> {:halt, error}
      end
    end)
  end

  defp check(library) do
    case File.regular?(library) do
      true -> read_and_judge(library, family(library))
      false -> {:error, "#{library} is not a file"}
    end
  end

  defp family(library) do
    case Path.extname(library) do
      ".dll" -> @windows_family
      _other -> @symbol_family
    end
  end

  defp read_and_judge(library, family) do
    case symbol_tool(family) do
      {:ok, tool} -> read_markers(tool, library, family)
      {:error, _message} = error -> error
    end
  end

  defp symbol_tool(family) do
    case System.get_env(@tool_variable) do
      nil -> first_tool(family.tools, family)
      named -> first_tool([named], family)
    end
  end

  defp first_tool(candidates, family) do
    case Enum.find_value(candidates, &resolve/1) do
      nil -> {:error, no_tool_message(family)}
      tool -> {:ok, tool}
    end
  end

  defp resolve(candidate) do
    case System.find_executable(candidate) do
      nil -> in_rust_sysroot(candidate)
      path -> path
    end
  end

  defp in_rust_sysroot(candidate) do
    case System.find_executable("rustc") do
      nil -> nil
      rustc -> sysroot_tool(rustc, candidate)
    end
  end

  defp sysroot_tool(rustc, candidate) do
    with {sysroot, 0} <- System.cmd(rustc, ["--print", "sysroot"]),
         {version, 0} <- System.cmd(rustc, ["-vV"]),
         host when is_binary(host) <- host_triple(version) do
      sysroot
      |> String.trim()
      |> Path.join("lib/rustlib/#{host}/bin")
      |> first_existing(candidate)
    else
      _unreadable -> nil
    end
  end

  defp host_triple(version) do
    version
    |> String.split(~r/\r?\n/)
    |> Enum.find_value(&host_line/1)
  end

  defp host_line("host: " <> host), do: String.trim(host)
  defp host_line(_line), do: nil

  defp first_existing(directory, candidate) do
    [candidate, candidate <> ".exe"]
    |> Enum.map(fn name -> Path.join(directory, name) end)
    |> Enum.find(&File.regular?/1)
  end

  defp read_markers(tool, library, family) do
    case System.cmd(tool, family.arguments ++ [library], stderr_to_stdout: true) do
      {output, 0} -> verdict(tool, library, family, output)
      {output, code} -> {:error, tool_failed_message(tool, library, code, output)}
    end
  end

  defp verdict(tool, library, family, output) do
    case Enum.any?(family.markers, fn marker -> String.contains?(output, marker) end) do
      true -> pass(library)
      false -> {:error, aborts_message(tool, library, family, output)}
    end
  end

  defp pass(library) do
    IO.puts("panic strategy: #{library} unwinds on a panic")
    :ok
  end

  defp no_tool_message(family) do
    """
    no tool to read #{family.tool_names} output with.

    This library needs #{family.tool_names}. Install one of them, or name the
    one to use in #{@tool_variable}. The Rust toolchain ships llvm-nm and
    llvm-objdump: `rustup component add llvm-tools`. Nothing was read, so
    nothing was checked.
    """
  end

  defp tool_failed_message(tool, library, code, output) do
    """
    #{tool} failed on #{library} (exit #{code}).

    Nothing was read, so nothing was checked. What it printed:
    #{indent(output)}
    """
  end

  defp aborts_message(tool, library, family, output) do
    """
    #{library} aborts on a panic instead of unwinding.

    Read with: #{tool} #{Enum.join(family.arguments, " ")} #{library}
    Looked for: #{Enum.join(family.markers, " or ")}
    What the readout held:
    #{interesting_lines(output)}

    rustler's guard cannot catch a panic in a build like this: the calling
    process does not get :nif_panicked, the whole VM dies. Check that
    native/xqlitenif/.cargo/config.toml still pins `panic = "unwind"` under
    [profile.release] and [profile.dev], and that nothing on this machine
    overrides it, then build again.
    """
  end

  defp interesting_lines(output) do
    output
    |> String.split(~r/\r?\n/)
    |> Enum.filter(&interesting?/1)
    |> lines_or_nothing()
  end

  defp interesting?(line) do
    Enum.any?(@interesting, fn word -> String.contains?(line, word) end)
  end

  defp lines_or_nothing([]) do
    "  nothing in the readout mentioned #{Enum.join(@interesting, ", ")}"
  end

  defp lines_or_nothing(lines), do: indent(Enum.join(lines, "\n"))

  defp indent(text) do
    text
    |> String.split(~r/\r?\n/)
    |> Enum.map_join("\n", fn line -> "  " <> line end)
  end

  defp fail(code, message) do
    IO.puts(:stderr, "panic strategy: #{message}")
    System.halt(code)
  end
end

PanicStrategy.main(System.argv())

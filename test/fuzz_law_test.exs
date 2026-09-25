defmodule Xqlite.FuzzLawTest do
  @moduledoc """
  Every public function of `Xqlite`, `XqliteNIF`, `Xqlite.Pragma` and
  `Xqlite.TypeExtension`, called with hostile terms and with values of its own
  `@spec` types.

  The law: the virtual machine survives every call, every call returns, and
  every answer has a documented shape: `:ok`, `{:ok, _}`, `{:error, reason}`
  whose reason is an atom or a tuple tagged with one, a raise of
  `ArgumentError` or `FunctionClauseError`, or the bare answer a few functions
  document.

  The calls run in a second virtual machine, `test/support/fuzz_child.exs`, so
  a crash in native code ends that machine and not the suite, and a call that
  never returns meets a deadline. Before each call the child appends the
  function and the call's index to `calls.log`, whose last line names the
  culprit. The seed and that index regenerate its arguments: from an empty
  directory, `elixir -pa "<repo>/_build/test/lib/*/ebin"
  <repo>/test/support/fuzz_child.exs <seed> <index> <function>` runs that
  function alone and adds each call's arguments to its line in `calls.log`.
  Run it from a terminal: the child halts when its stdin reaches end of file,
  so under `</dev/null` it stops before the first call.

  Left out: the functions hidden from the docs, which are no public API;
  `Xqlite.Pragma.query_to_pragma_result/1`, which only converts the library's
  own answers; `Xqlite.TypeExtension.encode_value/2` and `decode_value/2`,
  whose caller vouches for the extension list; and the atom `:hard_heap_limit`,
  because a small hard heap limit binds the whole OS process for good and
  every later open fails.
  """

  use ExUnit.Case, async: true

  @moduletag timeout: 240_000
  @child Path.expand("support/fuzz_child.exs", __DIR__)

  setup do
    scratch =
      Path.join(System.tmp_dir!(), "xqlite_fuzz_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(scratch)
    on_exit(fn -> File.rm_rf(scratch) end)
    %{scratch: scratch}
  end

  test "every public function survives 2000 calls and answers a documented shape", %{
    scratch: scratch
  } do
    assert_child_passes(scratch, [Integer.to_string(ExUnit.configuration()[:seed]), "2000"])
  end

  test "the child over XqliteNIF.query/3 alone passes 50 calls", %{scratch: scratch} do
    assert_child_passes(scratch, ["1", "50", "XqliteNIF.query/3"])
  end

  defp assert_child_passes(scratch, args) do
    ebin = Path.join(Path.dirname(to_string(:code.lib_dir(:xqlite))), "*/ebin")

    port =
      Port.open({:spawn_executable, System.find_executable("elixir")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        cd: scratch,
        args: ["-pa", ebin, @child | args]
      ])

    {status, output} = collect(port, System.monotonic_time(:millisecond) + 180_000, [])

    assert status == 0,
           "child #{Enum.join(args, " ")}: status #{inspect(status)}, last call #{last_call(scratch)}\n#{output}"
  end

  defp collect(port, deadline, output) do
    receive do
      {^port, {:data, data}} -> collect(port, deadline, [output | data])
      {^port, {:exit_status, status}} -> {status, IO.iodata_to_binary(output)}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        Port.close(port)
        {:deadline, IO.iodata_to_binary(output)}
    end
  end

  defp last_call(scratch) do
    case File.read(Path.join(scratch, "calls.log")) do
      {:ok, log} -> log |> String.split("\n", trim: true) |> List.last()
      {:error, reason} -> inspect(reason)
    end
  end
end

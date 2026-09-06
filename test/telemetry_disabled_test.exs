defmodule Xqlite.TelemetryDisabledTest do
  @moduledoc """
  What `Xqlite.Telemetry`'s macros do when the compile-time flag is off.

  The suite itself compiles with `:telemetry_enabled` set to `true`, so
  the `else` branch of the module's `if` never reaches a normal run.
  This file compiles that branch on purpose: it renames the module in
  the source text, sets the flag to `false`, compiles the renamed
  source, restores the flag, and then compiles a consumer module
  against the renamed macros. `mix test.seq` gives every file its own
  OS process, so the flipped flag and the extra modules stay here.

  A second consumer, compiled against the enabled module this suite
  already carries, does double duty: it proves the "no call into
  `:telemetry`" check can fail rather than passing because it looks in
  the wrong place, and it is the other half of the pin that both
  builds accept the same block shapes.

  The consumers take their block value from a function call rather
  than a literal, so each shape reaches the macro as a runtime value.
  """

  use ExUnit.Case, async: true

  @telemetry_source "lib/xqlite/telemetry.ex"
  @module_header "defmodule Xqlite.Telemetry do"
  @probe_name "XqliteTelemetryDisabledProbe"
  @disabled_consumer "XqliteTelemetryDisabledConsumer"
  @enabled_consumer "XqliteTelemetryEnabledConsumer"

  setup_all do
    source = File.read!(@telemetry_source)
    assert String.contains?(source, @module_header)

    renamed =
      String.replace(source, @module_header, "defmodule #{@probe_name} do", global: false)

    previous = Application.get_env(:xqlite, :telemetry_enabled)
    Application.put_env(:xqlite, :telemetry_enabled, false)
    _probe_modules = Code.compile_string(renamed)
    restore_flag(previous)

    {disabled, disabled_binary} = compile_consumer(@disabled_consumer, @probe_name)
    {enabled, enabled_binary} = compile_consumer(@enabled_consumer, "Xqlite.Telemetry")

    {:ok,
     probe: Module.concat([@probe_name]),
     disabled: disabled,
     disabled_binary: disabled_binary,
     enabled: enabled,
     enabled_binary: enabled_binary}
  end

  test "the disabled build reports itself disabled", %{probe: probe} do
    refute probe.enabled?()
  end

  test "emit/3 evaluates its arguments and returns :ok", %{disabled: disabled} do
    assert disabled.emit(:anything) == :ok
  end

  test "span/3 returns the block's value in every shape", %{disabled: disabled} do
    for shape <- [:plain, :two, :three] do
      assert disabled.span(shape) == disabled.block(shape)
    end
  end

  test "span_with_stop_metadata/3 unwraps both stop-metadata shapes", %{disabled: disabled} do
    assert disabled.span_with_stop_metadata(:two) == :two_value
    assert disabled.span_with_stop_metadata(:three) == :three_value
  end

  test "a block of any other shape fails in both builds", %{
    disabled: disabled,
    enabled: enabled
  } do
    assert_raise FunctionClauseError, fn -> disabled.span_with_stop_metadata(:plain) end
    assert_raise FunctionClauseError, fn -> enabled.span_with_stop_metadata(:plain) end
  end

  test "the disabled consumer's bytecode holds no call into :telemetry", %{
    disabled: disabled,
    disabled_binary: binary
  } do
    assert external_calls(binary, disabled, :telemetry) == []
  end

  test "the same consumer against the enabled module does call :telemetry", %{
    enabled: enabled,
    enabled_binary: binary
  } do
    assert external_calls(binary, enabled, :telemetry) == [{:telemetry, :execute, 3}]
  end

  defp restore_flag(nil), do: Application.delete_env(:xqlite, :telemetry_enabled)
  defp restore_flag(value), do: Application.put_env(:xqlite, :telemetry_enabled, value)

  defp compile_consumer(name, telemetry_module) do
    module = Module.concat([name])
    assert [{^module, binary}] = Code.compile_string(consumer_source(name, telemetry_module))
    {module, binary}
  end

  defp consumer_source(name, telemetry_module) do
    """
    defmodule #{name} do
      require #{telemetry_module}, as: T

      def emit(kind), do: T.emit([:probe, :emit], %{count: 1}, %{kind: kind})

      def span(kind), do: T.span([:probe, :span], %{kind: kind}, do: block(kind))

      def span_with_stop_metadata(kind),
        do: T.span_with_stop_metadata([:probe, :swsm], %{kind: kind}, do: block(kind))

      def block(:plain), do: :plain_value
      def block(:two), do: {:two_value, %{table: "t"}}
      def block(:three), do: {:three_value, %{rows: 1}, %{table: "t"}}
    end
    """
  end

  # A module's `imports` chunk is every external function its compiled
  # bytecode can call, which is what "no telemetry call is left in the
  # beam" means. The abstract-code chunk is absent here: modules built
  # with `Code.compile_string/1` carry Elixir debug info, not Erlang's.
  defp external_calls(binary, module, called_module) do
    assert {:ok, {^module, [imports: imports]}} = :beam_lib.chunks(binary, [:imports])

    Enum.filter(imports, fn
      {^called_module, _fun, _arity} -> true
      _other -> false
    end)
  end
end

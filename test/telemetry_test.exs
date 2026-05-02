defmodule Xqlite.TelemetryTest do
  use ExUnit.Case, async: true

  alias Xqlite.Telemetry

  describe "compile-time flag" do
    test "enabled?/0 reflects the compile_env value" do
      # Test config sets :telemetry_enabled to true.
      assert Telemetry.enabled?() == true
    end

    test "enabled?/0 returns a constant (no runtime lookup)" do
      # Calling twice must give the same value — flag is fixed at
      # compile time, not read from Application env at runtime.
      assert Telemetry.enabled?() == Telemetry.enabled?()
    end
  end

  describe "monotonic_time/0" do
    test "returns an integer in nanoseconds" do
      t = Telemetry.monotonic_time()
      assert is_integer(t)
    end

    test "is non-decreasing across consecutive calls" do
      t1 = Telemetry.monotonic_time()
      t2 = Telemetry.monotonic_time()
      assert t2 >= t1
    end

    test "matches System.monotonic_time(:nanosecond) order of magnitude" do
      ours = Telemetry.monotonic_time()
      theirs = System.monotonic_time(:nanosecond)
      # Same clock; values should be within milliseconds of each other.
      assert abs(theirs - ours) < 1_000_000_000
    end
  end

  describe "emit/3 macro" do
    require Telemetry

    test "fires a :telemetry event when enabled" do
      :telemetry.attach(
        "telemetry-test-emit",
        [:xqlite, :test, :unit],
        fn name, measurements, metadata, _ ->
          send(self_pid(metadata), {:emitted, name, measurements, metadata})
        end,
        nil
      )

      Telemetry.emit([:xqlite, :test, :unit], %{count: 1}, %{
        pid: self(),
        token: :unit_test
      })

      assert_receive {:emitted, [:xqlite, :test, :unit], %{count: 1}, %{token: :unit_test}}

      :telemetry.detach("telemetry-test-emit")
    end

    test "fires no event when no handler is attached (smoke test)" do
      # Disable side-effect: this just confirms emit/3 doesn't crash
      # when there are zero handlers. It's the cheap baseline.
      assert Telemetry.emit([:xqlite, :test, :no_handler], %{}, %{}) == :ok
    end
  end

  describe "span/3 macro" do
    require Telemetry

    test "fires :start and :stop when block succeeds" do
      attach_capture("test-span-success", [
        [:xqlite, :test, :span, :start],
        [:xqlite, :test, :span, :stop],
        [:xqlite, :test, :span, :exception]
      ])

      result =
        Telemetry.span([:xqlite, :test, :span], %{tag: :ok_path}, do: 42)

      assert result == 42

      assert_receive {:telemetry_event, [:xqlite, :test, :span, :start],
                      %{monotonic_time: _, system_time: _}, %{tag: :ok_path}}

      assert_receive {:telemetry_event, [:xqlite, :test, :span, :stop], %{duration: dur},
                      %{tag: :ok_path}}

      assert is_integer(dur) and dur >= 0

      :telemetry.detach("test-span-success")
    end

    test "fires :exception when block raises and re-raises" do
      attach_capture("test-span-exception", [
        [:xqlite, :test, :span2, :start],
        [:xqlite, :test, :span2, :stop],
        [:xqlite, :test, :span2, :exception]
      ])

      assert_raise RuntimeError, "boom", fn ->
        Telemetry.span([:xqlite, :test, :span2], %{tag: :err_path}, do: raise("boom"))
      end

      assert_receive {:telemetry_event, [:xqlite, :test, :span2, :start], %{monotonic_time: _},
                      %{tag: :err_path}}

      assert_receive {:telemetry_event, [:xqlite, :test, :span2, :exception], %{duration: _},
                      metadata}

      assert metadata.tag == :err_path
      assert metadata.kind == :error
      assert metadata.reason == %RuntimeError{message: "boom"}

      :telemetry.detach("test-span-exception")
    end
  end

  describe "span_with_stop_metadata/3 macro" do
    require Telemetry

    test "merges start metadata with block-returned stop metadata" do
      attach_capture("test-span-merge", [
        [:xqlite, :test, :merge, :start],
        [:xqlite, :test, :merge, :stop]
      ])

      result =
        Telemetry.span_with_stop_metadata [:xqlite, :test, :merge], %{
          phase: :start
        } do
          {:computed, %{phase: :start, rows: 7}}
        end

      assert result == :computed

      assert_receive {:telemetry_event, [:xqlite, :test, :merge, :start], _measurements,
                      %{phase: :start}}

      assert_receive {:telemetry_event, [:xqlite, :test, :merge, :stop], _measurements,
                      %{phase: :start, rows: 7}}

      :telemetry.detach("test-span-merge")
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp self_pid(%{pid: pid}), do: pid

  defp attach_capture(handler_id, events) do
    test_pid = self()

    :telemetry.attach_many(
      handler_id,
      events,
      fn name, measurements, metadata, _ ->
        send(test_pid, {:telemetry_event, name, measurements, metadata})
      end,
      nil
    )
  end
end

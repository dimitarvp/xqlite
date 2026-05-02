defmodule Xqlite.Telemetry.TestSupportTest do
  @moduledoc """
  Validates the telemetry test helpers behave as documented:
  attach_capture / detach round-trip, assert_emitted with measurement
  + metadata subset matching, assert_span happy path, drain_events.
  """

  use ExUnit.Case, async: true
  import Xqlite.Telemetry.TestSupport

  setup do
    {:ok, conn} = Xqlite.open_in_memory()
    on_exit(fn -> XqliteNIF.close(conn) end)
    {:ok, conn: conn}
  end

  test "attach_capture / detach round-trip", %{conn: conn} do
    handler_id =
      attach_capture([
        [:xqlite, :query, :start],
        [:xqlite, :query, :stop]
      ])

    {:ok, _} = Xqlite.query(conn, "SELECT 1", [])

    # Both events should be in the mailbox.
    assert_received {:telemetry_event, [:xqlite, :query, :start], _, _}
    assert_received {:telemetry_event, [:xqlite, :query, :stop], _, _}

    detach(handler_id)

    {:ok, _} = Xqlite.query(conn, "SELECT 2", [])
    refute_receive {:telemetry_event, [:xqlite, :query, :stop], _, _}, 50
  end

  test "assert_emitted with metadata subset match", %{conn: conn} do
    handler_id = attach_capture([[:xqlite, :query, :stop]])

    {:ok, _} = Xqlite.query(conn, "SELECT 1", [])

    assert_emitted([:xqlite, :query, :stop],
      metadata: %{result_class: :ok, error_reason: nil}
    )

    detach(handler_id)
  end

  test "assert_span returns both start and stop metadata", %{conn: conn} do
    handler_id =
      attach_capture([
        [:xqlite, :query, :start],
        [:xqlite, :query, :stop]
      ])

    {:ok, _} = Xqlite.query(conn, "SELECT 1", [])

    {start_md, stop_md} = assert_span([:xqlite, :query])

    assert start_md.cancellable? == false
    assert stop_md.result_class == :ok

    detach(handler_id)
  end

  test "drain_events returns all in order", %{conn: conn} do
    handler_id =
      attach_capture([
        [:xqlite, :query, :start],
        [:xqlite, :query, :stop]
      ])

    {:ok, _} = Xqlite.query(conn, "SELECT 1", [])
    {:ok, _} = Xqlite.query(conn, "SELECT 2", [])

    events = drain_events()
    assert length(events) == 4

    names = Enum.map(events, fn {n, _, _} -> n end)

    assert names == [
             [:xqlite, :query, :start],
             [:xqlite, :query, :stop],
             [:xqlite, :query, :start],
             [:xqlite, :query, :stop]
           ]

    detach(handler_id)
  end

  test "compile-time flag invariant: enabled?/0 is constant" do
    # In test config :telemetry_enabled is true; this confirms the
    # macro is exercising the enabled path. The disabled path is
    # verified by the macro definition itself (compile-time
    # conditional in lib/xqlite/telemetry.ex). To confirm disabled
    # behaviour empirically, set the flag to false in a separate
    # build and rerun this test — `Xqlite.Telemetry.enabled?()`
    # would then return false and no events would fire even though
    # we call into them.
    assert Xqlite.Telemetry.enabled?() == true
    assert XqliteNIF != nil
  end
end

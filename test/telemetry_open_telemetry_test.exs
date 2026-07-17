defmodule Xqlite.Telemetry.OpenTelemetryTest do
  use ExUnit.Case, async: true

  alias Xqlite.Telemetry.OpenTelemetry, as: Otel

  test "query events map system, operation, and query text" do
    metadata = %{conn: nil, sql: "SELECT 1", result_class: :ok, error_reason: nil}

    assert %{
             "db.system.name" => "sqlite",
             "db.operation.name" => "query",
             "db.query.text" => "SELECT 1"
           } == Otel.attributes([:xqlite, :query, :stop], %{}, metadata)
  end

  test "error results map error.type from the structured reason's leading atom" do
    metadata = %{
      sql: "INSERT INTO t VALUES (1)",
      result_class: :error,
      error_reason: {:constraint_violation, :constraint_unique, %{}}
    }

    attrs = Otel.attributes([:xqlite, :execute, :stop], %{}, metadata)
    assert attrs["error.type"] == "constraint_violation"
    assert attrs["db.operation.name"] == "execute"
  end

  test "exception events map error.type from the exception module" do
    metadata = %{sql: "SELECT 1", kind: :error, reason: %ArgumentError{}}

    assert %{"error.type" => "ArgumentError"} =
             Otel.attributes([:xqlite, :query, :exception], %{}, metadata)
  end

  test "open events map the path to db.namespace; nil paths are skipped" do
    with_path = %{path: "/tmp/a.db", mode: :file, result_class: :ok, error_reason: nil}
    attrs = Otel.attributes([:xqlite, :open, :stop], %{}, with_path)
    assert attrs["db.namespace"] == "/tmp/a.db"

    temp = %{path: nil, mode: :temp, result_class: :ok, error_reason: nil}
    refute Map.has_key?(Otel.attributes([:xqlite, :open, :stop], %{}, temp), "db.namespace")
  end

  test "grouped events derive dotted operation names" do
    assert %{"db.operation.name" => "hook.busy"} =
             Otel.attributes([:xqlite, :hook, :busy], %{}, %{conn: nil, tag: nil})

    assert %{"db.operation.name" => "stream.open"} =
             Otel.attributes([:xqlite, :stream, :open, :stop], %{}, %{})
  end

  test "span_name follows the operation/namespace priority chain" do
    assert "open /tmp/a.db" == Otel.span_name([:xqlite, :open, :stop], %{path: "/tmp/a.db"})
    assert "query" == Otel.span_name([:xqlite, :query, :stop], %{})
    assert "sqlite" == Otel.span_name([:not_ours], %{})
  end
end

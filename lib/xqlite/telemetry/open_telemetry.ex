defmodule Xqlite.Telemetry.OpenTelemetry do
  @moduledoc """
  A pure translation table from xqlite's telemetry events to
  OpenTelemetry's stable database semantic-convention attributes.

  xqlite has NO OpenTelemetry dependency — you own the handler and the
  SDK. Feed any `[:xqlite, ...]` event through `attributes/3` inside
  your own `:telemetry` handler and attach the returned map to the span
  you create; backends with database-aware tooling (latency by
  statement, DB overview pages) key off exactly these names.

      def handle_event([:xqlite | _] = event, measurements, metadata, _cfg) do
        attrs = Xqlite.Telemetry.OpenTelemetry.attributes(event, measurements, metadata)
        # create/end your OTel span here, with `attrs` as span attributes
      end

  Targets the STABLE database conventions: `db.system.name`,
  `db.query.text`, `db.operation.name`, `db.namespace`, `error.type`.
  Keys are strings, values strings — ready for OTel attribute APIs.

  If first-class instrumentation lands later (an optional
  `opentelemetry_api` dependency, or a companion instrumentation
  package), it builds on this module as its attribute vocabulary — the
  mapping here is the contract either way.

  ## Sources

  Every mapped name traces to the OpenTelemetry specification:

  * Database client spans (attribute set, the span-name priority
    chain, and the `sqlite` value for `db.system.name`):
    <https://opentelemetry.io/docs/specs/semconv/database/database-spans/>
  * The `db.*` attribute registry (definitions of `db.system.name`,
    `db.query.text`, `db.operation.name`, `db.namespace`):
    <https://opentelemetry.io/docs/specs/semconv/registry/attributes/db/>
  * The `error.type` attribute (general registry):
    <https://opentelemetry.io/docs/specs/semconv/registry/attributes/error/>

  Verified against the stable revision of the database conventions on
  2026-07-17; the pre-stabilization names (`db.system`,
  `db.statement`) are deliberately NOT emitted.
  """

  @doc """
  Maps one xqlite telemetry event to semantic-convention attributes.

  Always includes `db.system.name => "sqlite"`. Adds
  `db.operation.name` derived from the event, `db.query.text` when the
  event's metadata carries `:sql`, `db.namespace` when it carries
  `:path` (connection open/close; `nil` paths — temporary databases —
  are skipped), and `error.type` for error results and exceptions (the
  structured reason's leading atom, or the exception module).

  Everything else in the metadata (result classes, counters, xqlite's
  own identifiers) remains available to your handler directly — this
  function maps only the semantic-convention vocabulary.
  """
  @spec attributes([atom()], map(), map()) :: %{String.t() => String.t()}
  def attributes([:xqlite | _] = event, _measurements, metadata) when is_map(metadata) do
    %{"db.system.name" => "sqlite"}
    |> put_present("db.operation.name", operation_name(event))
    |> put_present("db.query.text", query_text(metadata))
    |> put_present("db.namespace", metadata[:path])
    |> put_error(metadata)
  end

  @doc """
  Suggested span name per the conventions' priority chain:
  `"{operation} {namespace}"` when both are known, the operation alone
  otherwise, `"sqlite"` as the last resort.
  """
  @spec span_name([atom()], map()) :: String.t()
  def span_name(event, metadata \\ %{}) do
    case {operation_name(event), metadata[:path]} do
      {nil, _path} -> "sqlite"
      {op, nil} -> op
      {op, path} -> "#{op} #{path}"
    end
  end

  defp operation_name([:xqlite, op, stage]) when stage in [:start, :stop, :exception],
    do: Atom.to_string(op)

  defp operation_name([:xqlite, group, sub | _rest]), do: "#{group}.#{sub}"
  defp operation_name(_event), do: nil

  defp query_text(%{sql: sql}) when is_binary(sql), do: sql
  defp query_text(_metadata), do: nil

  defp put_present(attrs, _key, nil), do: attrs
  defp put_present(attrs, key, value) when is_binary(value), do: Map.put(attrs, key, value)
  defp put_present(attrs, _key, _value), do: attrs

  defp put_error(attrs, %{result_class: :error, error_reason: reason}),
    do: Map.put(attrs, "error.type", error_type(reason))

  defp put_error(attrs, %{kind: _kind, reason: reason}),
    do: Map.put(attrs, "error.type", error_type(reason))

  defp put_error(attrs, _metadata), do: attrs

  defp error_type(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_type({tag, _}) when is_atom(tag), do: Atom.to_string(tag)
  defp error_type({tag, _, _}) when is_atom(tag), do: Atom.to_string(tag)
  defp error_type({tag, _, _, _}) when is_atom(tag), do: Atom.to_string(tag)
  defp error_type(%struct{}), do: inspect(struct)
  defp error_type(_reason), do: "error"
end

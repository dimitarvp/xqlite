# Duration arrived in Elixir 1.17; the module only exists when the struct
# does, mirroring the optional-availability gate used for Decimal.
if Code.ensure_loaded?(Duration) do
  defmodule Xqlite.TypeExtension.Duration do
    @moduledoc """
    Encode-only type extension: exact-length `Duration` → int64
    nanoseconds.

    Only durations made of exact units convert — weeks, days, hours,
    minutes, seconds, microseconds. Calendar units (years, months) have
    no fixed length, so durations carrying them are skipped; binding then
    fails downstream with the NIF's structured rejection of the raw
    struct. There is deliberately no decode: a nanosecond span is
    indistinguishable from any other stored integer.

    Mirrors `XqliteEcto3.Types.Duration`'s semantics (int64 ns,
    exact-units-only). Requires Elixir 1.17+ — on older versions this
    module does not exist.
    """

    @behaviour Xqlite.TypeExtension

    @ns_per_second 1_000_000_000
    @seconds_per_week 604_800
    @seconds_per_day 86_400
    @seconds_per_hour 3_600
    @seconds_per_minute 60

    @impl true
    def encode(%Duration{year: 0, month: 0} = d) do
      seconds =
        d.week * @seconds_per_week + d.day * @seconds_per_day +
          d.hour * @seconds_per_hour + d.minute * @seconds_per_minute + d.second

      {microseconds, _precision} = d.microsecond
      {:ok, seconds * @ns_per_second + microseconds * 1_000}
    end

    def encode(_), do: :skip

    @impl true
    def decode(_), do: :skip
  end
end

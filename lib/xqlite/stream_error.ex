defmodule Xqlite.StreamError do
  @moduledoc """
  Raised when a mid-stream fetch fails and the stream was opened with
  `on_error: :raise` (the default mode of `Xqlite.stream/4`).

  Streaming is the one place where xqlite departs from its tuples-only
  contract: `Stream.resource/3` cannot hand an error back to the consumer
  as a return value, so the default surfaces mid-fetch failures as this
  exception (mirroring how Ecto/DBConnection streams behave). The
  structured failure is preserved verbatim in `:reason` (an
  `t:Xqlite.error_reason/0` term such as `{:utf8_error, column, detail}`)
  so callers can inspect it; `:message` is always a human-readable binary
  derived from that reason.
  """
  defexception [:reason, :message]

  @type t :: %__MODULE__{reason: term(), message: binary()}

  @impl true
  def exception(opts) do
    reason = Keyword.fetch!(opts, :reason)
    %__MODULE__{reason: reason, message: "xqlite stream fetch failed: #{inspect(reason)}"}
  end
end

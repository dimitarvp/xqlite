defmodule XqliteNIF do
  use Rustler, otp_app: :xqlite, crate: :xqlitenif

  def open(_db_name, _opts), do: err()

  # def close(_conn), do: err()
  # def exec(_conn, _sql), do: err()

  defp err, do: :erlang.nif_error(:nif_not_loaded)
end

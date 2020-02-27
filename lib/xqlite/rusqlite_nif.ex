defmodule Xqlite.RusqliteNif do
  use Rustler, otp_app: :xqlite, crate: :xqlite_rusqlitenif

  def add(_a, _b), do: err()
  def open(_db_name, _opts), do: err()
  def close(_db_name), do: err()

  defp err, do: :erlang.nif_error(:nif_not_loaded)
end

defmodule XqliteNIF do
  use Rustler, otp_app: :xqlite, crate: :xqlitenif, mode: :release

  def open(_db_name, _opts), do: err()
  def close(_conn), do: err()
  def exec(_conn, _sql), do: err()
  def pragma_get0(_conn, _pragma_name, _opts), do: err()
  def pragma_get1(_conn, _pragma_name, _param, _opts), do: err()
  def pragma_put(_conn, _pragma_name, _pragma_value, _opts), do: err()
  def query(_conn, _sql), do: err()

  def raw_open(_path, _opts \\ []), do: err()
  def raw_exec(_conn, _sql, _params \\ []), do: err()
  def raw_close(_conn), do: err()
  def raw_pragma_write(_conn, _sql), do: err()
  def raw_pragma_write_and_read(_conn, _name, _value), do: err()

  defp err, do: :erlang.nif_error(:nif_not_loaded)
end

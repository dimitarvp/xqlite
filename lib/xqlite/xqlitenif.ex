defmodule XqliteNIF do
  use Rustler, otp_app: :xqlite, crate: :xqlitenif, mode: :release

  def raw_open(_path, _opts \\ []), do: err()
  def raw_open_in_memory(_path), do: err()
  def raw_open_temporary(), do: err()
  def raw_query(_conn, _sql, _params \\ []), do: err()
  def raw_execute(_conn, _sql, _params \\ []), do: err()
  def raw_close(_conn), do: err()
  def raw_pragma_write(_conn, _sql), do: err()
  def raw_pragma_write_and_read(_conn, _name, _value), do: err()
  def raw_begin(_conn), do: err()
  def raw_commit(_conn), do: err()
  def raw_rollback(_conn), do: err()

  defp err, do: :erlang.nif_error(:nif_not_loaded)
end

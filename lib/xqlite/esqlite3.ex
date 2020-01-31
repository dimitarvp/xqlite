defmodule Xqlite.Esqlite3 do
  import Xqlite

  alias Xqlite.{Config, Driver}

  @behaviour Driver

  @impl Driver
  def open(db_name, opts) when is_db_name(db_name) and is_opts(opts) do
    :esqlite3.open(to_charlist(db_name), Config.get_exec_timeout(opts))
  end

  @impl Driver
  def close(db, opts) when is_conn(db) and is_opts(opts) do
    :esqlite3.close(db, Config.get_exec_timeout(opts))
  end
end

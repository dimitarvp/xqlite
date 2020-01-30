defmodule Xqlite.Driver do
  @callback open(Xqlite.db_name(), Xqlite.opts()) :: Xqlite.open_result()
  @callback close(Xqlite.conn(), Xqlite.opts()) :: Xqlite.close_result()
end

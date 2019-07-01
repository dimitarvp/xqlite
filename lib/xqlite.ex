defmodule Xqlite do
  @moduledoc """
  TODO
  """

  # If no path is specified, use an anonymous in-memory database.
  @default_db ":memory:"

  # Default timeout to open an Sqlite3 database.
  @default_db_timeout 5000

  @spec default_db() :: String.t()
  def default_db(), do: @default_db

  @spec default_db_timeout() :: non_neg_integer
  def default_db_timeout(), do: @default_db_timeout
end

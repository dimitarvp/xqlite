defmodule Xqlite do
  @moduledoc ~S"""
  This is the central module of this library. All SQLite operations can be performed from here.
  Note that they delegate to other modules which you can also use directly.
  """

  @type conn :: reference()
  @type error :: {:error, any()}

  @spec int2bool(0 | 1) :: true | false
  def int2bool(0), do: false
  def int2bool(1), do: true

  @doc """
  Enables strict mode only for the lifetime of the given database connection.

  In strict mode, SQLite is less forgiving. For example, an attempt to insert
  a string into an INTEGER column of a `STRICT` table will result in an error,
  whereas in normal mode it might be coerced or stored as text.
  This setting only affects tables declared with the `STRICT` keyword.

  See: [STRICT Tables](https://www.sqlite.org/stricttables.html)
  """
  @spec enable_strict_mode(conn()) :: :ok | error()
  def enable_strict_mode(conn) do
    case XqliteNIF.set_pragma(conn, "strict", :on) do
      {:ok, true} -> :ok
      error -> error
    end
  end

  @doc """
  Disables strict mode only for the lifetime given database connection (SQLite's default).

  See `enable_strict_mode/1` for details.
  """
  @spec disable_strict_mode(conn()) :: :ok | error()
  def disable_strict_mode(conn) do
    case XqliteNIF.set_pragma(conn, "strict", :off) do
      {:ok, true} -> :ok
      error -> error
    end
  end

  @doc """
  Enables foreign key constraint enforcement for the given database connection.

  By default, SQLite parses foreign key constraints but does not enforce them.
  This function turns on enforcement.

  See: [SQLite PRAGMA foreign_keys](https://www.sqlite.org/pragma.html#pragma_foreign_keys)
  """
  @spec enable_foreign_key_enforcement(conn()) :: :ok | error()
  def enable_foreign_key_enforcement(conn) do
    case XqliteNIF.set_pragma(conn, "foreign_keys", :on) do
      {:ok, true} -> :ok
      error -> error
    end
  end

  @doc """
  Disables foreign key constraint enforcement for the given database connection (default behavior).

  See `enable_foreign_key_enforcement/1` for details.
  """
  @spec disable_foreign_key_enforcement(conn()) :: :ok | error()
  def disable_foreign_key_enforcement(conn) do
    case XqliteNIF.set_pragma(conn, "foreign_keys", :off) do
      {:ok, true} -> :ok
      error -> error
    end
  end
end

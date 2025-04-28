defmodule Xqlite.Schema.DatabaseInfo do
  @moduledoc """
  Information about an attached database, corresponding to `PRAGMA database_list`.
  """

  @typedoc """
  Struct definition.

  * `:name` - The logical name of the database (e.g., "main", "temp", or attached name).
  * `:file` - The absolute path to the database file, or `nil` for in-memory/temporary databases.
  """
  @type t :: %__MODULE__{
          name: String.t(),
          file: String.t() | nil
        }

  defstruct [
    :name,
    :file
  ]
end

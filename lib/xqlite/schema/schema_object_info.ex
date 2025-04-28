defmodule Xqlite.Schema.SchemaObjectInfo do
  @moduledoc """
  Information about a schema object (table, view, etc.), corresponding to `PRAGMA table_list`.
  Note: `PRAGMA table_list` primarily lists tables, views, and virtual tables.
  """

  alias Xqlite.Schema.Types

  @typedoc """
  Struct definition.

  * `:schema` - Name of the schema containing the object (e.g., "main").
  * `:name` - Name of the object.
  * `:object_type` - The type of object (see `t:Types.object_type/0`).
  * `:column_count` - Number of columns (meaningful for tables/views).
  * `:is_writable` - `true` if data can be inserted/updated/deleted in this object (typically tables/virtual tables), `false` otherwise (typically views/shadow tables).
  * `:strict` - `true` if the table was declared using `STRICT` mode, `false` otherwise.
  """
  @type t :: %__MODULE__{
          schema: String.t(),
          name: String.t(),
          object_type: Types.object_type(),
          column_count: integer(),
          is_writable: boolean(),
          strict: boolean()
        }

  defstruct [
    :schema,
    :name,
    :object_type,
    :column_count,
    :is_writable,
    :strict
  ]
end

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
  * `:is_without_rowid` - `true` if the table was created with the `WITHOUT ROWID` optimization, `false` otherwise. This is derived from the `wr` column in `PRAGMA table_list`.
  * `:strict` - `true` if the table was declared using `STRICT` mode, `false` otherwise.
  """
  @type t :: %__MODULE__{
          schema: String.t(),
          name: String.t(),
          object_type: Types.object_type(),
          column_count: integer(),
          is_without_rowid: boolean(),
          strict: boolean()
        }

  defstruct [
    :schema,
    :name,
    :object_type,
    :column_count,
    :is_without_rowid,
    :strict
  ]
end

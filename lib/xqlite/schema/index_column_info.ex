defmodule Xqlite.Schema.IndexColumnInfo do
  @moduledoc """
  Information about a specific column within an index, corresponding to `PRAGMA index_xinfo`.
  """

  alias Xqlite.Schema.Types

  @typedoc """
  Struct definition.

  * `:index_column_sequence` - 0-based position of this column within the index key/definition.
  * `:table_column_id` - The ID (0-based index) of the column in the base table definition, corresponding to the `cid` from `PRAGMA table_info`. A value of `-1` indicates that the indexed item is an expression, not a direct table column.
  * `:name` - Name of the table column included in the index, or `nil` if the index is on an expression.
  * `:sort_order` - Sort order for this column (`:asc` or `:desc`).
  * `:collation` - Name of the collation sequence used for this column (e.g., "BINARY", "NOCASE", "RTRIM").
  * `:is_key_column` - `true` if this column is part of the primary index key used for lookups. `false` if it's an "included" column (only stored in the index, part of covering indexes, SQLite >= 3.9.0).
  """
  @type t :: %__MODULE__{
          index_column_sequence: integer(),
          table_column_id: integer(),
          name: String.t() | nil,
          sort_order: Types.sort_order(),
          collation: String.t(),
          is_key_column: boolean()
        }

  defstruct [
    :index_column_sequence,
    :table_column_id,
    :name,
    :sort_order,
    :collation,
    :is_key_column
  ]
end

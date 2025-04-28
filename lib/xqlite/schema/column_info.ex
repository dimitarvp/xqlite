defmodule Xqlite.Schema.ColumnInfo do
  @moduledoc """
  Information about a specific column in a table, corresponding to `PRAGMA table_info`.
  """

  alias Xqlite.Schema.Types

  @typedoc """
  Struct definition.

  * `:column_id` - The zero-indexed ID of the column within the table.
  * `:name` - Name of the column.
  * `:type_affinity` - The resolved data type affinity (see `t:Types.type_affinity/0`).
  * `:nullable` - `true` if the column allows NULL values, `false` otherwise (derived from `NOT NULL` constraint).
  * `:default_value` - The default value expression as a string literal (e.g., "'default'", "123", "CURRENT_TIMESTAMP"), or `nil` if no default.
  * `:primary_key_index` - If this column is part of the primary key, its 1-based index within the key (e.g., 1 for single PK, 1 or 2 for compound PK). `0` if not part of the primary key.
  """
  @type t :: %__MODULE__{
          column_id: integer(),
          name: String.t(),
          type_affinity: Types.type_affinity(),
          nullable: boolean(),
          default_value: String.t() | nil,
          # 0 or 1-based index (u8 in Rust)
          primary_key_index: non_neg_integer()
        }

  defstruct [
    :column_id,
    :name,
    :type_affinity,
    :nullable,
    :default_value,
    :primary_key_index
  ]
end

defmodule Xqlite.Schema.IndexInfo do
  @moduledoc """
  Information about an index on a table, corresponding to `PRAGMA index_list`.
  """

  alias Xqlite.Schema.Types

  @typedoc """
  Struct definition.

  * `:name` - Name of the index. SQLite automatically generates names for indexes created by constraints (e.g., `sqlite_autoindex_tablename_1`).
  * `:unique` - `true` if the index enforces uniqueness, `false` otherwise.
  * `:origin` - How the index was created (see `t:Types.index_origin/0`). `:primary_key` for primary key constraints, `:unique_constraint` for unique constraints, `:create_index` for `CREATE INDEX` statements.
  * `:partial` - `true` if the index is partial (has a `WHERE` clause), `false` otherwise.
  """
  @type t :: %__MODULE__{
          name: String.t(),
          unique: boolean(),
          origin: Types.index_origin(),
          partial: boolean()
        }

  defstruct [
    :name,
    :unique,
    :origin,
    :partial
  ]
end

defmodule Xqlite.Schema.ForeignKeyInfo do
  @moduledoc """
  Information about a foreign key constraint originating from a table,
  corresponding to `PRAGMA foreign_key_list`.
  """

  alias Xqlite.Schema.Types

  @typedoc """
  Struct definition.

  * `:id` - ID of the foreign key constraint (0-based index for the table).
  * `:column_sequence` - 0-based index of the column within the foreign key constraint (for compound FKs).
  * `:target_table` - Name of the table referenced by the foreign key.
  * `:from_column` - Name of the column in the current table that is part of the foreign key.
  * `:to_column` - Name of the column in the target table that is referenced, or `nil` when the REFERENCES clause names none: SQLite then uses the parent's primary key, and a parent without one of that many columns makes every write the key checks answer `{:error, {:sqlite_failure, 1, 1, _}}` (see `XqliteNIF.schema_foreign_keys/2`).
  * `:on_update` - Action taken on update (see `t:Types.fk_action/0`).
  * `:on_delete` - Action taken on delete (see `t:Types.fk_action/0`).
  * `:match_clause` - The `MATCH` clause specified (see `t:Types.fk_match/0`).
  """
  @type t :: %__MODULE__{
          id: integer(),
          column_sequence: integer(),
          target_table: String.t(),
          from_column: String.t(),
          to_column: String.t() | nil,
          on_update: Types.fk_action(),
          on_delete: Types.fk_action(),
          match_clause: Types.fk_match()
        }

  @enforce_keys [
    :id,
    :column_sequence,
    :target_table,
    :from_column,
    :on_update,
    :on_delete,
    :match_clause
  ]
  defstruct [
    :id,
    :column_sequence,
    :target_table,
    :from_column,
    :to_column,
    :on_update,
    :on_delete,
    :match_clause
  ]
end

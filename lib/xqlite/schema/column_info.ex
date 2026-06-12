defmodule Xqlite.Schema.ColumnInfo do
  @moduledoc """
  Information about a specific column in a table, corresponding to `PRAGMA table_info`.
  """

  alias Xqlite.Schema.Types

  @typedoc """
  A column default, classified from the raw SQL text SQLite stores.

  * `:none` - the column declares no default at all.
  * `{:literal, value}` - a parsed literal: `nil` (explicit
    `DEFAULT NULL`), a boolean (`DEFAULT TRUE` / `FALSE` — SQLite
    stores these as INTEGER 1/0), an integer (including hex literals,
    interpreted as 64-bit two's complement like SQLite does), a float,
    or a string (with SQLite's `''` escaping undone).
  * `{:blob, binary}` - an `x'...'` hex blob, decoded. May contain
    arbitrary bytes, including invalid UTF-8 — that is the point of
    blobs.
  * `{:current, :time | :date | :timestamp}` - the `CURRENT_TIME` /
    `CURRENT_DATE` / `CURRENT_TIMESTAMP` keywords (matched
    case-insensitively).
  * `{:expr, sql}` - anything else, verbatim as SQLite stored it:
    parenthesized expression defaults arrive with their outer
    parentheses stripped by SQLite (e.g. `"datetime('now')"`,
    `"1+2"`). Never constant-folded — SQLite folds at insert time,
    not xqlite. Integer-shaped values that overflow 64 bits and
    non-finite floats (`9e999`) also land here rather than silently
    changing numeric type.

  Note the same literal can store differently depending on column
  affinity (`DEFAULT 42` on a TEXT column inserts the text `'42'`);
  the classification reports the default as written, not as any
  particular column would store it.

  Date/time-looking strings (`DEFAULT '2024-01-15'`) stay
  `{:literal, "2024-01-15"}` — xqlite does not divine types at the
  schema layer.
  """
  @type default_value ::
          :none
          | {:literal, nil | boolean() | integer() | float() | String.t()}
          | {:blob, binary()}
          | {:current, :time | :date | :timestamp}
          | {:expr, String.t()}

  @typedoc """
  Struct definition.

  * `:column_id` - The zero-indexed ID of the column within the table.
  * `:name` - Name of the column.
  * `:type_affinity` - The resolved data type affinity (see `t:Types.type_affinity/0`).
  * `:declared_type` - The original data type string exactly as declared in the `CREATE TABLE` statement (e.g., "VARCHAR(50)", "INTEGER", "BOOLEAN").
  * `:nullable` - `true` if the column allows NULL values, `false` otherwise (derived from `NOT NULL` constraint).
  * `:default_value` - The column default, classified (see `t:default_value/0`).
  * `:primary_key_index` - If this column is part of the primary key, its 1-based index within the key (e.g., 1 for single PK, 1 or 2 for compound PK). `0` if not part of the primary key.
  * `:hidden_kind` - Indicates if and how a column is hidden/generated (see `t:Types.column_hidden_kind/0`).
  """
  @type t :: %__MODULE__{
          column_id: integer(),
          name: String.t(),
          type_affinity: Types.type_affinity(),
          declared_type: String.t(),
          nullable: boolean(),
          default_value: default_value(),
          primary_key_index: non_neg_integer(),
          hidden_kind: Types.column_hidden_kind()
        }

  @enforce_keys [
    :column_id,
    :name,
    :type_affinity,
    :declared_type,
    :nullable,
    :primary_key_index,
    :hidden_kind
  ]
  defstruct [
    :column_id,
    :name,
    :type_affinity,
    :declared_type,
    :nullable,
    :default_value,
    :primary_key_index,
    :hidden_kind
  ]
end

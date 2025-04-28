defmodule Xqlite.Schema.Types do
  @moduledoc """
  Defines shared types used across schema information structs.
  """

  @typedoc """
  The type of schema object (table, view, etc.).
  """
  @type object_type :: :table | :view | :shadow | :virtual | :sequence

  @typedoc """
  The resolved type affinity of a column.
  """
  @type type_affinity :: :text | :numeric | :integer | :real | :blob

  @typedoc """
  The action to take on a foreign key constraint violation.
  """
  @type fk_action :: :no_action | :restrict | :set_null | :set_default | :cascade

  @typedoc """
  The foreign key matching clause type (rarely used beyond `:none`).
  """
  @type fk_match :: :none | :simple | :partial | :full

  @typedoc """
  The origin of an index (how it was created).
  """
  @type index_origin :: :create_index | :unique_constraint | :primary_key_constraint

  @typedoc """
  The sort order for a column within an index.
  """
  @type sort_order :: :asc | :desc
end

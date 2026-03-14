defmodule Xqlite.PragmaSpec do
  @moduledoc """
  Describes the capabilities and validation rules for a single SQLite PRAGMA.

  Used as the value type in the `Xqlite.Pragma.schema/0` map. Each struct fully
  describes how a PRAGMA can be read, written, validated, and post-processed.

  ## Fields

    * `return_type` — what GET returns: `:int`, `:text`, `:bool`, `:list`, or `:nothing`
    * `read_arities` — which arities support GET: `[0]`, `[1]`, `[0, 1]`, or `[]`
    * `schema_prefix` — whether `PRAGMA db_name.pragma_name` is allowed
    * `writable` — whether SET is supported
    * `valid_values` — pre-flight validation for SET: `Range.t()`, `[term()]`, or `nil`
    * `int_mapping` — maps raw integer GET results to atoms (e.g. `%{0 => :none}`)
  """

  @type t :: %__MODULE__{
          return_type: :int | :text | :bool | :list | :nothing,
          read_arities: [0 | 1],
          schema_prefix: boolean(),
          writable: boolean(),
          valid_values: Range.t() | [term()] | nil,
          int_mapping: %{integer() => atom() | boolean()} | nil
        }

  @enforce_keys [:return_type]
  defstruct [
    :return_type,
    :valid_values,
    :int_mapping,
    read_arities: [],
    schema_prefix: false,
    writable: false
  ]
end

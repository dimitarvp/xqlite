defmodule Xqlite.Result do
  @moduledoc """
  A struct representing the result of a query.

  Implements the `Table.Reader` protocol, making results directly
  consumable by libraries like Explorer, Kino, VegaLite, etc.

  ## Fields

    * `:columns` — list of column name strings
    * `:rows` — list of rows, each row being a list of values
    * `:num_rows` — number of result rows returned
    * `:changes` — number of rows modified by the last DML statement
      (INSERT/UPDATE/DELETE). For SELECT queries this is 0.
  """

  @enforce_keys [:columns, :rows, :num_rows]
  defstruct [:columns, :rows, :num_rows, changes: 0]

  @type t :: %__MODULE__{
          columns: [String.t()],
          rows: [[term()]],
          num_rows: non_neg_integer(),
          changes: non_neg_integer()
        }

  @doc """
  Converts a raw NIF query result map into a `Xqlite.Result` struct.
  """
  @spec from_map(%{columns: [String.t()], rows: [[term()]], num_rows: non_neg_integer()}) ::
          t()
  def from_map(%{columns: columns, rows: rows, num_rows: num_rows} = map) do
    %__MODULE__{
      columns: columns,
      rows: rows,
      num_rows: num_rows,
      changes: Map.get(map, :changes, 0)
    }
  end
end

defimpl Table.Reader, for: Xqlite.Result do
  def init(%{columns: columns, rows: rows, num_rows: num_rows}) do
    {:rows, %{columns: columns, count: num_rows}, rows}
  end
end

defmodule Xqlite.Result do
  @moduledoc """
  A struct representing the result of a query.

  Implements the `Table.Reader` protocol, making results directly
  consumable by libraries like Explorer, Kino, VegaLite, etc.

  ## Fields

    * `:columns` — list of column name strings
    * `:rows` — list of rows, each row being a list of values
    * `:num_rows` — number of rows returned

  ## Creating from NIF results

      {:ok, map} = XqliteNIF.query(conn, "SELECT id, name FROM users", [])
      result = Xqlite.Result.from_map(map)
  """

  @enforce_keys [:columns, :rows, :num_rows]
  defstruct [:columns, :rows, :num_rows]

  @type t :: %__MODULE__{
          columns: [String.t()],
          rows: [[term()]],
          num_rows: non_neg_integer()
        }

  @doc """
  Converts a raw NIF query result map into a `Xqlite.Result` struct.
  """
  @spec from_map(%{columns: [String.t()], rows: [[term()]], num_rows: non_neg_integer()}) ::
          t()
  def from_map(%{columns: columns, rows: rows, num_rows: num_rows}) do
    %__MODULE__{columns: columns, rows: rows, num_rows: num_rows}
  end
end

defimpl Table.Reader, for: Xqlite.Result do
  def init(%{columns: columns, rows: rows, num_rows: num_rows}) do
    {:rows, %{columns: columns, count: num_rows}, rows}
  end
end

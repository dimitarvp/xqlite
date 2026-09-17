defmodule Xqlite.NIF.StreamOpenLeakLawTest do
  @moduledoc """
  What a stream open leaves behind when it refuses one of its parameters.

  Opening a stream prepares the SQL first and reads the parameters after, so
  every way out between the two has to free the statement it prepared. The
  law: however many opens a connection refuses, the connection still closes
  with `:ok` — SQLite itself is the oracle, because a connection that still
  owns a prepared statement refuses to close — and the heap the connection
  reports for its prepared statements is back where it started, which is
  what separates "freed" from "kept somewhere we no longer look at".

  The domain is an element of the parameter list, not the parameter term: a
  map as one element of a list is a refused parameter, while a map as the
  whole term is refused earlier, before anything is prepared.

  Improper lists (`[1 | 2]`) are left out of the generators here; they are a
  law of their own.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  import Xqlite.ConnCase

  @moduletag timeout: 300_000

  for_each_opener "a stream open that refuses a parameter" do
    test "the anchor: one refused open, then the connection closes clean", %{conn: conn} do
      assert {:error, {:unsupported_data_type, :bitstring}} =
               Xqlite.stream(conn, "SELECT ?1", [<<1::7>>])

      assert :ok = Xqlite.close(conn)
    end

    property "refused opens leave nothing prepared", context do
      {mod, fun, args} = Xqlite.TestUtil.find_opener_mfa!(context)

      check all(
              element <- refused_element(),
              position <- integer(0..3),
              valid_count <- integer(1..3),
              rejections <- integer(1..3),
              max_runs: 2000
            ) do
        assert {:ok, conn} = apply(mod, fun, args)
        params = params_with(element, position, valid_count)
        assert {:ok, %{stmt_used: baseline}} = Xqlite.connection_stats(conn)

        for _ <- 1..rejections do
          assert {:error, _reason} = Xqlite.stream(conn, "SELECT ?1", params)
        end

        :erlang.garbage_collect()
        assert {:ok, %{stmt_used: ^baseline}} = Xqlite.connection_stats(conn)

        assert [%{"?1" => 7}] =
                 conn
                 |> Xqlite.stream("SELECT ?1", [7])
                 |> Enum.to_list()

        assert :ok = Xqlite.close(conn)
      end
    end
  end

  defp params_with(element, position, valid_count) do
    valid = Enum.to_list(1..valid_count)
    List.insert_at(valid, rem(position, valid_count + 1), element)
  end

  defp refused_element do
    one_of([
      constant(<<1::7>>),
      constant(%Xqlite.Blob{bytes: :nope}),
      constant({:a, :b}),
      constant(self()),
      constant(%{a: 1}),
      constant(make_ref()),
      constant(&Function.identity/1),
      constant([1, 2]),
      constant(:some_atom)
    ])
  end
end

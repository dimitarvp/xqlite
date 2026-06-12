defmodule Xqlite.SchemaDefaultValuePropertyTest do
  @moduledoc """
  Property coverage for `ColumnInfo.default_value` classification.

  Two properties, deliberately:

  1. **Round-trip via SQLite's own renderer** — for any generated
     integer / float / string / blob, `SELECT quote(?1)` produces the
     canonical SQL literal (ground truth, so symmetric render/parse
     bugs cannot hide), that literal goes into a real `DEFAULT`
     clause, and the classification must recover exactly the
     original value.
  2. **Grammar-boundary totality** — random payloads pushed through
     every DEFAULT form the grammar accepts must always classify to
     a valid shape; the classifier never errors and never panics.

  The example matrix lives in `Xqlite.SchemaDefaultValueTest`.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias XqliteNIF, as: NIF

  # NUL terminates SQL text at the C boundary, so a NUL inside a string
  # literal cannot survive a DDL round-trip; SQLite shares this limit.
  defp sql_safe_string do
    StreamData.filter(StreamData.string(:utf8), fn s -> not String.contains?(s, <<0>>) end)
  end

  defp i64 do
    StreamData.one_of([
      StreamData.integer(),
      StreamData.integer(-9_223_372_036_854_775_808..9_223_372_036_854_775_807),
      StreamData.member_of([
        0,
        -1,
        1,
        9_223_372_036_854_775_807,
        -9_223_372_036_854_775_808
      ])
    ])
  end

  defp quoted(conn, value) do
    {:ok, %{rows: [[q]]}} = NIF.query(conn, "SELECT quote(?1)", [value])
    q
  end

  defp classify_via_ddl(conn, default_sql) do
    :ok = NIF.execute_batch(conn, "DROP TABLE IF EXISTS dv_prop")
    :ok = NIF.execute_batch(conn, "CREATE TABLE dv_prop (c TEXT DEFAULT #{default_sql})")
    {:ok, [col]} = NIF.schema_columns(conn, "dv_prop")
    col.default_value
  end

  setup do
    {:ok, conn} = NIF.open_in_memory(":memory:")
    on_exit(fn -> NIF.close(conn) end)
    {:ok, conn: conn}
  end

  property "integers round-trip through quote() and DEFAULT", %{conn: conn} do
    check all(i <- i64()) do
      assert classify_via_ddl(conn, quoted(conn, i)) == {:literal, i}
    end
  end

  property "floats round-trip exactly (SQLite renders shortest-exact)", %{conn: conn} do
    check all(f <- StreamData.float()) do
      assert classify_via_ddl(conn, quoted(conn, f)) == {:literal, f}
    end
  end

  property "strings round-trip, quoting and all", %{conn: conn} do
    check all(s <- sql_safe_string()) do
      assert classify_via_ddl(conn, quoted(conn, s)) == {:literal, s}
    end
  end

  property "arbitrary byte blobs round-trip", %{conn: conn} do
    check all(b <- StreamData.binary()) do
      assert classify_via_ddl(conn, "x'" <> Base.encode16(b) <> "'") == {:blob, b}
    end
  end

  property "every grammar form classifies to a valid shape", %{conn: conn} do
    template =
      StreamData.one_of([
        StreamData.map(i64(), fn i -> {"#{i}", :literal} end),
        StreamData.map(StreamData.float(), fn f -> {"#{f}", :literal} end),
        StreamData.map(sql_safe_string(), fn s -> {quoted(conn, s), :literal} end),
        StreamData.map(StreamData.binary(), fn b ->
          {"x'" <> Base.encode16(b) <> "'", :blob}
        end),
        StreamData.map(sql_safe_string(), fn s ->
          # arbitrary payload inside an expression default
          {"(" <> quoted(conn, s) <> " || 'x')", :expr}
        end),
        StreamData.member_of([
          {"NULL", :literal},
          {"TRUE", :literal},
          {"FALSE", :literal},
          {"CURRENT_TIMESTAMP", :current},
          {"(1+2)", :expr}
        ])
      ])

    check all({default_sql, kind} <- template) do
      result = classify_via_ddl(conn, default_sql)

      case kind do
        :literal -> assert match?({:literal, _}, result)
        :blob -> assert match?({:blob, _}, result)
        :current -> assert match?({:current, _}, result)
        :expr -> assert match?({:expr, _}, result)
      end
    end
  end
end

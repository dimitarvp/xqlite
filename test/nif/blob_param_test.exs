defmodule Xqlite.NIF.BlobParamTest do
  @moduledoc """
  `%Xqlite.Blob{}` forces `BLOB` storage on every entry point that binds
  parameters, and refuses bytes that are not a binary.

  The sixteen bytes used throughout are plain ASCII, so they are valid UTF-8
  and a plain bind stores them as `TEXT`. That is what makes them a usable
  anchor: the only difference between the two expectations below is the
  wrapper.

  The empty payload is pinned twice on purpose. `query/3` and `execute/3` go
  through rusqlite, which turns an empty slice into `sqlite3_bind_zeroblob`,
  while `stream_open/3`, `stmt_bind/2` and `explain_analyze/3` use this
  crate's own binder, which calls `sqlite3_bind_blob` with a zero length —
  two different C calls with one expected result.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  import Xqlite.ConnCase

  alias Xqlite.Blob
  alias XqliteNIF, as: NIF

  # Sixteen ASCII bytes: valid UTF-8, so a plain bind stores them as TEXT.
  @utf8_bytes "0123456789abcdef"
  @raw_bytes <<0xFF, 0x00, 0x80, 0xC3>>

  for_each_opener "blob parameters" do
    setup %{conn: conn} do
      :ok =
        NIF.execute_batch(conn, "CREATE TABLE blob_param (id INTEGER PRIMARY KEY, v BLOB);")

      :ok
    end

    test "the same bytes are TEXT plain and BLOB wrapped", %{conn: conn} do
      assert {:ok, %{rows: [["text", @utf8_bytes]]}} =
               NIF.query(conn, "SELECT typeof(?1), ?1", [@utf8_bytes])

      assert {:ok, %{rows: [["blob", @utf8_bytes]]}} =
               NIF.query(conn, "SELECT typeof(?1), ?1", [%Blob{bytes: @utf8_bytes}])
    end

    test "bytes that are not UTF-8 stay BLOB either way", %{conn: conn} do
      assert {:ok, %{rows: [["blob", @raw_bytes]]}} =
               NIF.query(conn, "SELECT typeof(?1), ?1", [@raw_bytes])

      assert {:ok, %{rows: [["blob", @raw_bytes]]}} =
               NIF.query(conn, "SELECT typeof(?1), ?1", [%Blob{bytes: @raw_bytes}])
    end

    test "query_with_changes/3 binds the wrapper", %{conn: conn} do
      assert {:ok, %{rows: [["blob"]]}} =
               NIF.query_with_changes(conn, "SELECT typeof(?1)", [%Blob{bytes: @utf8_bytes}])
    end

    test "Xqlite.query/4 binds the wrapper", %{conn: conn} do
      assert {:ok, %Xqlite.Result{rows: [["blob"]]}} =
               Xqlite.query(conn, "SELECT typeof(?1)", [%Blob{bytes: @utf8_bytes}])
    end

    test "query_cancellable/4 binds the wrapper", %{conn: conn} do
      {:ok, token} = NIF.create_cancel_token()

      assert {:ok, %{rows: [["blob"]]}} =
               NIF.query_cancellable(
                 conn,
                 "SELECT typeof(?1)",
                 [%Blob{bytes: @utf8_bytes}],
                 [token]
               )
    end

    test "query_with_changes_cancellable/4 binds the wrapper", %{conn: conn} do
      {:ok, token} = NIF.create_cancel_token()

      assert {:ok, %{rows: [["blob"]]}} =
               NIF.query_with_changes_cancellable(
                 conn,
                 "SELECT typeof(?1)",
                 [%Blob{bytes: @utf8_bytes}],
                 [token]
               )
    end

    test "execute_cancellable/5 stores the wrapper as a BLOB", %{conn: conn} do
      {:ok, token} = NIF.create_cancel_token()

      assert {:ok, 1} =
               Xqlite.execute_cancellable(
                 conn,
                 "INSERT INTO blob_param (id, v) VALUES (7, ?1)",
                 [%Blob{bytes: @raw_bytes}],
                 token,
                 type_extensions: [Xqlite.TypeExtension.UUID]
               )

      assert {:ok, %{rows: [["blob", @raw_bytes]]}} =
               NIF.query(conn, "SELECT typeof(v), v FROM blob_param WHERE id = 7", [])
    end

    test "execute/3 stores the wrapper as a BLOB", %{conn: conn} do
      assert {:ok, 1} =
               NIF.execute(conn, "INSERT INTO blob_param (id, v) VALUES (1, ?1)", [
                 %Blob{bytes: @utf8_bytes}
               ])

      assert {:ok, %{rows: [["blob", @utf8_bytes]]}} =
               NIF.query(conn, "SELECT typeof(v), v FROM blob_param WHERE id = 1", [])
    end

    test "stream/4 binds the wrapper", %{conn: conn} do
      rows =
        conn
        |> Xqlite.stream("SELECT typeof(?1) AS t", [%Blob{bytes: @utf8_bytes}])
        |> Enum.to_list()

      assert rows == [%{"t" => "blob"}]
    end

    test "a prepared statement binds the wrapper", %{conn: conn} do
      assert {:ok, stmt} = Xqlite.prepare(conn, "SELECT typeof(?1)")
      assert :ok = Xqlite.bind(stmt, [%Blob{bytes: @utf8_bytes}])
      assert {:row, ["blob"]} = Xqlite.step(stmt)
      assert :ok = Xqlite.finalize(stmt)
    end

    test "explain_analyze/3 binds the wrapper", %{conn: conn} do
      assert {:ok, _report} =
               NIF.explain_analyze(conn, "INSERT INTO blob_param (id, v) VALUES (2, ?1)", [
                 %Blob{bytes: @utf8_bytes}
               ])

      assert {:ok, %{rows: [["blob", @utf8_bytes]]}} =
               NIF.query(conn, "SELECT typeof(v), v FROM blob_param WHERE id = 2", [])
    end

    # rusqlite's path: an empty slice becomes sqlite3_bind_zeroblob.
    test "an empty wrapper is a zero-length BLOB on query/3 and execute/3", %{conn: conn} do
      assert {:ok, %{rows: [["blob", 0, <<>>]]}} =
               NIF.query(conn, "SELECT typeof(?1), length(?1), ?1", [%Blob{bytes: <<>>}])

      assert {:ok, 1} =
               NIF.execute(conn, "INSERT INTO blob_param (id, v) VALUES (3, ?1)", [
                 %Blob{bytes: <<>>}
               ])

      assert {:ok, %{rows: [["blob", 0, <<>>]]}} =
               NIF.query(
                 conn,
                 "SELECT typeof(v), length(v), v FROM blob_param WHERE id = 3",
                 []
               )
    end

    # This crate's own binder: sqlite3_bind_blob with a zero length.
    test "an empty wrapper is a zero-length BLOB on the crate's own binder", %{conn: conn} do
      rows =
        conn
        |> Xqlite.stream("SELECT typeof(?1) AS t, length(?1) AS l", [%Blob{bytes: <<>>}])
        |> Enum.to_list()

      assert rows == [%{"t" => "blob", "l" => 0}]

      assert {:ok, stmt} = Xqlite.prepare(conn, "SELECT typeof(?1), length(?1), ?1")
      assert :ok = Xqlite.bind(stmt, [%Blob{bytes: <<>>}])
      assert {:row, ["blob", 0, <<>>]} = Xqlite.step(stmt)
      assert :ok = Xqlite.finalize(stmt)

      assert {:ok, _report} =
               NIF.explain_analyze(conn, "INSERT INTO blob_param (id, v) VALUES (4, ?1)", [
                 %Blob{bytes: <<>>}
               ])

      assert {:ok, %{rows: [["blob", 0]]}} =
               NIF.query(conn, "SELECT typeof(v), length(v) FROM blob_param WHERE id = 4", [])
    end

    test "a wrapper is accepted as the value of a keyword pair", %{conn: conn} do
      assert {:ok, %{rows: [["blob", @utf8_bytes]]}} =
               NIF.query(conn, "SELECT typeof(:v), :v", v: %Blob{bytes: @utf8_bytes})
    end

    # A parameter named :blob keeps working: the wrapper is a struct, so the
    # keyword-versus-positional dispatch never had to learn about it.
    test "a named parameter called :blob still binds by name", %{conn: conn} do
      assert {:ok, %{rows: [["text", @utf8_bytes]]}} =
               NIF.query(conn, "SELECT typeof(:blob), :blob", blob: @utf8_bytes)
    end

    test "a positional list whose first element is a wrapper binds every element", %{
      conn: conn
    } do
      assert {:ok, %{rows: [["blob", 7]]}} =
               NIF.query(conn, "SELECT typeof(?1), ?2", [%Blob{bytes: @utf8_bytes}, 7])
    end

    test "a wrapper counts as one parameter when a statement is bound", %{conn: conn} do
      assert {:ok, stmt} = Xqlite.prepare(conn, "SELECT typeof(?1), ?2")
      assert :ok = Xqlite.bind(stmt, [%Blob{bytes: @utf8_bytes}, 7])
      assert {:row, ["blob", 7]} = Xqlite.step(stmt)
      assert :ok = Xqlite.finalize(stmt)
    end

    # Nothing in a result row says which storage class a value came from, so
    # writing a read value straight back moves it to TEXT.
    test "a value read back is a plain binary, not a wrapper", %{conn: conn} do
      assert {:ok, 1} =
               NIF.execute(conn, "INSERT INTO blob_param (id, v) VALUES (5, ?1)", [
                 %Blob{bytes: @utf8_bytes}
               ])

      assert {:ok, %{rows: [[read_back]]}} =
               NIF.query(conn, "SELECT v FROM blob_param WHERE id = 5", [])

      assert read_back == @utf8_bytes

      assert {:ok, 1} =
               NIF.execute(conn, "INSERT INTO blob_param (id, v) VALUES (6, ?1)", [read_back])

      assert {:ok, %{rows: [["text"]]}} =
               NIF.query(conn, "SELECT typeof(v) FROM blob_param WHERE id = 6", [])
    end

    # The defect this wrapper exists for: a STRICT table's BLOB column refuses
    # the bytes when they happen to be valid UTF-8 and nothing forces the class.
    test "a STRICT BLOB column accepts the wrapper and refuses the plain bytes", %{conn: conn} do
      :ok = NIF.execute_batch(conn, "CREATE TABLE strict_blob (v BLOB NOT NULL) STRICT;")

      assert {:error, {:constraint_violation, :constraint_datatype, _}} =
               NIF.execute(conn, "INSERT INTO strict_blob (v) VALUES (?1)", [@utf8_bytes])

      assert {:ok, 1} =
               NIF.execute(conn, "INSERT INTO strict_blob (v) VALUES (?1)", [
                 %Blob{bytes: @utf8_bytes}
               ])
    end

    property "whole bytes bind as a blob of that many bytes, the rest are refused",
             %{conn: conn} do
      check all(bits <- payload_bits(), max_runs: 2000) do
        assert_bits_bind(conn, bits, rem(bit_size(bits), 8))
      end
    end

    test "a wrapper built at runtime without bytes still reaches the binder", %{conn: conn} do
      assert {:error, {:invalid_blob_bytes, %{position: 1, type: :atom}}} =
               NIF.query(conn, "SELECT ?1", [struct(Blob, [])])

      assert {:error, {:invalid_blob_bytes, %{position: 1, type: :atom}}} =
               NIF.query(conn, "SELECT ?1", [struct!(Blob, bytes: nil)])
    end
  end

  test "the wrapper cannot be built without bytes" do
    assert_raise ArgumentError, fn -> Code.eval_string("%Xqlite.Blob{}") end
    assert_raise ArgumentError, fn -> struct!(Blob, []) end
  end

  defp payload_bits do
    StreamData.scale(StreamData.bitstring(), fn size -> min(size, 64) end)
  end

  defp assert_bits_bind(conn, bits, 0) do
    bytes = div(bit_size(bits), 8)

    assert {:ok, %{rows: [["blob", ^bytes]]}} =
             NIF.query(conn, "SELECT typeof(?1), length(?1)", [%Blob{bytes: bits}])

    assert {:ok, stmt} = NIF.stmt_prepare(conn, "SELECT typeof(?1), length(?1)")
    assert :ok = NIF.stmt_bind(stmt, [%Blob{bytes: bits}])
    assert {:row, ["blob", ^bytes]} = NIF.stmt_step(stmt)
  end

  defp assert_bits_bind(conn, bits, _remainder) do
    assert {:error, {:invalid_blob_bytes, %{position: 1, type: :bitstring}}} =
             NIF.query(conn, "SELECT ?1", [%Blob{bytes: bits}])

    assert {:ok, stmt} = NIF.stmt_prepare(conn, "SELECT ?1")

    assert {:error, {:invalid_blob_bytes, %{position: 1, type: :bitstring}}} =
             NIF.stmt_bind(stmt, [%Blob{bytes: bits}])
  end
end

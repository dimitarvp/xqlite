defmodule Xqlite.TypeExtension.JSONTest do
  use ExUnit.Case, async: true

  import Xqlite.ConnCase

  alias Xqlite.TypeExtension
  alias Xqlite.TypeExtension.JSON, as: JSONExt
  alias XqliteNIF, as: NIF

  # ---------------------------------------------------------------------------
  # Unit tests: encode
  # ---------------------------------------------------------------------------

  describe "encode/1" do
    test "encodes a plain map" do
      assert {:ok, json} = JSONExt.encode(%{"a" => 1, "b" => "two"})
      assert {:ok, %{"a" => 1, "b" => "two"}} = Jason.decode(json)
    end

    test "encodes an atom-keyed map (keys become strings)" do
      assert {:ok, json} = JSONExt.encode(%{a: 1})
      assert {:ok, %{"a" => 1}} = Jason.decode(json)
    end

    test "encodes a list" do
      assert {:ok, "[1,2,3]"} = JSONExt.encode([1, 2, 3])
    end

    test "encodes an empty map and empty list" do
      assert {:ok, "{}"} = JSONExt.encode(%{})
      assert {:ok, "[]"} = JSONExt.encode([])
    end

    test "encodes nested structures" do
      assert {:ok, json} = JSONExt.encode(%{"items" => [%{"id" => 1}, %{"id" => 2}]})
      assert {:ok, %{"items" => [%{"id" => 1}, %{"id" => 2}]}} = Jason.decode(json)
    end

    test "skips structs (they belong to their own extensions)" do
      assert :skip = JSONExt.encode(~D[2024-01-15])
      assert :skip = JSONExt.encode(~U[2024-01-15 10:30:00Z])
      assert :skip = JSONExt.encode(~N[2024-01-15 10:30:00])
      assert :skip = JSONExt.encode(~T[10:30:00])
    end

    test "skips native SQLite scalar values" do
      assert :skip = JSONExt.encode(42)
      assert :skip = JSONExt.encode(3.14)
      assert :skip = JSONExt.encode("already a string")
      assert :skip = JSONExt.encode(nil)
      assert :skip = JSONExt.encode(:an_atom)
    end

    test "refuses a map whose bytes are not valid UTF-8, and says why" do
      assert {:error, {:json_encode_failed, %{reason: %Jason.EncodeError{}}}} =
               JSONExt.encode(%{"k" => <<0xFF, 0xFE>>})

      assert {:error, {:json_encode_failed, %{reason: %Jason.EncodeError{}}}} =
               JSONExt.encode(%{<<0xFF, 0xFE>> => 1})
    end

    test "refuses a map holding a term with no JSON form, and says why" do
      assert {:error, {:json_encode_failed, %{reason: %Protocol.UndefinedError{}}}} =
               JSONExt.encode(%{"k" => {1, 2}})

      assert {:error, {:json_encode_failed, %{reason: %Protocol.UndefinedError{}}}} =
               JSONExt.encode(%{"k" => self()})
    end
  end

  # ---------------------------------------------------------------------------
  # Unit tests: decode
  # ---------------------------------------------------------------------------

  describe "decode/1" do
    test "decodes a JSON object" do
      assert {:ok, %{"a" => 1}} = JSONExt.decode(~s({"a":1}))
    end

    test "decodes a JSON array" do
      assert {:ok, [1, 2, 3]} = JSONExt.decode("[1,2,3]")
    end

    test "decodes with leading whitespace before the opening brace" do
      assert {:ok, %{"a" => 1}} = JSONExt.decode("  \n\t{\"a\":1}")
    end

    test "decodes nested structures" do
      assert {:ok, %{"items" => [%{"id" => 1}]}} = JSONExt.decode(~s({"items":[{"id":1}]}))
    end

    test "skips strings that do not start with { or [" do
      assert :skip = JSONExt.decode("hello world")
      assert :skip = JSONExt.decode("42")
      assert :skip = JSONExt.decode("3.14")
      assert :skip = JSONExt.decode("2024-01-15T10:30:00Z")
      assert :skip = JSONExt.decode("")
    end

    test "skips JSON-shaped but invalid text" do
      assert :skip = JSONExt.decode("{not valid json")
      assert :skip = JSONExt.decode("[1, 2,")
    end

    test "skips non-binary values" do
      assert :skip = JSONExt.decode(42)
      assert :skip = JSONExt.decode(3.14)
      assert :skip = JSONExt.decode(nil)
      assert :skip = JSONExt.decode(%{"a" => 1})
      assert :skip = JSONExt.decode([1, 2, 3])
    end
  end

  # ---------------------------------------------------------------------------
  # Integration: round-trip through a real connection (stream + type_extensions)
  # ---------------------------------------------------------------------------

  for_each_opener "JSON round-trip" do
    setup %{conn: conn} do
      :ok =
        NIF.execute_batch(conn, """
        CREATE TABLE je_test (id INTEGER PRIMARY KEY, doc TEXT);
        """)

      :ok
    end

    test "map round-trips via encode_params + stream decode", %{conn: conn} do
      doc = %{"name" => "alice", "age" => 30, "tags" => ["x", "y"]}
      {:ok, params} = TypeExtension.encode_params([1, doc], [JSONExt])

      {:ok, 1} = NIF.execute(conn, "INSERT INTO je_test (id, doc) VALUES (?1, ?2)", params)

      [row] =
        Xqlite.stream(conn, "SELECT doc FROM je_test WHERE id = 1", [],
          type_extensions: [JSONExt]
        )
        |> Enum.to_list()

      assert row["doc"] == doc
    end

    test "list round-trips via encode_params + stream decode", %{conn: conn} do
      doc = [1, "two", %{"three" => 3}]
      {:ok, params} = TypeExtension.encode_params([2, doc], [JSONExt])

      {:ok, 1} = NIF.execute(conn, "INSERT INTO je_test (id, doc) VALUES (?1, ?2)", params)

      [row] =
        Xqlite.stream(conn, "SELECT doc FROM je_test WHERE id = 2", [],
          type_extensions: [JSONExt]
        )
        |> Enum.to_list()

      assert row["doc"] == doc
    end

    test "stream without the extension returns the raw JSON text", %{conn: conn} do
      {:ok, params} = TypeExtension.encode_params([3, %{"a" => 1}], [JSONExt])
      {:ok, 1} = NIF.execute(conn, "INSERT INTO je_test (id, doc) VALUES (?1, ?2)", params)

      [row] =
        Xqlite.stream(conn, "SELECT doc FROM je_test WHERE id = 3", [])
        |> Enum.to_list()

      assert {:ok, %{"a" => 1}} = Jason.decode(row["doc"])
    end

    test "a map the extension cannot encode is refused, naming the extension", %{conn: conn} do
      doc = %{"k" => <<0xFF, 0xFE>>}

      assert {:error,
              {:type_extension_refused,
               %{position: 2, extension: JSONExt, reason: {:json_encode_failed, %{reason: _}}}}} =
               Xqlite.execute(conn, "INSERT INTO je_test (id, doc) VALUES (?1, ?2)", [4, doc],
                 type_extensions: [JSONExt]
               )
    end

    test "the same map with no extension keeps the NIF's own refusal", %{conn: conn} do
      doc = %{"k" => <<0xFF, 0xFE>>}

      assert {:error, {:unsupported_data_type, :map}} =
               Xqlite.execute(conn, "INSERT INTO je_test (id, doc) VALUES (?1, ?2)", [5, doc])
    end
  end
end

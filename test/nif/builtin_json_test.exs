defmodule Xqlite.NIF.BuiltinJsonTest do
  use ExUnit.Case, async: true

  import Xqlite.TestUtil, only: [connection_openers: 0, find_opener_mfa!: 1]

  alias XqliteNIF, as: NIF

  for {type_tag, prefix, _opener_mfa} <- connection_openers() do
    describe "JSON1 using #{prefix}" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = find_opener_mfa!(context)
        assert {:ok, conn} = apply(mod, fun, args)

        on_exit(fn -> NIF.close(conn) end)
        {:ok, conn: conn}
      end

      # -------------------------------------------------------------------
      # json() validation and normalization
      # -------------------------------------------------------------------

      test "json() validates and normalizes a JSON string", %{conn: conn} do
        assert {:ok, %{rows: [["[1,2,3]"]]}} =
                 NIF.query(conn, "SELECT json('[1, 2,  3]')", [])
      end

      test "json() rejects malformed JSON", %{conn: conn} do
        assert {:error, _} = NIF.query(conn, "SELECT json('{bad')", [])
      end

      test "json() normalizes whitespace in objects", %{conn: conn} do
        assert {:ok, %{rows: [[normalized]]}} =
                 NIF.query(conn, ~s|SELECT json('{ "a" : 1 ,  "b" : 2 }')|, [])

        assert normalized == ~s|{"a":1,"b":2}|
      end

      test "json() accepts null literal", %{conn: conn} do
        assert {:ok, %{rows: [["null"]]}} =
                 NIF.query(conn, "SELECT json('null')", [])
      end

      test "json() accepts boolean literals", %{conn: conn} do
        assert {:ok, %{rows: [["true"]]}} =
                 NIF.query(conn, "SELECT json('true')", [])

        assert {:ok, %{rows: [["false"]]}} =
                 NIF.query(conn, "SELECT json('false')", [])
      end

      test "json() accepts bare numeric values", %{conn: conn} do
        assert {:ok, %{rows: [["42"]]}} =
                 NIF.query(conn, "SELECT json('42')", [])

        assert {:ok, %{rows: [["3.14"]]}} =
                 NIF.query(conn, "SELECT json('3.14')", [])
      end

      # -------------------------------------------------------------------
      # json_extract()
      # -------------------------------------------------------------------

      test "json_extract() extracts a nested value", %{conn: conn} do
        assert {:ok, %{rows: [["baz"]]}} =
                 NIF.query(
                   conn,
                   ~s|SELECT json_extract('{"foo":{"bar":"baz"}}', '$.foo.bar')|,
                   []
                 )
      end

      test "json_extract() returns integer from JSON", %{conn: conn} do
        assert {:ok, %{rows: [[42]]}} =
                 NIF.query(conn, ~s|SELECT json_extract('{"n":42}', '$.n')|, [])
      end

      test "json_extract() returns float from JSON", %{conn: conn} do
        assert {:ok, %{rows: [[val]]}} =
                 NIF.query(conn, ~s|SELECT json_extract('{"pi":3.14159}', '$.pi')|, [])

        assert_in_delta val, 3.14159, 0.00001
      end

      test "json_extract() returns nil for missing path", %{conn: conn} do
        assert {:ok, %{rows: [[nil]]}} =
                 NIF.query(conn, ~s|SELECT json_extract('{"a":1}', '$.b')|, [])
      end

      test "json_extract() with array index", %{conn: conn} do
        assert {:ok, %{rows: [["second"]]}} =
                 NIF.query(
                   conn,
                   ~s|SELECT json_extract('["first","second","third"]', '$[1]')|,
                   []
                 )
      end

      test "json_extract() with negative array index from end", %{conn: conn} do
        assert {:ok, %{rows: [[3]]}} =
                 NIF.query(
                   conn,
                   ~s|SELECT json_extract('[1,2,3]', '$[#-1]')|,
                   []
                 )
      end

      test "json_extract() returns boolean as integer", %{conn: conn} do
        assert {:ok, %{rows: [[1]]}} =
                 NIF.query(conn, ~s|SELECT json_extract('{"flag":true}', '$.flag')|, [])

        assert {:ok, %{rows: [[0]]}} =
                 NIF.query(conn, ~s|SELECT json_extract('{"flag":false}', '$.flag')|, [])
      end

      # -------------------------------------------------------------------
      # json_array() and json_object()
      # -------------------------------------------------------------------

      test "json_array() constructs an array from arguments", %{conn: conn} do
        assert {:ok, %{rows: [["[1,\"two\",3.0]"]]}} =
                 NIF.query(conn, "SELECT json_array(1, 'two', 3.0)", [])
      end

      test "json_array() with no arguments", %{conn: conn} do
        assert {:ok, %{rows: [["[]"]]}} =
                 NIF.query(conn, "SELECT json_array()", [])
      end

      test "json_array() with NULL", %{conn: conn} do
        assert {:ok, %{rows: [["[null]"]]}} =
                 NIF.query(conn, "SELECT json_array(NULL)", [])
      end

      test "json_object() constructs an object", %{conn: conn} do
        assert {:ok, %{rows: [[obj]]}} =
                 NIF.query(conn, "SELECT json_object('a', 1, 'b', 'two')", [])

        assert obj == ~s|{"a":1,"b":"two"}|
      end

      test "json_object() with no arguments", %{conn: conn} do
        assert {:ok, %{rows: [["{}"]]}} =
                 NIF.query(conn, "SELECT json_object()", [])
      end

      # -------------------------------------------------------------------
      # json_type()
      # -------------------------------------------------------------------

      test "json_type() identifies value types", %{conn: conn} do
        assert {:ok, %{rows: [["object"]]}} =
                 NIF.query(conn, ~s|SELECT json_type('{}')|, [])

        assert {:ok, %{rows: [["array"]]}} =
                 NIF.query(conn, ~s|SELECT json_type('[]')|, [])

        assert {:ok, %{rows: [["integer"]]}} =
                 NIF.query(conn, ~s|SELECT json_type('42')|, [])

        assert {:ok, %{rows: [["real"]]}} =
                 NIF.query(conn, ~s|SELECT json_type('3.14')|, [])

        assert {:ok, %{rows: [["text"]]}} =
                 NIF.query(conn, ~s|SELECT json_type('"hello"')|, [])

        assert {:ok, %{rows: [["null"]]}} =
                 NIF.query(conn, ~s|SELECT json_type('null')|, [])

        assert {:ok, %{rows: [["true"]]}} =
                 NIF.query(conn, ~s|SELECT json_type('true')|, [])
      end

      # -------------------------------------------------------------------
      # json_each() table-valued function
      # -------------------------------------------------------------------

      test "json_each() iterates over array elements", %{conn: conn} do
        assert {:ok, %{rows: rows}} =
                 NIF.query(
                   conn,
                   "SELECT value FROM json_each('[10, 20, 30]') ORDER BY key",
                   []
                 )

        assert rows == [[10], [20], [30]]
      end

      test "json_each() iterates over object keys", %{conn: conn} do
        assert {:ok, %{rows: rows}} =
                 NIF.query(
                   conn,
                   ~s|SELECT key, value FROM json_each('{"x":1,"y":2}') ORDER BY key|,
                   []
                 )

        assert rows == [["x", 1], ["y", 2]]
      end

      test "json_each() with path argument", %{conn: conn} do
        assert {:ok, %{rows: rows}} =
                 NIF.query(
                   conn,
                   ~s|SELECT value FROM json_each('{"items":[100,200]}', '$.items') ORDER BY key|,
                   []
                 )

        assert rows == [[100], [200]]
      end

      # -------------------------------------------------------------------
      # json_tree() deep traversal
      # -------------------------------------------------------------------

      test "json_tree() traverses nested structure", %{conn: conn} do
        assert {:ok, %{rows: rows}} =
                 NIF.query(
                   conn,
                   ~s|SELECT key, type FROM json_tree('{"a":{"b":1}}') ORDER BY id|,
                   []
                 )

        assert length(rows) >= 3
      end

      # -------------------------------------------------------------------
      # json_group_array() and json_group_object() aggregates
      # -------------------------------------------------------------------

      test "json_group_array() aggregates rows into JSON array", %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE TABLE jga (val TEXT);")
        {:ok, 1} = NIF.execute(conn, "INSERT INTO jga VALUES (?1)", ["alpha"])
        {:ok, 1} = NIF.execute(conn, "INSERT INTO jga VALUES (?1)", ["beta"])
        {:ok, 1} = NIF.execute(conn, "INSERT INTO jga VALUES (?1)", ["gamma"])

        assert {:ok, %{rows: [[result]]}} =
                 NIF.query(conn, "SELECT json_group_array(val) FROM jga", [])

        decoded = :json.decode(result)
        assert Enum.sort(decoded) == ["alpha", "beta", "gamma"]
      end

      test "json_group_object() aggregates rows into JSON object", %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE TABLE jgo (k TEXT, v INTEGER);")
        {:ok, 1} = NIF.execute(conn, "INSERT INTO jgo VALUES ('x', 1)", [])
        {:ok, 1} = NIF.execute(conn, "INSERT INTO jgo VALUES ('y', 2)", [])

        assert {:ok, %{rows: [[result]]}} =
                 NIF.query(conn, "SELECT json_group_object(k, v) FROM jgo", [])

        decoded = :json.decode(result)
        assert decoded == %{"x" => 1, "y" => 2}
      end

      # -------------------------------------------------------------------
      # json_insert(), json_replace(), json_set(), json_remove()
      # -------------------------------------------------------------------

      test "json_insert() adds new key without overwriting", %{conn: conn} do
        assert {:ok, %{rows: [[result]]}} =
                 NIF.query(
                   conn,
                   ~s|SELECT json_insert('{"a":1}', '$.b', 2, '$.a', 99)|,
                   []
                 )

        decoded = :json.decode(result)
        assert decoded["a"] == 1
        assert decoded["b"] == 2
      end

      test "json_replace() overwrites existing key only", %{conn: conn} do
        assert {:ok, %{rows: [[result]]}} =
                 NIF.query(
                   conn,
                   ~s|SELECT json_replace('{"a":1}', '$.a', 99, '$.b', 2)|,
                   []
                 )

        decoded = :json.decode(result)
        assert decoded["a"] == 99
        refute Map.has_key?(decoded, "b")
      end

      test "json_set() inserts or replaces", %{conn: conn} do
        assert {:ok, %{rows: [[result]]}} =
                 NIF.query(
                   conn,
                   ~s|SELECT json_set('{"a":1}', '$.a', 99, '$.b', 2)|,
                   []
                 )

        decoded = :json.decode(result)
        assert decoded == %{"a" => 99, "b" => 2}
      end

      test "json_remove() deletes keys", %{conn: conn} do
        assert {:ok, %{rows: [[result]]}} =
                 NIF.query(
                   conn,
                   ~s|SELECT json_remove('{"a":1,"b":2,"c":3}', '$.b')|,
                   []
                 )

        decoded = :json.decode(result)
        assert decoded == %{"a" => 1, "c" => 3}
      end

      # -------------------------------------------------------------------
      # json_valid()
      # -------------------------------------------------------------------

      test "json_valid() returns 1 for valid JSON", %{conn: conn} do
        assert {:ok, %{rows: [[1]]}} =
                 NIF.query(conn, ~s|SELECT json_valid('{"a":1}')|, [])
      end

      test "json_valid() returns 0 for invalid JSON", %{conn: conn} do
        assert {:ok, %{rows: [[0]]}} =
                 NIF.query(conn, ~s|SELECT json_valid('{bad}')|, [])
      end

      test "json_valid() returns 0 for plain string", %{conn: conn} do
        assert {:ok, %{rows: [[0]]}} =
                 NIF.query(conn, ~s|SELECT json_valid('hello')|, [])
      end

      test "json_valid() returns 0 for NULL", %{conn: conn} do
        assert {:ok, %{rows: [[nil]]}} =
                 NIF.query(conn, "SELECT json_valid(NULL)", [])
      end

      # -------------------------------------------------------------------
      # JSON stored in tables — round-trip through NIF serialization
      # -------------------------------------------------------------------

      test "JSON stored in TEXT column round-trips correctly", %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE TABLE jrt (id INTEGER PRIMARY KEY, data TEXT);")
        json_in = ~s|{"key":"value","nums":[1,2,3],"nested":{"deep":true}}|

        {:ok, 1} = NIF.execute(conn, "INSERT INTO jrt VALUES (1, ?1)", [json_in])

        assert {:ok, %{rows: [[1, json_out]]}} =
                 NIF.query(conn, "SELECT * FROM jrt WHERE id = 1", [])

        assert :json.decode(json_out) == :json.decode(json_in)
      end

      test "json_extract() works on stored column data", %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE TABLE je_store (doc TEXT);")

        {:ok, 1} =
          NIF.execute(
            conn,
            "INSERT INTO je_store VALUES (?1)",
            [~s|{"user":"alice","age":30,"tags":["admin","dev"]}|]
          )

        assert {:ok, %{rows: [["alice"]]}} =
                 NIF.query(conn, "SELECT json_extract(doc, '$.user') FROM je_store", [])

        assert {:ok, %{rows: [[30]]}} =
                 NIF.query(conn, "SELECT json_extract(doc, '$.age') FROM je_store", [])

        assert {:ok, %{rows: [["admin"]]}} =
                 NIF.query(conn, "SELECT json_extract(doc, '$.tags[0]') FROM je_store", [])
      end

      # -------------------------------------------------------------------
      # Edge cases — Unicode, escaping, large payloads
      # -------------------------------------------------------------------

      test "JSON with Unicode characters round-trips", %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE TABLE juni (data TEXT);")
        json_in = ~s|{"emoji":"🎉","cjk":"日本語","math":"∑∫∂"}|

        {:ok, 1} = NIF.execute(conn, "INSERT INTO juni VALUES (?1)", [json_in])

        assert {:ok, %{rows: [[json_out]]}} =
                 NIF.query(conn, "SELECT data FROM juni", [])

        assert :json.decode(json_out) == :json.decode(json_in)
      end

      test "JSON with escaped characters", %{conn: conn} do
        assert {:ok, %{rows: [[result]]}} =
                 NIF.query(
                   conn,
                   ~s|SELECT json_extract('{"msg":"line1\\nline2\\ttab"}', '$.msg')|,
                   []
                 )

        assert result == "line1\nline2\ttab"
      end

      test "deeply nested JSON", %{conn: conn} do
        deep = ~s|{"a":{"b":{"c":{"d":{"e":{"f":"deep"}}}}}}|

        assert {:ok, %{rows: [["deep"]]}} =
                 NIF.query(
                   conn,
                   "SELECT json_extract(?1, '$.a.b.c.d.e.f')",
                   [deep]
                 )
      end

      test "JSON array with mixed types", %{conn: conn} do
        assert {:ok, %{rows: [[result]]}} =
                 NIF.query(
                   conn,
                   ~s|SELECT json_array(1, 'two', 3.0, NULL, json('true'), json_array(4,5))|,
                   []
                 )

        decoded = :json.decode(result)
        assert length(decoded) == 6
        assert Enum.at(decoded, 0) == 1
        assert Enum.at(decoded, 1) == "two"
        assert Enum.at(decoded, 3) == :null
        assert Enum.at(decoded, 4) == true
        assert Enum.at(decoded, 5) == [4, 5]
      end

      test "large JSON object with many keys", %{conn: conn} do
        pairs =
          1..100
          |> Enum.map(fn i -> ~s|"key_#{i}":#{i}| end)
          |> Enum.join(",")

        big_json = "{#{pairs}}"

        assert {:ok, %{rows: [[1]]}} =
                 NIF.query(conn, "SELECT json_valid(?1)", [big_json])

        assert {:ok, %{rows: [[100]]}} =
                 NIF.query(conn, "SELECT json_extract(?1, '$.key_100')", [big_json])
      end

      test "json_patch() merges two objects", %{conn: conn} do
        assert {:ok, %{rows: [[result]]}} =
                 NIF.query(
                   conn,
                   ~s|SELECT json_patch('{"a":1,"b":2}', '{"b":99,"c":3}')|,
                   []
                 )

        decoded = :json.decode(result)
        assert decoded == %{"a" => 1, "b" => 99, "c" => 3}
      end

      test "json_patch() can delete keys with null", %{conn: conn} do
        assert {:ok, %{rows: [[result]]}} =
                 NIF.query(
                   conn,
                   ~s|SELECT json_patch('{"a":1,"b":2}', '{"b":null}')|,
                   []
                 )

        decoded = :json.decode(result)
        assert decoded == %{"a" => 1}
      end
    end
  end
end

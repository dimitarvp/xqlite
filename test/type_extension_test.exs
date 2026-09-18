defmodule Xqlite.TypeExtensionTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Xqlite.TestUtil
  alias Xqlite.TypeExtension
  alias XqliteNIF, as: NIF

  @all_extensions [
    Xqlite.TypeExtension.DateTime,
    Xqlite.TypeExtension.NaiveDateTime,
    Xqlite.TypeExtension.Date,
    Xqlite.TypeExtension.Time
  ]

  # ---------------------------------------------------------------------------
  # Test helpers: custom extensions for testing chain behaviour
  # ---------------------------------------------------------------------------

  defmodule SkipAllExtension do
    @behaviour TypeExtension

    @impl true
    def encode(_), do: :skip

    @impl true
    def decode(_), do: :skip
  end

  defmodule IntDoubler do
    @behaviour TypeExtension

    @impl true
    def encode(value) when is_integer(value), do: {:ok, value * 2}
    def encode(_), do: :skip

    @impl true
    def decode(value) when is_integer(value), do: {:ok, div(value, 2)}
    def decode(_), do: :skip
  end

  defmodule StringUppercase do
    @behaviour TypeExtension

    @impl true
    def encode(value) when is_binary(value), do: {:ok, String.upcase(value)}
    def encode(_), do: :skip

    @impl true
    def decode(value) when is_binary(value), do: {:ok, String.downcase(value)}
    def decode(_), do: :skip
  end

  # Claims the marker atom and refuses it: the third answer of the callback.
  defmodule Refuser do
    @behaviour TypeExtension

    @marker :refuse_me

    def marker, do: @marker

    @impl true
    def encode(@marker), do: {:error, :nope}
    def encode(_), do: :skip

    @impl true
    def decode(_), do: :skip
  end

  # ---------------------------------------------------------------------------
  # Unit tests: DateTime extension
  # ---------------------------------------------------------------------------

  describe "Xqlite.TypeExtension.DateTime" do
    alias Xqlite.TypeExtension.DateTime, as: DTExt

    test "encode DateTime struct" do
      dt = ~U[2024-01-15 10:30:00Z]
      assert {:ok, "2024-01-15T10:30:00Z"} = DTExt.encode(dt)
    end

    test "encode DateTime with microseconds" do
      dt = ~U[2024-01-15 10:30:00.123456Z]
      assert {:ok, "2024-01-15T10:30:00.123456Z"} = DTExt.encode(dt)
    end

    test "encode DateTime with non-UTC offset" do
      {:ok, dt} = DateTime.new(~D[2024-06-15], ~T[14:30:00], "Etc/UTC")
      assert {:ok, "2024-06-15T14:30:00Z"} = DTExt.encode(dt)
    end

    test "encode skips non-DateTime values" do
      assert :skip = DTExt.encode(42)
      assert :skip = DTExt.encode("hello")
      assert :skip = DTExt.encode(nil)
      assert :skip = DTExt.encode(~N[2024-01-15 10:30:00])
      assert :skip = DTExt.encode(~D[2024-01-15])
      assert :skip = DTExt.encode(~T[10:30:00])
      assert :skip = DTExt.encode(3.14)
      assert :skip = DTExt.encode([])
      assert :skip = DTExt.encode(%{})
    end

    test "decode ISO 8601 string to DateTime" do
      assert {:ok, ~U[2024-01-15 10:30:00Z]} = DTExt.decode("2024-01-15T10:30:00Z")
    end

    test "decode ISO 8601 string with microseconds" do
      assert {:ok, ~U[2024-01-15 10:30:00.123456Z]} =
               DTExt.decode("2024-01-15T10:30:00.123456Z")
    end

    test "decode ISO 8601 string with positive offset normalizes to UTC" do
      assert {:ok, dt} = DTExt.decode("2024-01-15T10:30:00+02:00")
      assert dt.hour == 8
      assert dt.utc_offset == 0
    end

    test "decode ISO 8601 string with negative offset normalizes to UTC" do
      assert {:ok, dt} = DTExt.decode("2024-01-15T10:30:00-05:00")
      assert dt.hour == 15
      assert dt.utc_offset == 0
    end

    test "the offset is written but the value reads back as UTC" do
      dt = offset_datetime(2024, 3, 15, 10, 30, 0, 123_456, 7200)

      assert {:ok, text} = DTExt.encode(dt)
      assert String.ends_with?(text, "+02:00")

      assert {:ok, decoded} = DTExt.decode(text)
      assert DateTime.compare(decoded, dt) == :eq
      assert decoded.utc_offset == 0
      assert decoded.std_offset == 0
    end

    property "any offset round-trips to the same instant, normalized to UTC" do
      check all(
              offset_minutes <- StreamData.integer(-840..840),
              year <- StreamData.integer(1970..2100),
              month <- StreamData.integer(1..12),
              day <- StreamData.integer(1..28),
              hour <- StreamData.integer(0..23),
              minute <- StreamData.integer(0..59),
              second <- StreamData.integer(0..59),
              microsecond <- StreamData.integer(0..999_999),
              max_runs: 2000
            ) do
        dt =
          offset_datetime(
            year,
            month,
            day,
            hour,
            minute,
            second,
            microsecond,
            offset_minutes * 60
          )

        assert {:ok, text} = DTExt.encode(dt)
        assert {:ok, decoded} = DTExt.decode(text)
        assert DateTime.compare(decoded, dt) == :eq
        assert decoded.utc_offset == 0
        assert decoded.std_offset == 0
      end
    end

    test "decode skips non-ISO 8601 strings" do
      assert :skip = DTExt.decode("hello world")
      assert :skip = DTExt.decode("not-a-date")
      assert :skip = DTExt.decode("")
    end

    test "decode skips non-string values" do
      assert :skip = DTExt.decode(42)
      assert :skip = DTExt.decode(3.14)
      assert :skip = DTExt.decode(nil)
      assert :skip = DTExt.decode([])
    end
  end

  # ---------------------------------------------------------------------------
  # Unit tests: NaiveDateTime extension
  # ---------------------------------------------------------------------------

  describe "Xqlite.TypeExtension.NaiveDateTime" do
    alias Xqlite.TypeExtension.NaiveDateTime, as: NDTExt

    test "encode NaiveDateTime struct" do
      ndt = ~N[2024-01-15 10:30:00]
      assert {:ok, "2024-01-15T10:30:00"} = NDTExt.encode(ndt)
    end

    test "encode NaiveDateTime with microseconds" do
      ndt = ~N[2024-01-15 10:30:00.654321]
      assert {:ok, "2024-01-15T10:30:00.654321"} = NDTExt.encode(ndt)
    end

    test "encode skips non-NaiveDateTime values" do
      assert :skip = NDTExt.encode(42)
      assert :skip = NDTExt.encode("hello")
      assert :skip = NDTExt.encode(nil)
      assert :skip = NDTExt.encode(~U[2024-01-15 10:30:00Z])
      assert :skip = NDTExt.encode(~D[2024-01-15])
      assert :skip = NDTExt.encode(~T[10:30:00])
    end

    test "decode ISO 8601 string to NaiveDateTime" do
      assert {:ok, ~N[2024-01-15 10:30:00]} = NDTExt.decode("2024-01-15T10:30:00")
    end

    test "decode ISO 8601 string with microseconds" do
      assert {:ok, ~N[2024-01-15 10:30:00.654321]} =
               NDTExt.decode("2024-01-15T10:30:00.654321")
    end

    test "decode skips non-ISO 8601 strings" do
      assert :skip = NDTExt.decode("hello world")
      assert :skip = NDTExt.decode("not-a-date")
      assert :skip = NDTExt.decode("")
    end

    test "decode skips non-string values" do
      assert :skip = NDTExt.decode(42)
      assert :skip = NDTExt.decode(3.14)
      assert :skip = NDTExt.decode(nil)
    end
  end

  # ---------------------------------------------------------------------------
  # Unit tests: Date extension
  # ---------------------------------------------------------------------------

  describe "Xqlite.TypeExtension.Date" do
    alias Xqlite.TypeExtension.Date, as: DExt

    test "encode Date struct" do
      assert {:ok, "2024-01-15"} = DExt.encode(~D[2024-01-15])
    end

    test "encode leap day" do
      assert {:ok, "2024-02-29"} = DExt.encode(~D[2024-02-29])
    end

    test "encode skips non-Date values" do
      assert :skip = DExt.encode(42)
      assert :skip = DExt.encode("2024-01-15")
      assert :skip = DExt.encode(nil)
      assert :skip = DExt.encode(~N[2024-01-15 10:30:00])
      assert :skip = DExt.encode(~U[2024-01-15 10:30:00Z])
      assert :skip = DExt.encode(~T[10:30:00])
    end

    test "decode YYYY-MM-DD string to Date" do
      assert {:ok, ~D[2024-01-15]} = DExt.decode("2024-01-15")
    end

    test "decode leap day" do
      assert {:ok, ~D[2024-02-29]} = DExt.decode("2024-02-29")
    end

    test "decode skips invalid date strings" do
      assert :skip = DExt.decode("2024-13-01")
      assert :skip = DExt.decode("2023-02-29")
      assert :skip = DExt.decode("hello")
      assert :skip = DExt.decode("")
    end

    test "decode skips non-string values" do
      assert :skip = DExt.decode(42)
      assert :skip = DExt.decode(3.14)
      assert :skip = DExt.decode(nil)
    end
  end

  # ---------------------------------------------------------------------------
  # Unit tests: Time extension
  # ---------------------------------------------------------------------------

  describe "Xqlite.TypeExtension.Time" do
    alias Xqlite.TypeExtension.Time, as: TExt

    test "encode Time struct" do
      assert {:ok, "10:30:00"} = TExt.encode(~T[10:30:00])
    end

    test "encode Time with microseconds" do
      assert {:ok, "10:30:00.123456"} = TExt.encode(~T[10:30:00.123456])
    end

    test "encode midnight" do
      assert {:ok, "00:00:00"} = TExt.encode(~T[00:00:00])
    end

    test "encode end of day" do
      assert {:ok, "23:59:59"} = TExt.encode(~T[23:59:59])
    end

    test "encode skips non-Time values" do
      assert :skip = TExt.encode(42)
      assert :skip = TExt.encode("10:30:00")
      assert :skip = TExt.encode(nil)
      assert :skip = TExt.encode(~D[2024-01-15])
      assert :skip = TExt.encode(~N[2024-01-15 10:30:00])
    end

    test "decode HH:MM:SS string to Time" do
      assert {:ok, ~T[10:30:00]} = TExt.decode("10:30:00")
    end

    test "decode Time with microseconds" do
      assert {:ok, ~T[10:30:00.123456]} = TExt.decode("10:30:00.123456")
    end

    test "decode midnight" do
      assert {:ok, ~T[00:00:00]} = TExt.decode("00:00:00")
    end

    test "decode skips invalid time strings" do
      assert :skip = TExt.decode("25:00:00")
      assert :skip = TExt.decode("hello")
      assert :skip = TExt.decode("")
    end

    test "decode skips non-string values" do
      assert :skip = TExt.decode(42)
      assert :skip = TExt.decode(3.14)
      assert :skip = TExt.decode(nil)
    end
  end

  # ---------------------------------------------------------------------------
  # Unit tests: TypeExtension chain helpers
  # ---------------------------------------------------------------------------

  describe "encode_value/2" do
    test "returns original value when no extensions" do
      assert TypeExtension.encode_value(42, []) == {:ok, 42}
      assert TypeExtension.encode_value("hello", []) == {:ok, "hello"}
      assert TypeExtension.encode_value(nil, []) == {:ok, nil}
    end

    test "first matching extension wins" do
      value = 10
      assert TypeExtension.encode_value(value, [IntDoubler, SkipAllExtension]) == {:ok, 20}
    end

    test "skips non-matching extensions and tries next" do
      assert TypeExtension.encode_value("hello", [IntDoubler, StringUppercase]) ==
               {:ok, "HELLO"}
    end

    test "returns original value when all extensions skip" do
      assert TypeExtension.encode_value(:an_atom, [IntDoubler, StringUppercase]) ==
               {:ok, :an_atom}
    end

    test "single extension that matches" do
      assert TypeExtension.encode_value(5, [IntDoubler]) == {:ok, 10}
    end

    test "single extension that skips" do
      assert TypeExtension.encode_value("hi", [IntDoubler]) == {:ok, "hi"}
    end

    test "a refusal stops the chain and names the extension" do
      assert TypeExtension.encode_value(Refuser.marker(), [Refuser, IntDoubler]) ==
               {:error, %{extension: Refuser, reason: :nope}}
    end

    test "a value that is itself an error tuple is data, not a refusal" do
      assert TypeExtension.encode_value({:error, :boom}, [IntDoubler]) ==
               {:ok, {:error, :boom}}
    end
  end

  describe "decode_value/2" do
    test "returns original value when no extensions" do
      assert TypeExtension.decode_value(42, []) == 42
    end

    test "first matching extension wins" do
      assert TypeExtension.decode_value(20, [IntDoubler, SkipAllExtension]) == 10
    end

    test "skips non-matching and tries next" do
      assert TypeExtension.decode_value("HELLO", [IntDoubler, StringUppercase]) == "hello"
    end

    test "returns original value when all extensions skip" do
      assert TypeExtension.decode_value(nil, [IntDoubler, StringUppercase]) == nil
    end
  end

  describe "encode_params/2" do
    test "empty list unchanged" do
      assert TypeExtension.encode_params([], [IntDoubler]) == {:ok, []}
    end

    test "no extensions returns params unchanged" do
      assert TypeExtension.encode_params([1, 2, 3], []) == {:ok, [1, 2, 3]}
    end

    test "nil params are accepted and stay nil" do
      assert TypeExtension.encode_params(nil, [IntDoubler]) == {:ok, nil}
      assert TypeExtension.encode_params(nil, []) == {:ok, nil}
    end

    test "encodes positional params" do
      assert TypeExtension.encode_params([5, "hi"], [IntDoubler, StringUppercase]) ==
               {:ok, [10, "HI"]}
    end

    test "encodes keyword params preserving keys" do
      params = [id: 5, name: "hello"]
      result = TypeExtension.encode_params(params, [IntDoubler, StringUppercase])
      assert result == {:ok, [id: 10, name: "HELLO"]}
    end

    test "mixed types with partial matching" do
      params = [42, "text", nil, 3.14]
      result = TypeExtension.encode_params(params, [IntDoubler])
      assert result == {:ok, [84, "text", nil, 3.14]}
    end

    test "DateTime encoding in params" do
      dt = ~U[2024-01-15 10:30:00Z]
      params = [1, dt, "other"]

      result =
        TypeExtension.encode_params(params, [
          Xqlite.TypeExtension.DateTime,
          Xqlite.TypeExtension.Date
        ])

      assert result == {:ok, [1, "2024-01-15T10:30:00Z", "other"]}
    end

    test "Date encoding in keyword params" do
      params = [start: ~D[2024-01-15], end: ~D[2024-12-31]]
      result = TypeExtension.encode_params(params, [Xqlite.TypeExtension.Date])
      assert result == {:ok, [start: "2024-01-15", end: "2024-12-31"]}
    end

    # Positional or keyword is decided once, from the first element, exactly as
    # the NIF decides it. A blob wrapper is a struct, so a list that starts with
    # one is positional and every later element is still encoded.
    test "a positional list starting with a blob wrapper encodes every later element" do
      wrapper = %Xqlite.Blob{bytes: <<1, 2>>}

      assert TypeExtension.encode_params([wrapper, 5], [IntDoubler]) == {:ok, [wrapper, 10]}
    end

    test "a keyword list encodes every pair's value, whatever its key" do
      params = [{:a, 5}, {"b", 5}]

      assert TypeExtension.encode_params(params, [IntDoubler]) == {:ok, [{:a, 10}, {"b", 10}]}
    end
  end

  describe "encode_params/2 refusals" do
    test "a refused positional parameter reports its 1-based position" do
      params = [1, Refuser.marker(), 3]

      assert TypeExtension.encode_params(params, [Refuser]) ==
               {:error,
                {:type_extension_refused, %{position: 2, extension: Refuser, reason: :nope}}}
    end

    test "a refused keyword parameter reports the pair's position" do
      params = [a: 1, b: Refuser.marker()]

      assert TypeExtension.encode_params(params, [Refuser]) ==
               {:error,
                {:type_extension_refused, %{position: 2, extension: Refuser, reason: :nope}}}
    end

    test "a blob wrapper counts as one position" do
      params = [%Xqlite.Blob{bytes: <<1>>}, 2, Refuser.marker()]

      assert {:error, {:type_extension_refused, %{position: 3}}} =
               TypeExtension.encode_params(params, [Refuser])
    end

    test "the first extension that answers decides" do
      params = [Refuser.marker()]

      assert {:ok, [_]} = TypeExtension.encode_params(params, [SkipAllExtension, IntDoubler])

      assert {:error, {:type_extension_refused, %{extension: Refuser}}} =
               TypeExtension.encode_params(params, [SkipAllExtension, Refuser])
    end

    test "a parameter that is itself an error tuple is encoded, not read as a refusal" do
      params = [{:error, :boom}]

      assert TypeExtension.encode_params(params, [Refuser]) == {:ok, [{:error, :boom}]}
    end

    property "the reported position is the refused parameter's own place in the list" do
      check all(
              before <- StreamData.list_of(StreamData.integer(), max_length: 8),
              rest <- StreamData.list_of(StreamData.integer(), max_length: 8),
              max_runs: 2000
            ) do
        params = before ++ [Refuser.marker()] ++ rest
        expected = length(before) + 1

        assert {:error, {:type_extension_refused, %{position: ^expected, reason: :nope}}} =
                 TypeExtension.encode_params(params, [IntDoubler, Refuser])
      end
    end
  end

  describe "decode_rows/2" do
    test "empty rows unchanged" do
      assert TypeExtension.decode_rows([], [IntDoubler]) == []
    end

    test "no extensions returns rows unchanged" do
      rows = [[1, "hello"], [2, "world"]]
      assert TypeExtension.decode_rows(rows, []) == rows
    end

    test "decodes every cell in every row" do
      rows = [[10, "HELLO"], [20, "WORLD"]]
      result = TypeExtension.decode_rows(rows, [IntDoubler, StringUppercase])
      assert result == [[5, "hello"], [10, "world"]]
    end

    test "nil values pass through" do
      rows = [[10, nil, "TEXT"]]
      result = TypeExtension.decode_rows(rows, [IntDoubler, StringUppercase])
      assert result == [[5, nil, "text"]]
    end
  end

  # ---------------------------------------------------------------------------
  # Unit tests: extension ordering
  # ---------------------------------------------------------------------------

  describe "extension ordering" do
    alias Xqlite.TypeExtension.DateTime, as: DTExt
    alias Xqlite.TypeExtension.NaiveDateTime, as: NDTExt

    test "DateTime before NaiveDateTime: timezone string decoded as DateTime" do
      result = TypeExtension.decode_value("2024-01-15T10:30:00Z", [DTExt, NDTExt])
      assert %DateTime{} = result
    end

    test "NaiveDateTime before DateTime: timezone string decoded as NaiveDateTime" do
      result = TypeExtension.decode_value("2024-01-15T10:30:00Z", [NDTExt, DTExt])
      assert %NaiveDateTime{} = result
    end

    test "NaiveDateTime-only string: NaiveDateTime wins regardless of order" do
      value = "2024-01-15T10:30:00"
      assert %NaiveDateTime{} = TypeExtension.decode_value(value, [DTExt, NDTExt])
      assert %NaiveDateTime{} = TypeExtension.decode_value(value, [NDTExt, DTExt])
    end

    test "Date before DateTime: date-only string decoded as Date, not DateTime" do
      alias Xqlite.TypeExtension.Date, as: DExt

      result = TypeExtension.decode_value("2024-01-15", [DExt, DTExt])
      assert %Date{} = result
    end
  end

  # ---------------------------------------------------------------------------
  # Unit tests: all four built-in extensions together
  # ---------------------------------------------------------------------------

  describe "all built-in extensions" do
    test "encode each built-in type" do
      params = [
        ~U[2024-01-15 10:30:00Z],
        ~N[2024-01-15 10:30:00],
        ~D[2024-01-15],
        ~T[10:30:00]
      ]

      result = TypeExtension.encode_params(params, @all_extensions)

      assert result ==
               {:ok,
                [
                  "2024-01-15T10:30:00Z",
                  "2024-01-15T10:30:00",
                  "2024-01-15",
                  "10:30:00"
                ]}
    end

    test "native SQLite values pass through encode unchanged" do
      params = [42, 3.14, "plain text", nil]
      result = TypeExtension.encode_params(params, @all_extensions)
      assert result == {:ok, [42, 3.14, "plain text", nil]}
    end

    test "integers and floats pass through decode unchanged" do
      rows = [[42, 3.14, nil]]
      result = TypeExtension.decode_rows(rows, @all_extensions)
      assert result == [[42, 3.14, nil]]
    end
  end

  # ---------------------------------------------------------------------------
  # Integration tests: round-trip through SQLite (connection_openers loop)
  # ---------------------------------------------------------------------------

  for {type_tag, prefix, _opener_mfa} <- TestUtil.connection_openers() do
    describe "round-trip using #{prefix}" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = TestUtil.find_opener_mfa!(context)
        assert {:ok, conn} = apply(mod, fun, args)

        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE type_ext_test (
            id INTEGER PRIMARY KEY,
            dt_val TEXT,
            ndt_val TEXT,
            d_val TEXT,
            t_val TEXT,
            int_val INTEGER,
            float_val REAL,
            plain_text TEXT
          );
          """)

        on_exit(fn -> NIF.close(conn) end)
        {:ok, conn: conn}
      end

      test "DateTime round-trip via query", %{conn: conn} do
        dt = ~U[2024-06-15 14:30:00.123456Z]
        encoded = DateTime.to_iso8601(dt)

        {:ok, 1} =
          NIF.execute(conn, "INSERT INTO type_ext_test (id, dt_val) VALUES (?1, ?2)", [
            1,
            encoded
          ])

        {:ok, %{rows: [[stored]]}} =
          NIF.query(conn, "SELECT dt_val FROM type_ext_test WHERE id = 1", [])

        assert stored == "2024-06-15T14:30:00.123456Z"

        decoded = TypeExtension.decode_value(stored, [Xqlite.TypeExtension.DateTime])
        assert decoded == dt
      end

      test "DateTime round-trip with encode_params", %{conn: conn} do
        dt = ~U[2024-01-15 10:30:00Z]
        extensions = [Xqlite.TypeExtension.DateTime]
        {:ok, params} = TypeExtension.encode_params([1, dt], extensions)

        {:ok, 1} =
          NIF.execute(conn, "INSERT INTO type_ext_test (id, dt_val) VALUES (?1, ?2)", params)

        {:ok, %{rows: [[raw]]}} =
          NIF.query(conn, "SELECT dt_val FROM type_ext_test WHERE id = 1", [])

        assert TypeExtension.decode_value(raw, extensions) == dt
      end

      test "NaiveDateTime round-trip", %{conn: conn} do
        ndt = ~N[2024-03-20 08:45:30.654321]
        extensions = [Xqlite.TypeExtension.NaiveDateTime]
        {:ok, params} = TypeExtension.encode_params([1, ndt], extensions)

        {:ok, 1} =
          NIF.execute(conn, "INSERT INTO type_ext_test (id, ndt_val) VALUES (?1, ?2)", params)

        {:ok, %{rows: [[raw]]}} =
          NIF.query(conn, "SELECT ndt_val FROM type_ext_test WHERE id = 1", [])

        assert TypeExtension.decode_value(raw, extensions) == ndt
      end

      test "Date round-trip", %{conn: conn} do
        d = ~D[2024-02-29]
        extensions = [Xqlite.TypeExtension.Date]
        {:ok, params} = TypeExtension.encode_params([1, d], extensions)

        {:ok, 1} =
          NIF.execute(conn, "INSERT INTO type_ext_test (id, d_val) VALUES (?1, ?2)", params)

        {:ok, %{rows: [[raw]]}} =
          NIF.query(conn, "SELECT d_val FROM type_ext_test WHERE id = 1", [])

        assert TypeExtension.decode_value(raw, extensions) == d
      end

      test "Time round-trip", %{conn: conn} do
        t = ~T[23:59:59.999999]
        extensions = [Xqlite.TypeExtension.Time]
        {:ok, params} = TypeExtension.encode_params([1, t], extensions)

        {:ok, 1} =
          NIF.execute(conn, "INSERT INTO type_ext_test (id, t_val) VALUES (?1, ?2)", params)

        {:ok, %{rows: [[raw]]}} =
          NIF.query(conn, "SELECT t_val FROM type_ext_test WHERE id = 1", [])

        assert TypeExtension.decode_value(raw, extensions) == t
      end

      test "all four types in one row", %{conn: conn} do
        dt = ~U[2024-01-15 10:30:00Z]
        ndt = ~N[2024-06-15 14:00:00]
        d = ~D[2024-12-25]
        t = ~T[08:00:00]

        extensions = [
          Xqlite.TypeExtension.DateTime,
          Xqlite.TypeExtension.NaiveDateTime,
          Xqlite.TypeExtension.Date,
          Xqlite.TypeExtension.Time
        ]

        {:ok, params} = TypeExtension.encode_params([1, dt, ndt, d, t], extensions)

        {:ok, 1} =
          NIF.execute(
            conn,
            "INSERT INTO type_ext_test (id, dt_val, ndt_val, d_val, t_val) VALUES (?1, ?2, ?3, ?4, ?5)",
            params
          )

        {:ok, %{rows: [row]}} =
          NIF.query(
            conn,
            "SELECT dt_val, ndt_val, d_val, t_val FROM type_ext_test WHERE id = 1",
            []
          )

        decoded = Enum.map(row, fn val -> TypeExtension.decode_value(val, extensions) end)
        assert decoded == [dt, ndt, d, t]
      end

      test "mixed types: extensions only affect matching values", %{conn: conn} do
        extensions = [Xqlite.TypeExtension.DateTime]
        dt = ~U[2024-01-15 10:30:00Z]

        {:ok, params} = TypeExtension.encode_params([1, dt, 42, 3.14, "plain"], extensions)

        {:ok, 1} =
          NIF.execute(
            conn,
            "INSERT INTO type_ext_test (id, dt_val, int_val, float_val, plain_text) VALUES (?1, ?2, ?3, ?4, ?5)",
            params
          )

        {:ok, %{rows: [row]}} =
          NIF.query(
            conn,
            "SELECT dt_val, int_val, float_val, plain_text FROM type_ext_test WHERE id = 1",
            []
          )

        [dt_raw, int_val, float_val, text_val] = row
        assert TypeExtension.decode_value(dt_raw, extensions) == dt
        assert int_val == 42
        assert float_val == 3.14
        assert text_val == "plain"
      end

      test "NULL values survive round-trip with extensions", %{conn: conn} do
        extensions = [
          Xqlite.TypeExtension.DateTime,
          Xqlite.TypeExtension.Date
        ]

        {:ok, 1} =
          NIF.execute(
            conn,
            "INSERT INTO type_ext_test (id, dt_val, d_val) VALUES (?1, ?2, ?3)",
            [1, nil, nil]
          )

        {:ok, %{rows: [[dt_raw, d_raw]]}} =
          NIF.query(
            conn,
            "SELECT dt_val, d_val FROM type_ext_test WHERE id = 1",
            []
          )

        assert TypeExtension.decode_value(dt_raw, extensions) == nil
        assert TypeExtension.decode_value(d_raw, extensions) == nil
      end

      test "no extensions: raw strings returned as-is", %{conn: conn} do
        {:ok, 1} =
          NIF.execute(
            conn,
            "INSERT INTO type_ext_test (id, dt_val) VALUES (?1, ?2)",
            [1, "2024-01-15T10:30:00Z"]
          )

        {:ok, %{rows: [[raw]]}} =
          NIF.query(conn, "SELECT dt_val FROM type_ext_test WHERE id = 1", [])

        assert raw == "2024-01-15T10:30:00Z"
        assert TypeExtension.decode_value(raw, []) == "2024-01-15T10:30:00Z"
      end

      test "stream with type_extensions option", %{conn: conn} do
        dt = ~U[2024-01-15 10:30:00Z]
        d = ~D[2024-06-15]
        encoded_dt = DateTime.to_iso8601(dt)
        encoded_d = Date.to_iso8601(d)

        {:ok, 1} =
          NIF.execute(
            conn,
            "INSERT INTO type_ext_test (id, dt_val, d_val, int_val) VALUES (?1, ?2, ?3, ?4)",
            [1, encoded_dt, encoded_d, 42]
          )

        results =
          Xqlite.stream(
            conn,
            "SELECT dt_val, d_val, int_val FROM type_ext_test WHERE id = 1",
            [],
            type_extensions: [
              Xqlite.TypeExtension.DateTime,
              Xqlite.TypeExtension.Date
            ]
          )
          |> Enum.to_list()

        assert [row] = results
        assert row["dt_val"] == dt
        assert row["d_val"] == d
        assert row["int_val"] == 42
      end

      test "stream with type_extensions encodes params", %{conn: conn} do
        dt = ~U[2024-01-15 10:30:00Z]
        encoded_dt = DateTime.to_iso8601(dt)

        {:ok, 1} =
          NIF.execute(
            conn,
            "INSERT INTO type_ext_test (id, dt_val) VALUES (?1, ?2)",
            [1, encoded_dt]
          )

        extensions = [Xqlite.TypeExtension.DateTime]

        results =
          Xqlite.stream(
            conn,
            "SELECT dt_val FROM type_ext_test WHERE dt_val = ?1",
            [dt],
            type_extensions: extensions
          )
          |> Enum.to_list()

        assert [%{"dt_val" => ^dt}] = results
      end

      test "stream without type_extensions returns raw strings", %{conn: conn} do
        {:ok, 1} =
          NIF.execute(
            conn,
            "INSERT INTO type_ext_test (id, dt_val) VALUES (?1, ?2)",
            [1, "2024-01-15T10:30:00Z"]
          )

        results =
          Xqlite.stream(conn, "SELECT dt_val FROM type_ext_test WHERE id = 1")
          |> Enum.to_list()

        assert [%{"dt_val" => "2024-01-15T10:30:00Z"}] = results
      end

      test "multiple rows decoded correctly via stream", %{conn: conn} do
        dates = [~D[2024-01-01], ~D[2024-06-15], ~D[2024-12-31]]

        dates
        |> Enum.with_index(1)
        |> Enum.each(fn {d, i} ->
          {:ok, 1} =
            NIF.execute(
              conn,
              "INSERT INTO type_ext_test (id, d_val) VALUES (?1, ?2)",
              [i, Date.to_iso8601(d)]
            )
        end)

        results =
          Xqlite.stream(
            conn,
            "SELECT d_val FROM type_ext_test WHERE d_val IS NOT NULL ORDER BY id",
            [],
            type_extensions: [Xqlite.TypeExtension.Date]
          )
          |> Enum.map(& &1["d_val"])

        assert results == dates
      end

      test "stream with named params and type extensions", %{conn: conn} do
        t = ~T[14:30:00]
        encoded_t = Time.to_iso8601(t)
        extensions = [Xqlite.TypeExtension.Time]

        {:ok, 1} =
          NIF.execute(
            conn,
            "INSERT INTO type_ext_test (id, t_val) VALUES (?1, ?2)",
            [1, encoded_t]
          )

        results =
          Xqlite.stream(
            conn,
            "SELECT t_val FROM type_ext_test WHERE id = :id",
            [id: 1],
            type_extensions: extensions
          )
          |> Enum.to_list()

        assert [%{"t_val" => ^t}] = results
      end

      test "decode_rows with multiple extensions on multi-column result", %{conn: conn} do
        dt = ~U[2024-01-15 10:30:00Z]
        d = ~D[2024-06-15]
        t = ~T[08:00:00]

        {:ok, 1} =
          NIF.execute(
            conn,
            "INSERT INTO type_ext_test (id, dt_val, d_val, t_val, int_val) VALUES (?1, ?2, ?3, ?4, ?5)",
            [1, DateTime.to_iso8601(dt), Date.to_iso8601(d), Time.to_iso8601(t), 99]
          )

        {:ok, %{rows: rows}} =
          NIF.query(
            conn,
            "SELECT dt_val, d_val, t_val, int_val FROM type_ext_test WHERE id = 1",
            []
          )

        extensions = [
          Xqlite.TypeExtension.DateTime,
          Xqlite.TypeExtension.Date,
          Xqlite.TypeExtension.Time
        ]

        decoded = TypeExtension.decode_rows(rows, extensions)
        assert [[^dt, ^d, ^t, 99]] = decoded
      end
    end
  end

  # ---------------------------------------------------------------------------
  # The :type_extensions option itself
  # ---------------------------------------------------------------------------

  describe "the :type_extensions option" do
    setup do
      assert {:ok, conn} = TestUtil.open_in_memory()
      on_exit(fn -> assert :ok = NIF.close(conn) end)
      {:ok, conn: conn}
    end

    test "a term that is no list at all is refused", %{conn: conn} do
      assert {:error, {:invalid_type_extensions, %{reason: :not_a_list, value_type: :atom}}} =
               Xqlite.stream(conn, "SELECT ?1", [1], type_extensions: :nope)
    end

    test "a list whose tail is not one is refused", %{conn: conn} do
      extensions = [Xqlite.TypeExtension.JSON | :x]

      assert {:error, {:invalid_type_extensions, %{reason: :improper_tail, value_type: :atom}}} =
               Xqlite.stream(conn, "SELECT ?1", [1], type_extensions: extensions)
    end

    test "an element that is no module name is refused by its position", %{conn: conn} do
      extensions = [Xqlite.TypeExtension.JSON, "x"]

      expected =
        {:error,
         {:invalid_type_extensions, %{reason: :bad_element, position: 2, value_type: :binary}}}

      assert expected == Xqlite.stream(conn, "SELECT ?1", [1], type_extensions: extensions)

      assert expected == Xqlite.stream(conn, "SELECT 1", [], type_extensions: extensions)
    end

    test "nil and an absent option both mean no extensions", %{conn: conn} do
      assert [%{"?1" => 1}] =
               conn
               |> Xqlite.stream("SELECT ?1", [1], type_extensions: nil)
               |> Enum.to_list()

      assert {:ok, %{rows: [[1]]}} = Xqlite.query(conn, "SELECT ?1", [1], type_extensions: nil)
      assert {:ok, %{rows: [[1]]}} = Xqlite.query(conn, "SELECT ?1", [1])
    end

    test "every door that takes the option judges it the same way", %{conn: conn} do
      assert :ok = Xqlite.execute_batch(conn, "CREATE TABLE ext_rows (v)")
      assert {:ok, token} = Xqlite.create_cancel_token()
      assert {:ok, stmt} = Xqlite.prepare(conn, "SELECT ?1")
      bad = [Xqlite.TypeExtension.JSON | :x]

      refusal =
        {:error, {:invalid_type_extensions, %{reason: :improper_tail, value_type: :atom}}}

      assert refusal == Xqlite.query(conn, "SELECT ?1", [1], type_extensions: bad)

      assert refusal ==
               Xqlite.execute(conn, "INSERT INTO ext_rows (v) VALUES (?1)", [1],
                 type_extensions: bad
               )

      assert refusal == Xqlite.explain_analyze(conn, "SELECT ?1", [1], type_extensions: bad)
      assert refusal == Xqlite.bind(stmt, [1], type_extensions: bad)

      assert refusal ==
               Xqlite.query_cancellable(conn, "SELECT ?1", [1], token, type_extensions: bad)

      assert refusal ==
               Xqlite.execute_cancellable(
                 conn,
                 "INSERT INTO ext_rows (v) VALUES (?1)",
                 [1],
                 token,
                 type_extensions: bad
               )

      assert refusal ==
               Xqlite.query_with_changes_cancellable(conn, "SELECT ?1", [1], token,
                 type_extensions: bad
               )

      assert :ok = Xqlite.finalize(stmt)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # A `DateTime` carrying an arbitrary offset. Built by hand because Elixir
  # ships no time-zone database, so `DateTime.new/3` can only make UTC ones.
  defp offset_datetime(year, month, day, hour, minute, second, microsecond, offset_seconds) do
    %DateTime{
      year: year,
      month: month,
      day: day,
      hour: hour,
      minute: minute,
      second: second,
      microsecond: {microsecond, 6},
      time_zone: "Etc/Unknown",
      zone_abbr: "TST",
      utc_offset: offset_seconds,
      std_offset: 0
    }
  end
end

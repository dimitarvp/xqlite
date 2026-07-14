defmodule Xqlite.TypeExtension.UUIDTest do
  use ExUnit.Case, async: true

  import Xqlite.ConnCase

  alias Xqlite.TypeExtension
  alias Xqlite.TypeExtension.UUID, as: UUIDExt
  alias XqliteNIF, as: NIF

  @canonical "550e8400-e29b-41d4-a716-446655440000"
  @canonical_hex "550e8400e29b41d4a716446655440000"

  # ---------------------------------------------------------------------------
  # Unit tests: encode
  # ---------------------------------------------------------------------------

  describe "encode/1" do
    test "encodes a canonical lowercase UUID to its 16 raw bytes" do
      assert {:ok, bytes} = UUIDExt.encode(@canonical)
      assert byte_size(bytes) == 16
      assert Base.encode16(bytes, case: :lower) == @canonical_hex
    end

    test "encoding is case-insensitive and normalizes to the same bytes" do
      upper = String.upcase(@canonical)
      mixed = "550E8400-e29b-41D4-a716-446655440000"

      assert {:ok, bytes} = UUIDExt.encode(@canonical)
      assert UUIDExt.encode(upper) == {:ok, bytes}
      assert UUIDExt.encode(mixed) == {:ok, bytes}
    end

    test "skips the un-hyphenated 32-char hex form" do
      assert :skip = UUIDExt.encode(@canonical_hex)
    end

    test "skips 36-char strings with hyphens in the wrong places" do
      assert :skip = UUIDExt.encode("550e840-0e29b-41d4-a716-4466554400000")
    end

    test "skips 36-char strings that are not hex" do
      assert :skip = UUIDExt.encode("550e8400-e29b-41d4-a716-44665544zzzz")
    end

    test "skips 36-char strings with non-hyphen separators" do
      assert :skip = UUIDExt.encode("550e8400_e29b_41d4_a716_446655440000")
    end

    # Explicitly NOT encoded: a raw 16-byte binary is ambiguous with an
    # ordinary blob the caller wanted stored verbatim.
    test "skips a raw 16-byte binary" do
      assert :skip = UUIDExt.encode(<<0::128>>)
    end

    test "skips non-binary and wrong-length values" do
      assert :skip = UUIDExt.encode(42)
      assert :skip = UUIDExt.encode(nil)
      assert :skip = UUIDExt.encode("")
      assert :skip = UUIDExt.encode("too-short")
      assert :skip = UUIDExt.encode(~D[2024-01-15])
    end
  end

  # ---------------------------------------------------------------------------
  # Unit tests: decode
  # ---------------------------------------------------------------------------

  describe "decode/1" do
    test "decodes 16 raw bytes to a canonical lowercase hyphenated string" do
      {:ok, bytes} = Base.decode16(@canonical_hex, case: :lower)
      assert {:ok, @canonical} = UUIDExt.decode(bytes)
    end

    test "always emits lowercase" do
      {:ok, bytes} = Base.decode16("AABBCCDDEEFF00112233445566778899", case: :upper)
      assert {:ok, "aabbccdd-eeff-0011-2233-445566778899"} = UUIDExt.decode(bytes)
    end

    test "decodes the nil UUID" do
      assert {:ok, "00000000-0000-0000-0000-000000000000"} = UUIDExt.decode(<<0::128>>)
    end

    # PINNED AMBIGUITY: decode cannot distinguish a 16-byte BLOB from a
    # 16-character TEXT value — rows arrive as plain Elixir binaries with no
    # storage-class tag. The 16 ASCII bytes of "abcdefghijklmnop" therefore
    # convert to a UUID string just like real UUID bytes would. This is the
    # documented decode heuristic, tested here so it can never silently change.
    test "converts any 16-byte binary, including 16-char TEXT" do
      assert {:ok, "61626364-6566-6768-696a-6b6c6d6e6f70"} = UUIDExt.decode("abcdefghijklmnop")
    end

    test "skips binaries that are not exactly 16 bytes" do
      assert :skip = UUIDExt.decode(<<0::120>>)
      assert :skip = UUIDExt.decode(<<0::136>>)
      assert :skip = UUIDExt.decode("")
    end

    # Decode does not re-parse the 36-char canonical text form (it is 36 bytes,
    # not 16) — encode owns that direction.
    test "skips the 36-char canonical string" do
      assert :skip = UUIDExt.decode(@canonical)
    end

    test "skips non-binary values" do
      assert :skip = UUIDExt.decode(42)
      assert :skip = UUIDExt.decode(nil)
    end
  end

  # ---------------------------------------------------------------------------
  # Integration: round-trip through a real connection (stream + type_extensions)
  # ---------------------------------------------------------------------------

  for_each_opener "UUID round-trip" do
    setup %{conn: conn} do
      :ok =
        NIF.execute_batch(conn, """
        CREATE TABLE uuid_test (id INTEGER PRIMARY KEY, u BLOB);
        """)

      :ok
    end

    test "canonical text encodes to a compact BLOB and decodes back", %{conn: conn} do
      [1, encoded] = TypeExtension.encode_params([1, @canonical], [UUIDExt])
      assert byte_size(encoded) == 16

      {:ok, 1} =
        NIF.execute(conn, "INSERT INTO uuid_test (id, u) VALUES (?1, ?2)", [1, encoded])

      # Stored compactly with BLOB affinity (these bytes are not valid UTF-8).
      {:ok, %{rows: [["blob"]]}} =
        NIF.query(conn, "SELECT typeof(u) FROM uuid_test WHERE id = 1", [])

      [row] =
        Xqlite.stream(conn, "SELECT u FROM uuid_test WHERE id = 1", [],
          type_extensions: [UUIDExt]
        )
        |> Enum.to_list()

      assert row["u"] == @canonical
    end

    test "uppercase input round-trips to lowercase output", %{conn: conn} do
      upper = String.upcase(@canonical)
      params = TypeExtension.encode_params([2, upper], [UUIDExt])

      {:ok, 1} = NIF.execute(conn, "INSERT INTO uuid_test (id, u) VALUES (?1, ?2)", params)

      [row] =
        Xqlite.stream(conn, "SELECT u FROM uuid_test WHERE id = 2", [],
          type_extensions: [UUIDExt]
        )
        |> Enum.to_list()

      assert row["u"] == @canonical
    end
  end
end

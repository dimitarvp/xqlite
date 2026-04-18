defmodule Xqlite.OpenOptsTest do
  use ExUnit.Case, async: true

  alias XqliteNIF, as: NIF

  # ---------------------------------------------------------------------------
  # Option validation
  # ---------------------------------------------------------------------------

  describe "option validation" do
    test "default options work" do
      assert {:ok, conn} = Xqlite.open_in_memory()
      NIF.close(conn)
    end

    test "rejects unknown option" do
      assert {:error, {:invalid_open_option, details}} =
               Xqlite.open_in_memory(typo_option: true)

      assert details.key == :typo_option
      assert details.reason == :unknown_key
      assert is_list(details.allowed)
      assert :journal_mode in details.allowed
    end

    test "rejects invalid journal_mode" do
      assert {:error,
              {:invalid_open_option,
               %{key: :journal_mode, reason: :invalid_value, value: :bogus}}} =
               Xqlite.open_in_memory(journal_mode: :bogus)
    end

    test "rejects invalid busy_timeout type" do
      assert {:error,
              {:invalid_open_option,
               %{key: :busy_timeout, reason: :invalid_value, value: "five seconds"}}} =
               Xqlite.open_in_memory(busy_timeout: "five seconds")
    end

    test "rejects negative busy_timeout" do
      assert {:error,
              {:invalid_open_option, %{key: :busy_timeout, reason: :invalid_value, value: -1}}} =
               Xqlite.open_in_memory(busy_timeout: -1)
    end

    test "rejects invalid foreign_keys type" do
      assert {:error,
              {:invalid_open_option,
               %{key: :foreign_keys, reason: :invalid_value, value: "yes"}}} =
               Xqlite.open_in_memory(foreign_keys: "yes")
    end

    test "rejects invalid synchronous value" do
      assert {:error,
              {:invalid_open_option,
               %{key: :synchronous, reason: :invalid_value, value: :turbo}}} =
               Xqlite.open_in_memory(synchronous: :turbo)
    end

    test "rejects invalid temp_store value" do
      assert {:error,
              {:invalid_open_option, %{key: :temp_store, reason: :invalid_value, value: :ssd}}} =
               Xqlite.open_in_memory(temp_store: :ssd)
    end

    test "rejects invalid auto_vacuum value" do
      assert {:error,
              {:invalid_open_option,
               %{key: :auto_vacuum, reason: :invalid_value, value: :aggressive}}} =
               Xqlite.open_in_memory(auto_vacuum: :aggressive)
    end

    test "rejects negative mmap_size" do
      assert {:error,
              {:invalid_open_option, %{key: :mmap_size, reason: :invalid_value, value: -1}}} =
               Xqlite.open_in_memory(mmap_size: -1)
    end

    test "rejects negative wal_autocheckpoint" do
      assert {:error,
              {:invalid_open_option,
               %{key: :wal_autocheckpoint, reason: :invalid_value, value: -1}}} =
               Xqlite.open_in_memory(wal_autocheckpoint: -1)
    end
  end

  # ---------------------------------------------------------------------------
  # PRAGMA application
  # ---------------------------------------------------------------------------

  describe "PRAGMA application" do
    test "journal_mode defaults to WAL" do
      {:ok, conn} = Xqlite.open_in_memory()
      {:ok, mode} = NIF.get_pragma(conn, "journal_mode")
      assert mode == "memory"
      NIF.close(conn)
    end

    test "journal_mode :wal on file DB" do
      path = temp_db_path()
      {:ok, conn} = Xqlite.open(path)
      {:ok, mode} = NIF.get_pragma(conn, "journal_mode")
      assert mode == "wal"
      NIF.close(conn)
    end

    test "journal_mode :delete" do
      path = temp_db_path()
      {:ok, conn} = Xqlite.open(path, journal_mode: :delete)
      {:ok, mode} = NIF.get_pragma(conn, "journal_mode")
      assert mode == "delete"
      NIF.close(conn)
    end

    test "busy_timeout is applied" do
      {:ok, conn} = Xqlite.open_in_memory(busy_timeout: 10_000)
      {:ok, timeout} = NIF.get_pragma(conn, "busy_timeout")
      assert timeout == 10_000
      NIF.close(conn)
    end

    test "busy_timeout :infinity sets max int" do
      {:ok, conn} = Xqlite.open_in_memory(busy_timeout: :infinity)
      {:ok, timeout} = NIF.get_pragma(conn, "busy_timeout")
      assert timeout == 2_147_483_647
      NIF.close(conn)
    end

    test "foreign_keys defaults to true" do
      {:ok, conn} = Xqlite.open_in_memory()
      {:ok, fk} = NIF.get_pragma(conn, "foreign_keys")
      assert fk == 1
      NIF.close(conn)
    end

    test "foreign_keys: false disables enforcement" do
      {:ok, conn} = Xqlite.open_in_memory(foreign_keys: false)
      {:ok, fk} = NIF.get_pragma(conn, "foreign_keys")
      assert fk == 0
      NIF.close(conn)
    end

    test "synchronous defaults to :normal" do
      {:ok, conn} = Xqlite.open_in_memory()
      {:ok, sync} = NIF.get_pragma(conn, "synchronous")
      # 1 = normal
      assert sync == 1
      NIF.close(conn)
    end

    test "synchronous :full" do
      {:ok, conn} = Xqlite.open_in_memory(synchronous: :full)
      {:ok, sync} = NIF.get_pragma(conn, "synchronous")
      # 2 = full
      assert sync == 2
      NIF.close(conn)
    end

    test "cache_size defaults to -64000 (64MB)" do
      {:ok, conn} = Xqlite.open_in_memory()
      {:ok, cache} = NIF.get_pragma(conn, "cache_size")
      assert cache == -64_000
      NIF.close(conn)
    end

    test "cache_size custom value" do
      {:ok, conn} = Xqlite.open_in_memory(cache_size: -32_000)
      {:ok, cache} = NIF.get_pragma(conn, "cache_size")
      assert cache == -32_000
      NIF.close(conn)
    end

    test "temp_store defaults to :memory" do
      {:ok, conn} = Xqlite.open_in_memory()
      {:ok, store} = NIF.get_pragma(conn, "temp_store")
      # 2 = memory
      assert store == 2
      NIF.close(conn)
    end

    test "wal_autocheckpoint custom value" do
      {:ok, conn} = Xqlite.open_in_memory(wal_autocheckpoint: 500)
      {:ok, val} = NIF.get_pragma(conn, "wal_autocheckpoint")
      assert val == 500
      NIF.close(conn)
    end

    test "wal_autocheckpoint 0 disables" do
      {:ok, conn} = Xqlite.open_in_memory(wal_autocheckpoint: 0)
      {:ok, val} = NIF.get_pragma(conn, "wal_autocheckpoint")
      assert val == 0
      NIF.close(conn)
    end

    test "mmap_size custom value on file DB" do
      path = temp_db_path()
      {:ok, conn} = Xqlite.open(path, mmap_size: 268_435_456)
      {:ok, val} = NIF.get_pragma(conn, "mmap_size")
      assert val == 268_435_456
      NIF.close(conn)
    end

    test "auto_vacuum :full" do
      {:ok, conn} = Xqlite.open_in_memory(auto_vacuum: :full)
      {:ok, val} = NIF.get_pragma(conn, "auto_vacuum")
      # 1 = full
      assert val == 1
      NIF.close(conn)
    end

    test "auto_vacuum :incremental" do
      {:ok, conn} = Xqlite.open_in_memory(auto_vacuum: :incremental)
      {:ok, val} = NIF.get_pragma(conn, "auto_vacuum")
      # 2 = incremental
      assert val == 2
      NIF.close(conn)
    end

    test "multiple options combined" do
      {:ok, conn} =
        Xqlite.open_in_memory(
          busy_timeout: 15_000,
          foreign_keys: false,
          synchronous: :off,
          cache_size: -128_000
        )

      {:ok, timeout} = NIF.get_pragma(conn, "busy_timeout")
      assert timeout == 15_000

      {:ok, fk} = NIF.get_pragma(conn, "foreign_keys")
      assert fk == 0

      {:ok, sync} = NIF.get_pragma(conn, "synchronous")
      assert sync == 0

      {:ok, cache} = NIF.get_pragma(conn, "cache_size")
      assert cache == -128_000

      NIF.close(conn)
    end
  end

  # ---------------------------------------------------------------------------
  # File-backed open
  # ---------------------------------------------------------------------------

  describe "Xqlite.open/2 with file path" do
    test "creates database file" do
      path = temp_db_path()
      {:ok, conn} = Xqlite.open(path)
      assert File.exists?(path)
      NIF.close(conn)
    end

    test "applies PRAGMAs on file-backed DB" do
      path = temp_db_path()
      {:ok, conn} = Xqlite.open(path, busy_timeout: 8_000)
      {:ok, timeout} = NIF.get_pragma(conn, "busy_timeout")
      assert timeout == 8_000
      NIF.close(conn)
    end
  end

  defp temp_db_path do
    path =
      Path.join(
        System.tmp_dir!(),
        "xqlite_open_opts_test_#{:erlang.unique_integer([:positive])}.db"
      )

    on_exit(fn -> File.rm(path) end)
    path
  end
end

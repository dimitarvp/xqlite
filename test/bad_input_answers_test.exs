defmodule Xqlite.BadInputAnswersTest do
  @moduledoc """
  What the three modules promise for bad input, one example per claim.

  `Xqlite` says an argument of the wrong type raises at the call — from a
  guard or from the native function's argument decoding — and that a value of
  the right type this library or SQLite refuses is an answer instead.
  `Xqlite.Pragma` names the three answers its doors give for a key that is no
  name, a value no pragma takes and an argument a pragma cannot take, and the
  one raise it keeps, for a connection that is not one. `XqliteNIF` says its
  raw stubs raise on a term the native side cannot decode.
  """

  use ExUnit.Case, async: true

  import Xqlite.ConnCase

  alias Xqlite.Pragma, as: P

  for_each_opener "bad input" do
    # These arguments are wrong on purpose, which the compiler's type checker
    # would report as a mistake; `apply/3` keeps it out of the call.
    test "a guard on an Xqlite function raises", %{conn: conn} do
      assert_raise FunctionClauseError, fn -> apply(Xqlite, :prepare, [conn, 42]) end

      assert {:ok, stmt} = Xqlite.prepare(conn, "SELECT 1")
      assert_raise FunctionClauseError, fn -> apply(Xqlite, :multi_step, [stmt, :ten]) end

      # The guard catches the wrong type and nothing else: a number outside the
      # batch size's domain is an answer.
      assert {:error, {:invalid_batch_size, %{minimum: 1, provided: 0}}} =
               Xqlite.multi_step(stmt, 0)
    end

    test "the native argument decoding raises", %{conn: conn} do
      assert_raise ArgumentError, fn -> apply(Xqlite, :query, [conn, 42, []]) end
    end

    test "a value of the right type is an answer", %{conn: conn} do
      assert {:error, {:expected_list, _text}} = Xqlite.query(conn, "SELECT 1", :atom)
    end

    test "a pragma key that is neither an atom nor a string is an answer", %{conn: conn} do
      assert {:error, {:invalid_pragma_name, 42}} = P.get(conn, 42)

      assert {:error, {:invalid_pragma_name, {:not, :a, :name}}} =
               Xqlite.get_pragma(conn, {:not, :a, :name})

      assert {:error, {:invalid_pragma_name, {:not, :a, :name}}} =
               Xqlite.set_pragma(conn, {:not, :a, :name}, 1)
    end

    test "open options that are not a list raise from a guard" do
      path = Xqlite.TestUtil.tmp_db_path("bad_open_opts")

      assert_raise FunctionClauseError, fn -> apply(Xqlite, :open, [path, :atom]) end

      assert_raise FunctionClauseError, fn ->
        apply(Xqlite, :open, [path, %{busy_timeout: 100}])
      end

      assert_raise FunctionClauseError, fn -> apply(Xqlite, :open_in_memory, [:atom]) end

      assert_raise FunctionClauseError, fn ->
        apply(Xqlite, :open_in_memory, [%{busy_timeout: 100}])
      end
    end

    test "an option that is not a key-value pair is an answer" do
      path = Xqlite.TestUtil.tmp_db_path("bad_open_opts")

      assert {:error,
              {:invalid_open_option, %{key: nil, reason: :not_a_pair, value: :busy_timeout}}} =
               Xqlite.open(path, [:busy_timeout])

      assert {:error,
              {:invalid_open_option, %{key: nil, reason: :not_a_pair, value: :busy_timeout}}} =
               Xqlite.open_in_memory([:busy_timeout])
    end

    test "an options list that does not end in [] is an answer" do
      path = Xqlite.TestUtil.tmp_db_path("bad_open_opts")
      improper = [{:foreign_keys, true} | :busy_timeout]

      assert {:error,
              {:invalid_open_option, %{key: nil, reason: :not_a_pair, value: :busy_timeout}}} =
               apply(Xqlite, :open, [path, improper])

      assert {:error,
              {:invalid_open_option, %{key: nil, reason: :not_a_pair, value: :busy_timeout}}} =
               apply(Xqlite, :open_in_memory, [improper])
    end

    test "a value no pragma takes is an answer", %{conn: conn} do
      assert {:error, {:invalid_pragma_value, %{pragma: :user_version, value: "nope"}}} =
               P.put(conn, :user_version, "nope")
    end

    test "an argument a pragma cannot take is an answer", %{conn: conn} do
      assert {:error, {:invalid_pragma_argument, %{pragma: :user_version}}} =
               P.get(conn, :user_version, 42)
    end

    test "a pragma door raises only for a connection that is not one" do
      assert_raise ArgumentError, fn -> P.get(:not_a_connection, :user_version) end
    end

    test "a raw NIF stub raises on a term it cannot decode" do
      assert_raise ArgumentError, fn -> XqliteNIF.cancel_operation(make_ref()) end
    end
  end
end

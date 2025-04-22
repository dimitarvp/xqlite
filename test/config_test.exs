defmodule XqliteConfigTest do
  use ExUnit.Case
  doctest Xqlite.Config

  alias Xqlite.Config, as: C

  @fields Keyword.keys(C.default()) -- [:__struct__]
  @valid_batch_size 2000
  @valid_db_name ":memory:"
  @valid_exec_timeout :infinity
  @valid_genserver_timeout 5000
  @valid_opts [
    batch_size: @valid_batch_size,
    db_name: @valid_db_name,
    exec_timeout: @valid_exec_timeout,
    genserver_timeout: @valid_genserver_timeout
  ]
  @another_batch_size 1000
  @another_db_name "/tmp/01DFKHMKX0EDTC2AP9AEWNX0JM.db"
  @another_exec_timeout 2000
  @another_genserver_timeout 3000

  setup do
    {:ok, opts: @valid_opts}
  end

  describe "defaults" do
    test "default batch size is a positive integer" do
      n = C.default_batch_size()
      assert is_integer(n)
      assert n > 0
    end

    test "default database name is a printable UTF-8 string" do
      t = C.default_db_name()
      assert is_binary(t)
      assert String.printable?(t)
    end

    test "default execution timeout is valid Erlang timeout" do
      t = C.default_exec_timeout()
      assert (is_atom(t) and t == :infinity) or (is_integer(t) and t >= 0)
    end

    test "default GenServer timeout is valid Erlang timeout" do
      t = C.default_exec_timeout()
      assert (is_atom(t) and t == :infinity) or (is_integer(t) and t >= 0)
    end
  end

  describe "fetch options" do
    @fields
    |> Enum.each(fn name ->
      test name do
        expected = unquote(Module.get_attribute(__MODULE__, String.to_atom("valid_#{name}")))
        assert C.get(@valid_opts, unquote(name)) == expected
        assert apply(C, unquote(:"get_#{name}"), [@valid_opts]) == expected
      end
    end)
  end

  describe "change options" do
    @fields
    |> Enum.each(fn name ->
      test name, %{opts: opts} do
        field_name = unquote(name)
        expected = unquote(Module.get_attribute(__MODULE__, String.to_atom("another_#{name}")))
        opts = C.put(opts, field_name, expected)
        assert C.get(opts, field_name) == expected
        opts = apply(C, unquote(:"put_#{name}"), [opts, expected])
        assert apply(C, unquote(:"get_#{name}"), [opts]) == expected
      end
    end)
  end
end

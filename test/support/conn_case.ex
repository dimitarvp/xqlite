defmodule Xqlite.ConnCase do
  @moduledoc """
  The standard NIF-test skeleton: every test runs against every
  connection mode (see `Xqlite.TestUtil.connection_openers/0`).

      import Xqlite.ConnCase

      for_each_opener do
        test "...", %{conn: conn} do
          ...
        end
      end

  expands to exactly the conventional hand-written form — a
  compile-time `for` over the openers, one `describe "using \#{prefix}"`
  per mode (tagged with the mode's tag), and a setup that opens the
  connection, registers its close, and provides `%{conn: conn}`.
  Test names and tags are byte-identical to the manual pattern, so
  CI tag filtering is unaffected.

  An optional label prefixes the describe name
  (`for_each_opener "serialize/deserialize" do …` →
  `"serialize/deserialize using \#{prefix}"`).

  Module-specific setup (DDL seeding etc.) goes INSIDE the block as a
  second `setup %{conn: conn} do … end` — describe-level setups run
  in declaration order, so the connection is already open. Files
  whose per-mode setup diverges from the canonical open/close shape
  keep the explicit `for` loop instead.
  """

  defmacro for_each_opener(label \\ "", do: block) do
    base =
      case label do
        "" -> "using "
        prefix_label when is_binary(prefix_label) -> prefix_label <> " using "
      end

    quote do
      for {type_tag, prefix, _opener_mfa} <- Xqlite.TestUtil.connection_openers() do
        describe unquote(base) <> prefix do
          @describetag type_tag

          setup context do
            {mod, fun, args} = Xqlite.TestUtil.find_opener_mfa!(context)
            assert {:ok, conn} = apply(mod, fun, args)

            on_exit(fn -> XqliteNIF.close(conn) end)
            {:ok, conn: conn}
          end

          unquote(block)
        end
      end
    end
  end
end

defmodule Xqlite.OptionListLawTest do
  @moduledoc """
  Every function that takes an option list walks it whole before it reads a
  value: an unknown key, a key given twice, an element that is no pair, a tail
  that is not `[]` and a value the option cannot take each answer
  `{:invalid_option, %{key, value, reason}}`, and nothing has changed.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  import Xqlite.ConnCase

  @moduletag timeout: 300_000

  @one_key ~w(query execute explain_analyze bind query_cancellable execute_cancellable
              query_with_changes_cancellable)a

  @keys Map.merge(Map.from_keys(@one_key, [:type_extensions]), %{
          open_in_memory:
            ~w(auto_vacuum busy_timeout cache_size foreign_keys journal_mode mmap_size
               synchronous temp_store wal_autocheckpoint)a,
          set_busy_policy: [:max_elapsed_ms, :max_retries, :sleep_ms],
          register_progress_hook: [:every_n, :tag],
          stream: [:batch_size, :cancel_tokens, :on_error, :type_extensions],
          bridge: [:hooks, :progress, :tag],
          bridge_log: [:tag]
        })

  @harmless Map.merge(Map.from_keys(@one_key, type_extensions: []), %{
              open_in_memory: [foreign_keys: true, journal_mode: :memory],
              set_busy_policy: [max_retries: 0, sleep_ms: 0],
              register_progress_hook: [every_n: 1, tag: :t],
              stream: [batch_size: 1, on_error: :halt],
              bridge: [tag: :t],
              bridge_log: [tag: :t]
            })

  # What the native decoders store: `u32`, `u64`, and `every_n` from 1.
  @bounds [
    {:set_busy_policy, :max_retries, 0..(2 ** 32 - 1)},
    {:set_busy_policy, :max_elapsed_ms, 0..(2 ** 64 - 1)},
    {:set_busy_policy, :sleep_ms, 0..(2 ** 64 - 1)},
    {:register_progress_hook, :every_n, 1..(2 ** 32 - 1)}
  ]

  @bridge_faults [
    {[hooks: :commit], %{key: :hooks, value: :commit, reason: :invalid_value}},
    {[progress: [tag: "x"]], %{key: :tag, value: "x", reason: :invalid_value}},
    {[progress: [every_n: 5, every_n: 0]], %{key: :every_n, value: 0, reason: :duplicate_key}},
    {[hooks: [:commit], progress: [evry_n: 5]],
     %{key: :evry_n, value: 5, reason: :unknown_key, allowed: [:every_n, :tag]}}
  ]

  @ticking "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 5000) " <>
             "SELECT count(*) FROM c"

  for_each_opener "option lists" do
    test "the anchor: a misspelled key and a key given twice answer on every function",
         %{conn: conn} do
      for {function, allowed} <- @keys do
        assert {:error,
                {:invalid_option, %{key: :typo, value: 1, reason: :unknown_key} = answer}} =
                 call(function, conn, typo: 1)

        assert {function, Enum.sort(answer.allowed)} == {function, allowed}

        [{key, value} | _] = @harmless[function]
        twice = {:error, {:invalid_option, %{key: key, value: value, reason: :duplicate_key}}}

        assert {function, twice} ==
                 {function, call(function, conn, [{key, value}, {key, value}])}
      end

      tops = [max_retries: 2 ** 32 - 1, max_elapsed_ms: 2 ** 64 - 1, sleep_ms: 2 ** 64 - 1]
      assert :ok = Xqlite.set_busy_policy(conn, tops)
      assert :ok = Xqlite.remove_busy_policy(conn)
      assert_nothing_changed(conn)
    end

    property "a fault anywhere in the list answers and changes nothing", %{conn: conn} do
      check all(
              {function, opts, expected} <- frequency([{3, pair_fault()}, {1, value_fault()}]),
              max_runs: 2000
            ) do
        assert {:error, {:invalid_option, answer}} = call(function, conn, opts)

        assert {function, Map.replace_lazy(answer, :allowed, &Enum.sort/1)} ==
                 {function, expected}
      end

      assert_nothing_changed(conn)
    end
  end

  defp pair_fault do
    gen all(
          function <- member_of(Map.keys(@keys)),
          taken <- integer(1..length(@harmless[function])),
          prefix = Enum.take(@harmless[function], taken),
          key <- filter(atom(:alphanumeric), &(&1 not in @keys[function])),
          value <- scale(term(), &min(&1, 6)),
          bad <- filter(scale(term(), &min(&1, 6)), &(not (is_list(&1) or match?({_, _}, &1)))),
          fault <- member_of([:unknown_key, :duplicate_key, :not_a_pair, :broken_tail])
        ) do
      case fault do
        :unknown_key ->
          unknown = %{key: key, value: value, reason: :unknown_key, allowed: @keys[function]}
          {function, prefix ++ [{key, value}], unknown}

        :duplicate_key ->
          [{twice, _first} | _] = prefix
          twice_again = %{key: twice, value: value, reason: :duplicate_key}
          {function, prefix ++ [{twice, value}], twice_again}

        :not_a_pair ->
          {function, prefix ++ [bad | prefix], %{key: nil, value: bad, reason: :not_a_pair}}

        :broken_tail ->
          {function, List.foldr(prefix, bad, &[&1 | &2]),
           %{key: nil, value: bad, reason: :not_a_pair}}
      end
    end
  end

  defp value_fault do
    numbers =
      gen all(
            {function, key, first..last//_} <- member_of(@bounds),
            value <-
              one_of([integer((first - 99)..(first - 1)), integer((last + 1)..(last + 99))])
          ) do
        {function, [{key, value}], %{key: key, value: value, reason: :invalid_value}}
      end

    one_of([numbers, map(member_of(@bridge_faults), fn {opts, ex} -> {:bridge, opts, ex} end)])
  end

  defp call(:open_in_memory, _conn, opts), do: Xqlite.open_in_memory(opts)
  defp call(:set_busy_policy, conn, opts), do: Xqlite.set_busy_policy(conn, opts)

  defp call(:register_progress_hook, conn, opts),
    do: Xqlite.register_progress_hook(conn, self(), opts)

  defp call(:bridge, conn, opts), do: Xqlite.Telemetry.bridge(conn, opts)
  defp call(:bridge_log, _conn, opts), do: Xqlite.Telemetry.bridge_log(opts)

  defp call(:bind, conn, opts) do
    {:ok, stmt} = Xqlite.prepare(conn, "SELECT 1")
    answer = Xqlite.bind(stmt, [], opts)
    :ok = Xqlite.finalize(stmt)
    answer
  end

  defp call(function, conn, opts) when function in ~w(query_cancellable execute_cancellable
                           query_with_changes_cancellable)a,
    do: apply(Xqlite, function, [conn, "SELECT 1", [], [], opts])

  defp call(function, conn, opts), do: apply(Xqlite, function, [conn, "SELECT 1", [], opts])

  defp assert_nothing_changed(conn) do
    assert {:ok, _} = XqliteNIF.set_pragma(conn, "busy_timeout", 1)
    assert {:ok, _} = Xqlite.query(conn, @ticking)
    refute_received {:xqlite_progress, _, _}
    refute_received {:xqlite_progress, _, _, _}
  end
end

# The parent's deadline closes stdin; halting then ends a child stuck in a native call.
spawn(fn ->
  IO.read(:stdio, :eof)
  System.halt(125)
end)

defmodule Xqlite.FuzzChild do
  @modes [nil, true, false, Xqlite.TypeExtension.JSON] ++
           ~w(ok error main temp passive full restart truncate deferred immediate exclusive omit
              replace abort length variable_number raise emit_error halt read insert delete pragma
              table index batch_size on_error cancel_tokens type_extensions db_name every_n tag
              busy_timeout)a
  @atoms @modes ++ (Xqlite.Pragma.all() -- [:hard_heap_limit])
  @ints [0, 1, 2, 64] ++ for(e <- [31, 32, 63, 64, 70], d <- [-1, 0, 1], do: 2 ** e + d)
  @texts ~w(main temp t b x :memory: journal_mode sp1 fuzz.db) ++
           ["SELECT * FROM t", "INSERT INTO t(x) VALUES (?1)"]
  @bad_texts ["", "a\0b", <<255, 254>>, "SELECT 1", "PRAGMA journal_mode", "BEGIN" | @texts] ++
               ~w(' " a'b t"x ] `)
  @table "CREATE TABLE t(id INTEGER PRIMARY KEY, b BLOB, x TEXT); " <>
           "INSERT INTO t VALUES (1, zeroblob(64), 'a')"
  @left_out ~w(Xqlite.Pragma.query_to_pragma_result/1 Xqlite.TypeExtension.encode_value/2
               Xqlite.TypeExtension.decode_value/2)
  @steps [{Xqlite, :step, 1}, {XqliteNIF, :stmt_step, 1}]
  @fetches [{XqliteNIF, :stream_fetch, 2}, {XqliteNIF, :stream_fetch_cancellable, 3}]

  def surface do
    for mod <- [Xqlite, XqliteNIF, Xqlite.Pragma, Xqlite.TypeExtension],
        {:docs_v1, _, _, _, _, _, docs} = Code.fetch_docs(mod),
        hidden =
          for(
            {{:function, name, arity}, _, _, :hidden, meta} <- docs,
            lower <- 0..Map.get(meta, :defaults, 0),
            do: {name, arity - lower}
          ),
        {fun, arity} <- mod.__info__(:functions),
        {fun, arity} not in hidden,
        Exception.format_mfa(mod, fun, arity) not in @left_out,
        do: {mod, fun, arity}
  end

  def handles(dead) do
    conns = for {_, _, opener} <- Xqlite.TestUtil.connection_openers(), do: table(opener)
    [conn | _] = conns
    {:ok, stmt} = XqliteNIF.stmt_prepare(conn, "SELECT * FROM t WHERE id > ?1")
    {:ok, fin} = XqliteNIF.stmt_prepare(conn, "SELECT 1")
    :ok = XqliteNIF.stmt_finalize(fin)
    {:ok, stream} = XqliteNIF.stream_open(conn, "SELECT * FROM t", [])
    {:ok, session} = XqliteNIF.session_new(conn)
    {:ok, token} = XqliteNIF.create_cancel_token()
    {:ok, closed} = XqliteNIF.open_in_memory(":memory:")
    :ok = XqliteNIF.close(closed)
    blob_conn = table({XqliteNIF, :open_in_memory, [":memory:"]})
    {:ok, blob} = XqliteNIF.blob_open(blob_conn, "main", "t", "b", 1, false)
    refs = [blob, stream, session, token, stmt]
    %{conns: [closed | conns], stmts: [stmt, stmt, fin], refs: refs, token: token, dead: dead}
  end

  defp table({mod, fun, args}) do
    {:ok, conn} = apply(mod, fun, args)
    :ok = XqliteNIF.execute_batch(conn, @table)
    conn
  end

  def fuzz({mod, fun, arity} = mfa, h, runs, log, trace) do
    name = Exception.format_mfa(mod, fun, arity)
    pools = for type <- arg_types(mod, fun, arity), do: typed(type, h)

    fails =
      for i <- 1..if(arity == 0, do: 1, else: runs),
          args = Enum.map(pools, &draw(&1, h)),
          shown = if(trace, do: [?\s | inspect(args)], else: []),
          :ok = :file.write(log, [name, ?\s, Integer.to_string(i), shown, ?\n]),
          answer = call(mod, fun, args),
          not conforming?(mfa, answer),
          do: {i, args, answer}

    with [{i, args, answer} | _] <- fails do
      shown = Enum.map_join([args, answer], ": ", &inspect(&1, limit: 9))
      IO.puts("FAIL #{name} x#{length(fails)} at #{i} with #{shown}")
    end

    length(fails)
  end

  defp draw(pool, h),
    do: if(pool != [] and :rand.uniform(2) == 1, do: Enum.random(pool), else: hostile(h))

  defp arg_types(mod, fun, arity) do
    {:ok, specs} = Code.Typespec.fetch_specs(mod)

    heads =
      for {{^fun, full}, [spec | _]} <- Enum.sort(specs),
          full >= arity,
          {:"::", _, [{^fun, _, args}, _]} <- [Code.Typespec.spec_to_quoted(fun, spec)],
          do: Enum.take(args, arity)

    heads
    |> List.first(List.duplicate(quote(do: term()), arity))
    |> Enum.map(fn
      {:"::", _, [_name, type]} -> Macro.to_string(type)
      type -> Macro.to_string(type)
    end)
  end

  defp typed(type, h) do
    cond do
      type in ["Xqlite.conn()", "conn()"] -> h.conns
      type in ["Xqlite.stmt()", "stmt()"] -> h.stmts
      type == "reference()" -> h.refs
      type == "[reference()]" -> [[], [h.token]]
      type =~ ~r/String|binary|name\(\)|pragma_key|pragma_value/ -> @texts
      type =~ ~r/integer|0 \| 1/ -> [0, 1, 2, 64]
      type =~ ~r/list|keyword|opts|\[term|\[\[/ -> [[], [1], [1, "a"], [a: 1]]
      type == "pid()" -> [h.dead]
      type == "boolean()" -> [true, false]
      type == "[module()]" -> [[], [Xqlite.TypeExtension.JSON]]
      type == "[atom()]" -> [[] | Enum.map(@modes, &[&1])]
      type =~ ~r/atom|mode|:omit|:passive/ -> @modes
      true -> []
    end
  end

  defp hostile(h) do
    u = :rand.uniform()

    cond do
      u < 0.0005 -> :binary.copy("x", 1_048_576)
      u < 0.001 -> List.duplicate(1, 100_000)
      u < 0.05 -> Enum.random(@atoms)
      u < 0.1 -> :"a#{:rand.uniform(50)}"
      u < 0.2 -> Enum.random(@bad_texts)
      u < 0.3 -> Enum.random([:rand.uniform(100) | @ints]) * Enum.random([1, -1])
      u < 0.4 -> Enum.random([0.0, -0.0, 1.5, 1.0e308])
      u < 0.5 -> Enum.random([<<1::3>>, <<255, 1::1>>])
      u < 0.57 -> Enum.random([[], [1 | 2], ~c"abc"])
      u < 0.585 -> [hostile(h)]
      u < 0.6 -> [{Enum.random(@modes), hostile(h)}]
      u < 0.7 -> Enum.random([{}, {:ok}, {1, 2, 3}, %{}, %{a: 1}])
      u < 0.8 -> Enum.random([h.dead, make_ref()])
      true -> Enum.random(h.conns ++ h.stmts ++ h.refs)
    end
  end

  defp call(mod, fun, args) do
    {:value, apply(mod, fun, args)}
  rescue
    error -> {:raised, error.__struct__}
  catch
    kind, reason -> {kind, reason}
  end

  defp conforming?(mfa, answer) do
    case {mfa, answer} do
      {_, {:raised, class}} -> class in [ArgumentError, FunctionClauseError]
      {_, {:value, :ok}} -> true
      {_, {:value, {:ok, _}}} -> true
      {_, {:value, {:error, reason}}} when is_atom(reason) -> true
      {_, {:value, {:error, reason}}} when is_tuple(reason) -> tagged?(reason)
      {{_, _, 0}, {:value, value}} -> not match?({:error, _}, value)
      {{Xqlite, :stream, _}, {:value, enum}} -> is_function(enum, 2)
      {step, {:value, {:row, row}}} when step in @steps -> is_list(row)
      {bare, {:value, :done}} -> bare in @steps or bare in @fetches
      {{XqliteNIF, :is_cancel_token, 1}, {:value, bool}} -> is_boolean(bool)
      # Producer: whichever function emits it.
      _ -> false
    end
  end

  defp tagged?(tuple), do: match?([tag | _] when is_atom(tag), Tuple.to_list(tuple))
end

[seed, runs | only] = System.argv()
[seed, runs] = Enum.map([seed, runs], &String.to_integer/1)
{dead, ref} = spawn_monitor(fn -> :ok end)

receive do
  {:DOWN, ^ref, :process, _, _} -> :ok
end

{:ok, log} = :file.open(~c"calls.log", [:write, :raw])
trace = only != []

chosen =
  for {{mod, fun, arity}, _} = entry <- Enum.with_index(Xqlite.FuzzChild.surface()),
      only in [[], [Exception.format_mfa(mod, fun, arity)]],
      do: entry

failures =
  for {mfa, index} <- chosen, reduce: 0 do
    failures ->
      :rand.seed(:exsss, {seed, index, 0})
      failures + Xqlite.FuzzChild.fuzz(mfa, Xqlite.FuzzChild.handles(dead), runs, log, trace)
  end

IO.puts("DONE seed=#{seed} functions=#{length(chosen)} failures=#{failures}")
if failures > 0 or chosen == [], do: System.halt(1)

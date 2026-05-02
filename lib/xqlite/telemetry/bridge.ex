defmodule Xqlite.Telemetry.Bridge do
  @moduledoc """
  Forwards multi-subscriber hook deliveries into `:telemetry` events.

  This is the Tier B layer of the telemetry plan. The fan-out hooks
  (`update`, `wal`, `commit`, `rollback`, `progress`, plus the global
  `log` hook) deliver Erlang messages to subscribed pids. The bridge
  is a small GenServer that:

  1. Subscribes to the requested hooks on a connection (or to the
     global log hook).
  2. Receives each hook message in its mailbox.
  3. Re-emits the message as a `[:xqlite, :hook, :*]` telemetry event.

  Each `bridge/2` (or `bridge_log/1`) call returns a struct holding
  the GenServer pid and the registered subscriber handles. Pass it
  to `unbridge/1` to tear down all subscriptions and stop the
  GenServer.

  > #### Opt-in {: .info}
  >
  > Bridges are NEVER attached automatically. Users must call
  > `bridge/2` or `bridge_log/1` explicitly for the connections /
  > log hook they care about.
  >
  > When telemetry is compile-disabled (`config :xqlite,
  > :telemetry_enabled, false`, the default), `bridge/2` and
  > `bridge_log/1` return `{:error, :telemetry_disabled}` rather
  > than silently registering hooks that produce no events.

  ## Per-connection bridge

      {:ok, bridge} =
        Xqlite.Telemetry.bridge(conn,
          hooks: [:wal, :commit, :rollback, :update, :progress],
          tag: :replica_a
        )

      # ... events fire as `[:xqlite, :hook, :wal]` etc ...

      :ok = Xqlite.Telemetry.unbridge(bridge)

  ## Global log bridge

      {:ok, log_bridge} = Xqlite.Telemetry.bridge_log()
      :ok = Xqlite.Telemetry.unbridge(log_bridge)

  ## What about busy_handler?

  `busy_handler` is single-subscriber by design (its callback returns
  a policy decision; multi-subscriber composition is ill-defined).
  It is NOT included in the bridge. If you want busy events as
  telemetry, register your own busy handler with a forwarder pid:

      forwarder = spawn_link(fn -> ... emit telemetry on receive ... end)
      :ok = Xqlite.set_busy_handler(conn, forwarder, max_retries: 50)

  A future split (see `project_busy_handler_observer_split` memory)
  will make the observation half multi-subscriber and bring it into
  the bridge then.
  """

  use GenServer
  require Xqlite.Telemetry
  alias XqliteNIF, as: NIF

  defstruct [:pid, :scope, :tag, :hook_handles]

  @type scope :: {:conn, reference()} | :log
  @type hook_kind :: :wal | :commit | :rollback | :update | :progress | :log
  @type t :: %__MODULE__{
          pid: pid(),
          scope: scope(),
          tag: term() | nil,
          hook_handles: [{hook_kind(), non_neg_integer()}]
        }

  @per_conn_hooks [:wal, :commit, :rollback, :update, :progress]
  @valid_per_conn_hooks @per_conn_hooks ++ [:all]

  @doc false
  def start_link(scope, tag) do
    GenServer.start_link(__MODULE__, %{scope: scope, tag: tag})
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_info(message, state) do
    handle_hook_message(message, state)
    {:noreply, state}
  end

  # --- Bridge construction (per-conn) ----------------------------------------

  @doc false
  def bridge_per_conn(conn, opts) when is_reference(conn) and is_list(opts) do
    if Xqlite.Telemetry.enabled?() do
      hooks = expand_hooks(Keyword.get(opts, :hooks, :all))
      tag = Keyword.get(opts, :tag, nil)
      progress_opts = Keyword.get(opts, :progress, [])

      with :ok <- validate_hooks(hooks),
           {:ok, pid} <- start_link({:conn, conn}, tag),
           {:ok, handles} <- register_per_conn_hooks(pid, conn, hooks, progress_opts) do
        {:ok,
         %__MODULE__{
           pid: pid,
           scope: {:conn, conn},
           tag: tag,
           hook_handles: handles
         }}
      else
        {:error, _} = err -> err
      end
    else
      {:error, :telemetry_disabled}
    end
  end

  # --- Bridge construction (global log) --------------------------------------

  @doc false
  def bridge_log_global(opts) when is_list(opts) do
    if Xqlite.Telemetry.enabled?() do
      tag = Keyword.get(opts, :tag, nil)

      with {:ok, pid} <- start_link(:log, tag),
           {:ok, handle} <- NIF.register_log_hook(pid) do
        {:ok,
         %__MODULE__{
           pid: pid,
           scope: :log,
           tag: tag,
           hook_handles: [{:log, handle}]
         }}
      else
        {:error, _} = err -> err
      end
    else
      {:error, :telemetry_disabled}
    end
  end

  # --- Teardown --------------------------------------------------------------

  @doc false
  def unbridge(%__MODULE__{pid: pid, scope: scope, hook_handles: handles}) do
    Enum.each(handles, fn {hook, handle} ->
      unregister_hook(scope, hook, handle)
    end)

    if Process.alive?(pid) do
      GenServer.stop(pid, :normal, 1_000)
    end

    :ok
  end

  # --- Internal helpers ------------------------------------------------------

  defp expand_hooks(:all), do: @per_conn_hooks
  defp expand_hooks(list) when is_list(list), do: list

  defp validate_hooks(hooks) do
    case Enum.find(hooks, fn h -> h not in @valid_per_conn_hooks end) do
      nil ->
        :ok

      bad ->
        {:error, {:invalid_hook, bad, valid: @valid_per_conn_hooks}}
    end
  end

  defp register_per_conn_hooks(pid, conn, hooks, progress_opts) do
    Enum.reduce_while(hooks, {:ok, []}, fn hook, {:ok, acc} ->
      case register_per_conn_hook(pid, conn, hook, progress_opts) do
        {:ok, handle} ->
          {:cont, {:ok, [{hook, handle} | acc]}}

        {:error, _} = err ->
          # Roll back any handles we already registered before this failure.
          Enum.each(acc, fn {h, hh} -> unregister_hook({:conn, conn}, h, hh) end)
          if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
          {:halt, err}
      end
    end)
    |> case do
      {:ok, handles} -> {:ok, Enum.reverse(handles)}
      err -> err
    end
  end

  defp register_per_conn_hook(pid, conn, :wal, _opts), do: NIF.register_wal_hook(conn, pid)

  defp register_per_conn_hook(pid, conn, :commit, _opts),
    do: NIF.register_commit_hook(conn, pid)

  defp register_per_conn_hook(pid, conn, :rollback, _opts),
    do: NIF.register_rollback_hook(conn, pid)

  defp register_per_conn_hook(pid, conn, :update, _opts),
    do: NIF.register_update_hook(conn, pid)

  defp register_per_conn_hook(pid, conn, :progress, opts) do
    every_n = Keyword.get(opts, :every_n, 1000)
    tag = Keyword.get(opts, :tag, nil)

    tag_str =
      case tag do
        nil -> nil
        a when is_atom(a) -> Atom.to_string(a)
      end

    NIF.register_progress_hook(conn, pid, every_n, tag_str)
  end

  defp unregister_hook({:conn, conn}, :wal, handle), do: NIF.unregister_wal_hook(conn, handle)

  defp unregister_hook({:conn, conn}, :commit, handle),
    do: NIF.unregister_commit_hook(conn, handle)

  defp unregister_hook({:conn, conn}, :rollback, handle),
    do: NIF.unregister_rollback_hook(conn, handle)

  defp unregister_hook({:conn, conn}, :update, handle),
    do: NIF.unregister_update_hook(conn, handle)

  defp unregister_hook({:conn, conn}, :progress, handle),
    do: NIF.unregister_progress_hook(conn, handle)

  defp unregister_hook(:log, :log, handle), do: NIF.unregister_log_hook(handle)

  # --- Hook message → telemetry ---------------------------------------------

  defp handle_hook_message({:xqlite_wal, db_name, pages}, state) do
    Xqlite.Telemetry.emit(
      [:xqlite, :hook, :wal],
      %{monotonic_time: Xqlite.Telemetry.monotonic_time(), pages: pages},
      Map.merge(scope_metadata(state), %{db_name: db_name})
    )
  end

  defp handle_hook_message({:xqlite_commit}, state) do
    Xqlite.Telemetry.emit(
      [:xqlite, :hook, :commit],
      %{monotonic_time: Xqlite.Telemetry.monotonic_time()},
      scope_metadata(state)
    )
  end

  defp handle_hook_message({:xqlite_rollback}, state) do
    Xqlite.Telemetry.emit(
      [:xqlite, :hook, :rollback],
      %{monotonic_time: Xqlite.Telemetry.monotonic_time()},
      scope_metadata(state)
    )
  end

  defp handle_hook_message({:xqlite_update, action, db_name, table, rowid}, state) do
    Xqlite.Telemetry.emit(
      [:xqlite, :hook, :update],
      %{monotonic_time: Xqlite.Telemetry.monotonic_time()},
      Map.merge(scope_metadata(state), %{
        action: action,
        db_name: db_name,
        table: table,
        rowid: rowid
      })
    )
  end

  defp handle_hook_message({:xqlite_progress, count, elapsed_ms}, state) do
    Xqlite.Telemetry.emit(
      [:xqlite, :hook, :progress],
      %{
        monotonic_time: Xqlite.Telemetry.monotonic_time(),
        count: count,
        elapsed: elapsed_ms * 1_000_000
      },
      Map.merge(scope_metadata(state), %{hook_tag: nil})
    )
  end

  defp handle_hook_message({:xqlite_progress, hook_tag, count, elapsed_ms}, state) do
    Xqlite.Telemetry.emit(
      [:xqlite, :hook, :progress],
      %{
        monotonic_time: Xqlite.Telemetry.monotonic_time(),
        count: count,
        elapsed: elapsed_ms * 1_000_000
      },
      Map.merge(scope_metadata(state), %{hook_tag: hook_tag})
    )
  end

  defp handle_hook_message({:xqlite_log, code, message}, state) do
    base_code = Bitwise.band(code, 0xFF)

    Xqlite.Telemetry.emit(
      [:xqlite, :hook, :log],
      %{monotonic_time: Xqlite.Telemetry.monotonic_time()},
      Map.merge(scope_metadata(state), %{
        code: code,
        base_code: base_code,
        message: message
      })
    )
  end

  defp handle_hook_message(_other, _state), do: :ok

  defp scope_metadata(%{scope: {:conn, conn}, tag: tag}), do: %{conn: conn, tag: tag}
  defp scope_metadata(%{scope: :log, tag: tag}), do: %{tag: tag}
end

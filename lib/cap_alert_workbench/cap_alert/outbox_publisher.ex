defmodule CapAlertWorkbench.CapAlert.OutboxPublisher do
  @moduledoc """
  Polls the notification outbox and broadcasts pending entries.

  Draining is performed inside a single transaction that claims rows with
  `SELECT ... FOR UPDATE SKIP LOCKED`, so multiple nodes never process the same
  row. The PubSub broadcast is a side effect; if the subsequent mark fails the
  transaction rolls back and the row is retried, giving at-least-once delivery.
  The original publish transaction is unaffected because the outbox row was
  committed atomically with the version state change.
  """

  use GenServer
  require Logger

  alias CapAlertWorkbench.CapAlert
  alias CapAlertWorkbench.Repo

  @interval_ms 2_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    schedule_tick()
    {:ok, %{}}
  end

  @doc "Trigger an immediate drain (useful in tests)."
  def drain(server \\ __MODULE__) do
    GenServer.call(server, :drain, 10_000)
  end

  @impl true
  def handle_info(:tick, state) do
    schedule_tick()
    {:noreply, drain_once(state)}
  end

  @impl true
  def handle_call(:drain, _from, state) do
    {:reply, :ok, drain_once(state)}
  end

  defp drain_once(state) do
    case drain_batch() do
      0 -> state
      n -> drain_once(Map.put(state, :last_count, n))
    end
  rescue
    error ->
      Logger.error("outbox drain failed: #{inspect(error)}")
      state
  end

  defp drain_batch do
    Repo.transaction(fn ->
      outboxes = CapAlert.claim_pending_outbox(50)

      Enum.reduce(outboxes, 0, fn outbox, acc ->
        CapAlert.broadcast_outbox(outbox)

        case CapAlert.mark_outbox_published(outbox) do
          {:ok, _} -> acc + 1
          {:error, reason} -> Repo.rollback({:mark_failed, reason})
        end
      end)
    end)
    |> case do
      {:ok, count} ->
        count

      {:error, reason} ->
        Logger.warning("outbox batch failed: #{inspect(reason)}")
        0
    end
  end

  defp schedule_tick do
    Process.send_after(self(), :tick, @interval_ms)
  end
end

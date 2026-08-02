defmodule CapAlertWorkbench.Cap.OutboxDispatcher do
  @moduledoc """
  Polls the transactional outbox and dispatches pending notifications. In this
  reference workbench "delivery" means writing to the application log and
  broadcasting on PubSub; real integrations would swap the `deliver/1` callback.

  Crucially, the outbox rows are created inside the same Ecto.Multi as the
  domain changes, so notifications cannot appear without a committed state
  change.
  """

  use GenServer

  import Ecto.Query

  alias CapAlertWorkbench.Cap.OutboxMessage
  alias CapAlertWorkbench.Repo

  @interval :timer.seconds(2)
  @batch_size 50

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    schedule_poll(0)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:poll, state) do
    dispatch_batch()
    schedule_poll(@interval)
    {:noreply, state}
  end

  defp dispatch_batch do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    messages =
      from(m in OutboxMessage,
        where: m.status == :pending and m.available_at <= ^now,
        order_by: [asc: m.available_at],
        limit: @batch_size,
        lock: "FOR UPDATE SKIP LOCKED"
      )
      |> Repo.all()

    Enum.each(messages, &deliver/1)
  end

  defp deliver(%OutboxMessage{} = message) do
    case do_deliver(message) do
      :ok ->
        message
        |> Ecto.Changeset.change(%{
          status: :delivered,
          delivered_at: DateTime.utc_now() |> DateTime.truncate(:second),
          attempts: message.attempts + 1
        })
        |> Repo.update()

      {:error, reason} ->
        attempts = message.attempts + 1
        backoff = :timer.seconds(min(30, attempts * 5))

        available_at =
          DateTime.utc_now()
          |> DateTime.add(backoff, :millisecond)
          |> DateTime.truncate(:second)

        message
        |> Ecto.Changeset.change(%{
          status: :failed,
          last_error: inspect(reason),
          attempts: attempts,
          available_at: available_at
        })
        |> Repo.update()
    end
  end

  defp do_deliver(message) do
    require Logger

    Logger.info(fn ->
      "[Outbox] delivered topic=#{message.topic} alert=#{message.alert_id}"
    end)

    if message.alert_id do
      Phoenix.PubSub.broadcast(
        CapAlertWorkbench.PubSub,
        "alert:#{message.alert_id}",
        {:notification, message.topic, message.payload}
      )
    end

    :ok
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp schedule_poll(delay) do
    Process.send_after(self(), :poll, delay)
  end
end

defmodule CapAlertWorkbench.Cap.ConcurrencyTest do
  use CapAlertWorkbench.DataCase, async: false

  alias CapAlertWorkbench.Cap

  test "two concurrent draft edits produce exactly one winner and one lock conflict" do
    {:ok, %{alert: alert}} =
      Cap.create_alert(
        Cap.Xml.Codec.seed_message()
        |> Map.from_struct()
        |> Map.put(:actor, "system")
        |> Map.to_list()
      )

    # Open two separate database connections/processes to simulate two browsers.
    # Because the SQL sandbox is shared in the test, we use tasks with their own
    # checkout via allowances.
    parent = self()

    {:ok, _pid1} =
      Task.start_link(fn ->
        Ecto.Adapters.SQL.Sandbox.allow(CapAlertWorkbench.Repo, parent, self())

        result =
          Cap.update_draft(
            alert.id,
            1,
            %{"headline" => "浏览器A写入"},
            "browser-A"
          )

        send(parent, {:result, :a, result})
      end)

    {:ok, _pid2} =
      Task.start_link(fn ->
        Ecto.Adapters.SQL.Sandbox.allow(CapAlertWorkbench.Repo, parent, self())

        result =
          Cap.update_draft(
            alert.id,
            1,
            %{"headline" => "浏览器B写入"},
            "browser-B"
          )

        send(parent, {:result, :b, result})
      end)

    assert_receive {:result, :a, result_a}, 2000
    assert_receive {:result, :b, result_b}, 2000

    results = [result_a, result_b]
    ok_count = Enum.count(results, &match?({:ok, _}, &1))
    conflict_count = Enum.count(results, &match?({:error, {:lock_version_mismatch, _, _}}, &1))

    assert ok_count == 1
    assert conflict_count == 1

    final = Cap.get_alert!(alert.id)
    assert final.draft_lock_version == 2
  end

  test "duplicate concurrent publishes leave exactly one published version" do
    {:ok, %{alert: alert}} =
      Cap.create_alert(
        Cap.Xml.Codec.seed_message()
        |> Map.from_struct()
        |> Map.put(:actor, "system")
        |> Map.to_list()
      )

    {:ok, _} = Cap.submit_for_review(alert.id, "author")
    {:ok, _} = Cap.decide_review(alert.id, %{"decision" => "approved"}, "reviewer")

    parent = self()

    tasks =
      Enum.map(1..2, fn i ->
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(CapAlertWorkbench.Repo, parent, self())

          result = Cap.publish(alert.id, "publisher-#{i}")
          send(parent, {:publish, i, result})
        end)
      end)

    Enum.each(tasks, &Task.await(&1, 5000))

    results =
      for _ <- 1..2 do
        receive do
          {:publish, _i, result} -> result
        after
          2000 -> flunk("publish did not complete")
        end
      end

    published = Enum.count(results, &match?({:ok, _}, &1))
    rejected = Enum.count(results, &match?({:error, _}, &1))

    assert published == 1
    assert rejected == 1

    final = Cap.get_alert!(alert.id)
    assert final.status == :published

    versions = Cap.list_versions(alert.id)
    assert length(versions) == 1
    assert hd(versions).status == :published
  end
end

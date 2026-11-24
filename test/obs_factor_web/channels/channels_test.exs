defmodule ObsFactorWeb.ChannelsTest do
  use ObsFactorWeb.ChannelCase, async: false
  require Logger

  alias ObsFactor.Store

  describe "snapshots" do
    setup do
      on_exit(fn -> Store.clear_snapshot() end)
    end

    test "the join reply is the current snapshot, then every tick is pushed as it was encoded" do
      Store.put_snapshot({:ok, ~s({"at":"first"})})

      {:ok, reply, _socket} =
        subscribe_and_join(authed_socket(), ObsFactorWeb.SnapshotsChannel, "snapshots")

      assert Jason.encode!(reply) == ~s({"snapshot":{"at":"first"}})

      Phoenix.PubSub.broadcast(ObsFactor.PubSub, "snapshots", {:snapshot, ~s({"at":"second"})})
      assert_push "snapshot", %Jason.Fragment{} = frag
      assert Jason.encode!(frag) == ~s({"at":"second"})
    end

    test "before the first tick the reply says so; a failed tick arrives as an error" do
      Store.clear_snapshot()

      {:ok, reply, _} =
        subscribe_and_join(authed_socket(), ObsFactorWeb.SnapshotsChannel, "snapshots")

      assert reply == %{error: "no snapshot yet"}

      Phoenix.PubSub.broadcast(ObsFactor.PubSub, "snapshots", {:snapshot_error, "boom"})
      assert_push "error", %{error: "snapshot build failed: boom"}
    end
  end

  describe "logs" do
    @describetag :capture_log

    test "join after an id returns what is newer, then each new event is pushed" do
      Logger.warning("channels test: before join #{System.unique_integer()}")
      [%{id: before} | _] = Enum.reverse(ObsFactor.LogRing.since(0))
      Logger.warning("channels test: the one after")

      {:ok, reply, _} =
        subscribe_and_join(authed_socket(), ObsFactorWeb.LogsChannel, "logs", %{"after" => before})

      assert [%{text: "channels test: the one after"} = ev] =
               Enum.filter(reply.events, &(&1.text =~ "channels test"))

      assert reply.last_id >= ev.id
      assert reply.kept == 2000

      Logger.warning("channels test: live")
      assert_push "events", %{events: [%{text: "channels test: live", level: :warning}]}
    end

    test "a bad after is refused" do
      assert {:error, %{reason: _}} =
               subscribe_and_join(authed_socket(), ObsFactorWeb.LogsChannel, "logs", %{
                 "after" => "x"
               })
    end
  end

  describe "actions" do
    test "whatever is broadcast on actions is relayed" do
      {:ok, %{}, _} = subscribe_and_join(authed_socket(), ObsFactorWeb.ActionsChannel, "actions")

      Phoenix.PubSub.broadcast(
        ObsFactor.PubSub,
        "actions",
        {:action, %{id: "a1", state: "requested"}}
      )

      assert_push "action", %{id: "a1", state: "requested"}
    end
  end

  describe "objectives without a store" do
    test "the join succeeds and says why there is no list; writes say so too" do
      refute ObsFactor.Objectives.enabled?()

      {:ok, reply, socket} =
        subscribe_and_join(authed_socket(), ObsFactorWeb.ObjectivesChannel, "objectives")

      assert reply == %{error: "no objectives store: OBJECTIVES_PG_URL is not set"}

      ref = push(socket, "pin", %{"node" => "blog"})
      assert_reply ref, :error, %{error: "no objectives store" <> _}
    end
  end

  describe "observer feed" do
    test "observer:observer:-:beam replays and pushes the BEAM report" do
      {:ok, _first, _} =
        subscribe_and_join(authed_socket(), ObsFactorWeb.FeedChannel, "observer:observer:-:beam")

      assert_push "feed", %{at: _, data: %{vm: %{node: _}, processes: [_ | _]}}, 2_000

      # a second viewer: the same feed, and its reply is the last report
      {:ok, second, _} =
        subscribe_and_join(
          authed_socket("other"),
          ObsFactorWeb.FeedChannel,
          "observer:observer:-:beam"
        )

      assert %{data: %{vm: _}} = second
      assert ObsFactor.Feeds.topics() |> Enum.count(&(&1 == "observer:observer:-:beam")) == 1
    end

    test "a topic no view serves is refused with the reason" do
      # observer:* topics are ObsFactor.Feeds.ObserverViews', which names what is wrong
      assert {:error, %{reason: "no node \"nope\" in the topology"}} =
               subscribe_and_join(
                 authed_socket(),
                 ObsFactorWeb.FeedChannel,
                 "observer:nope:-:system"
               )

      assert {:error, "no feed serves \"elsewhere:x\""} = ObsFactor.Feeds.Views.spec("elsewhere:x")

      assert {:error, %{reason: "history topics are" <> _}} =
               subscribe_and_join(authed_socket(), ObsFactorWeb.FeedChannel, "history:blog:1d")
    end

    test "history:<node>:<res> is a feed of the node's series; an unknown node is an error on it" do
      {:ok, reply, _} =
        subscribe_and_join(authed_socket(), ObsFactorWeb.FeedChannel, "history:nope:5s")

      # the feed's first fetch can land before the join: then the join reply
      # carries it (the latest payload), and no push follows until the next
      case reply do
        %{error: e} -> assert e == "the observer has no history for nope"
        _ -> assert_push "feed", %{error: "the observer has no history for nope"}, 2_000
      end
    end
  end
end

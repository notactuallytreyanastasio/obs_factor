defmodule ObsFactorWeb.PubSubFeedTest do
  # The observer's own PubSub, read through its own feeds: browsers'
  # channels are what subscribe in this VM, so join some and look.
  use ObsFactorWeb.ChannelCase, async: false

  alias ObsFactorWeb.{ActionsChannel, FeedChannel, SnapshotsChannel}

  setup do
    on_exit(fn ->
      for topic <- ObsFactor.Feeds.topics(), String.contains?(topic, ":pubsub"), pid = ObsFactor.Feeds.whereis(topic) do
        ref = Process.monitor(pid)
        receive(do: ({:DOWN, ^ref, _, _, _} -> :ok), after: (3_000 -> :ok))
      end
    end)
  end

  test "observer:observer:-:pubsub lists the topics the page's channels hold; a topic's view names its channel subscribers" do
    {:ok, _, _} = subscribe_and_join(authed_socket(), SnapshotsChannel, "snapshots")
    {:ok, _, _} = subscribe_and_join(authed_socket(), ActionsChannel, "actions")
    {:ok, _, list} = subscribe_and_join(authed_socket(), FeedChannel, "observer:observer:-:pubsub")
    assert_push "feed", %{data: data}, 5_000

    own = Enum.find(data["servers"], &(&1["name"] == "ObsFactor.PubSub"))
    topics = Enum.map(own["topics_list"], & &1["topic"])
    IO.puts("\n  the observer's own ObsFactor.PubSub: " <> Enum.map_join(own["topics_list"], ", ", &"#{&1["topic"]} (#{&1["subscriptions"]})"))

    assert "snapshots" in topics and "actions" in topics and "observer:observer:-:pubsub" in topics

    {:ok, _, _} = subscribe_and_join(authed_socket(), FeedChannel, "observer:observer:-:pubsub:ObsFactor.PubSub:snapshots")
    assert_push "feed", %{data: %{"topic" => "snapshots", "subscribers" => subs}}, 5_000
    # the channel process (with its fastlane to the socket), and this test
    # process, which subscribe_and_join subscribes too
    assert %{"kind" => "channel", "fastlane" => true, "initial_call" => "ObsFactorWeb.SnapshotsChannel.join/3"} =
             Enum.find(subs, &(&1["module"] == "ObsFactorWeb.SnapshotsChannel"))

    assert %{"kind" => "process"} = Enum.find(subs, &(&1["pid"] == FactoryReport.Observer.pid_text(self())))
    IO.puts("  snapshots, subscribed by: " <> Enum.map_join(subs, ", ", &"#{&1["pid"]} #{&1["kind"]} #{&1["module"]} mbox #{&1["message_queue_len"]}"))
    _ = list
  end
end

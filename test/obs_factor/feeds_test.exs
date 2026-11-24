defmodule ObsFactor.FeedsTest do
  use ExUnit.Case, async: true

  alias ObsFactor.Feeds

  # A fetch that counts its calls in an Agent and answers what the test says.
  defmodule Probe do
    def fetch({agent, :ok}), do: {:ok, %{n: Agent.get_and_update(agent, &{&1 + 1, &1 + 1})}}
    def fetch({_agent, :error}), do: {:error, "the sub-app answered 502"}
    def fetch({_agent, :raise}), do: raise("kaboom")
  end

  setup do
    {:ok, agent} = Agent.start_link(fn -> 0 end)
    # ends in ":" so no test's topic is a prefix of another's: refetch_prefix
    # of "feeds-test:8" also matched a concurrent test's "feeds-test:8453"
    topic = "feeds-test:#{System.unique_integer([:positive])}:"
    Phoenix.PubSub.subscribe(ObsFactor.PubSub, topic)
    %{agent: agent, topic: topic}
  end

  # a stand-in for a channel process: subscribes, reports what it got, waits
  defp viewer(topic, spec) do
    test = self()

    pid =
      spawn(fn ->
        send(test, {:joined, self(), Feeds.subscribe(topic, spec)})
        receive do: (:leave -> :ok)
      end)

    assert_receive {:joined, ^pid, {:ok, last}}
    {pid, last}
  end

  test "one feed per topic however many subscribe; the last result is replayed to a newcomer", %{
    agent: agent,
    topic: topic
  } do
    spec = {Probe, {agent, :ok}, 60_000}
    # the first fetch can finish before subscribe/2 returns, and then the
    # first subscriber is handed it: nil, or the first result, never another
    {_a, first} = viewer(topic, spec)
    assert first == nil or match?(%{data: %{n: 1}}, first)
    assert_receive {:feed, ^topic, %{at: at, data: %{n: 1}}}
    assert is_binary(at)

    feed = Feeds.whereis(topic)
    {_b, last} = viewer(topic, spec)
    assert last == %{at: at, data: %{n: 1}}
    assert Feeds.whereis(topic) == feed
    assert Agent.get(agent, & &1) == 1, "the second subscriber did not cause a fetch"
  end

  test "it fetches every interval and broadcasts each result", %{agent: agent, topic: topic} do
    {_a, _} = viewer(topic, {Probe, {agent, :ok}, 30})
    assert_receive {:feed, ^topic, %{data: %{n: 1}}}
    assert_receive {:feed, ^topic, %{data: %{n: 2}}}
    assert_receive {:feed, ^topic, %{data: %{n: 3}}}
  end

  test "an error, and a raise, are broadcast as errors", %{agent: agent, topic: topic} do
    {_a, _} = viewer(topic, {Probe, {agent, :error}, 60_000})
    assert_receive {:feed, ^topic, %{at: _, error: "the sub-app answered 502"} = p}
    refute Map.has_key?(p, :data)

    other = topic <> ":raise"
    Phoenix.PubSub.subscribe(ObsFactor.PubSub, other)
    {_b, _} = viewer(other, {Probe, {agent, :raise}, 60_000})
    assert_receive {:feed, ^other, %{error: "kaboom"}}
  end

  test "it stops after the last subscriber has gone, not before", %{agent: agent, topic: topic} do
    spec = {Probe, {agent, :ok}, 60_000}
    {a, _} = viewer(topic, spec)
    {b, _} = viewer(topic, spec)
    feed = Feeds.whereis(topic)
    ref = Process.monitor(feed)

    send(a, :leave)
    Process.sleep(Feeds.linger_ms() + 100)
    assert Process.alive?(feed), "one subscriber is still there"

    send(b, :leave)
    Process.sleep(div(Feeds.linger_ms(), 3))
    assert Process.alive?(feed), "it lingers"
    assert_receive {:DOWN, ^ref, :process, ^feed, :normal}, Feeds.linger_ms() + 500
    # the registry drops the name when it sees the DOWN itself
    assert Enum.any?(1..50, fn _ ->
             Feeds.whereis(topic) == nil or (Process.sleep(10) && false)
           end)
  end

  test "someone joining during the linger keeps it running", %{agent: agent, topic: topic} do
    spec = {Probe, {agent, :ok}, 60_000}
    {a, _} = viewer(topic, spec)
    # the first fetch has landed before anyone leaves: the joiner below is
    # handed it (under load it could still be in flight otherwise)
    assert_receive {:feed, ^topic, %{data: %{n: 1}}}
    feed = Feeds.whereis(topic)
    send(a, :leave)
    Process.sleep(div(Feeds.linger_ms(), 3))
    {_b, %{data: %{n: 1}}} = viewer(topic, spec)
    Process.sleep(Feeds.linger_ms() + 100)
    assert Feeds.whereis(topic) == feed
  end

  test "refetch fetches now, outside the interval; refetch_prefix finds the topics", %{agent: agent, topic: topic} do
    {_a, _} = viewer(topic, {Probe, {agent, :ok}, 60_000})
    assert_receive {:feed, ^topic, %{data: %{n: 1}}}
    assert Feeds.refetch_prefix(topic) == [topic]
    assert_receive {:feed, ^topic, %{data: %{n: 2}}}, 500
    assert Feeds.refetch("feeds-test:nobody") == :ok
    assert Feeds.refetch_prefix("feeds-test:nobody") == []
  end
end

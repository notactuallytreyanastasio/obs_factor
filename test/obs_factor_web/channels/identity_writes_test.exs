defmodule ObsFactorWeb.IdentityWritesTest do
  @moduledoc """
  The writes that arrived beside identities (alert routes, chapter 28; error
  budgets, chapter 32) are an operator's too: a viewer is refused on the
  server, before anything is stored, with the reason.
  """
  use ObsFactorWeb.ChannelCase, async: false

  @moduletag :capture_log

  @viewer %{"login" => "vera", "role" => "viewer", "via" => "github"}

  test "a viewer cannot save, delete or test an alert route" do
    {:ok, _, socket} = subscribe_and_join(authed_socket("v1", @viewer), ObsFactorWeb.AlertsChannel, "alerts")

    for {event, payload} <- [{"save_route", %{"name" => "x", "url" => "https://hooks.example/x"}}, {"delete_route", %{"id" => 1}}, {"test_route", %{"id" => 1}}] do
      ref = push(socket, event, payload)
      assert_reply ref, :error, %{error: "only an operator may " <> _}
    end
  end

  test "a viewer cannot set or remove an error budget" do
    {:ok, _, socket} = subscribe_and_join(authed_socket("v2", @viewer), ObsFactorWeb.SLOChannel, "slo")
    ref = push(socket, "save", %{"node" => "blog", "availability" => 0.995})
    assert_reply ref, :error, %{error: "only an operator may set an error budget" <> _}
    ref = push(socket, "delete", %{"node" => "blog"})
    assert_reply ref, :error, %{error: "only an operator may remove an error budget" <> _}
  end
end

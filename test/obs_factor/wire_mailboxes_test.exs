defmodule ObsFactor.Wire.MailboxesTest do
  use ExUnit.Case, async: true

  alias ObsFactor.Wire.Mailboxes

  test "a node with no backoff is due, whatever the sign of monotonic time" do
    now = System.monotonic_time(:millisecond)
    assert Mailboxes.due?(%{}, "marginalia", now)
    assert Mailboxes.due?(%{}, "marginalia", -576_460_000_000)
    refute Mailboxes.due?(%{"marginalia" => now + 1_000}, "marginalia", now)
    assert Mailboxes.due?(%{"marginalia" => now - 1}, "marginalia", now)
  end
end

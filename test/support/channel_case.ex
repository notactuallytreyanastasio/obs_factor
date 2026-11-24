defmodule ObsFactorWeb.ChannelCase do
  @moduledoc "Channel tests: `Phoenix.ChannelTest` against the running endpoint."
  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest
      @endpoint ObsFactorWeb.Endpoint

      # identities: a password login, an operator, unless the test says who
      defp authed_socket(sid \\ "test-session", identity \\ %{"login" => nil, "role" => "operator", "via" => "password"}),
        do: socket(ObsFactorWeb.UserSocket, "session:" <> sid, %{sid: sid, identity: identity})
    end
  end
end

defmodule ObsFactorWeb.ChannelCase do
  @moduledoc "Channel tests: `Phoenix.ChannelTest` against the running endpoint."
  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest
      @endpoint ObsFactorWeb.Endpoint

      defp authed_socket(sid \\ "test-session"),
        do: socket(ObsFactorWeb.UserSocket, "session:" <> sid, %{sid: sid})
    end
  end
end

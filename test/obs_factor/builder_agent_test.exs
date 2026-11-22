defmodule ObsFactor.Builder.AgentTest do
  use ExUnit.Case, async: true

  alias ObsFactor.Builder.{Agent, Recipe}

  setup do
    dir = Path.join(System.tmp_dir!(), "agent-#{System.unique_integer([:positive])}") |> Path.expand()
    File.mkdir_p!(Path.join(dir, "src"))
    File.write!(Path.join(dir, "README.md"), "# demo\nlisten on 8080\n")
    File.write!(Path.join(dir, "src/main.rs"), "fn main() { bind(\"0.0.0.0:8080\") }\n")
    File.ln_s!("/etc/hosts", Path.join(dir, "hosts-link"))
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, tools: Map.new(Recipe.tools(dir), &{&1.name, &1.run})}
  end

  describe "the recipe's tools stay in the clone" do
    test "read, list and grep work inside it", %{tools: t} do
      assert {:ok, "1\t# demo\n2\tlisten on 8080\n3\t"} = t["read_file"].(%{"path" => "README.md"})
      assert {:ok, list} = t["list_files"].(%{})
      assert list =~ "src/main.rs" and list =~ "README.md"
      refute list =~ "hosts-link"
      assert {:ok, "src/main.rs:1: " <> _} = t["grep"].(%{"pattern" => "0\\.0\\.0\\.0"})
    end

    test "paths out of the clone and through symlinks are refused", %{tools: t} do
      assert {:error, "../../etc/passwd is outside the repository"} = t["read_file"].(%{"path" => "../../etc/passwd"})
      assert {:error, "/etc/passwd is outside the repository"} = t["read_file"].(%{"path" => "/etc/passwd"})
      assert {:error, "hosts-link goes through a symlink" <> _} = t["read_file"].(%{"path" => "hosts-link"})
      assert {:error, ".gitmodules does not exist"} = t["grep"].(%{"pattern" => "x", "path" => ".gitmodules"})
    end

    test "writes only land under .obs_factor/", %{dir: dir, tools: t} do
      assert {:error, "only paths under .obs_factor/" <> _} = t["write_file"].(%{"path" => "Dockerfile", "content" => "x"})
      assert {:error, "only paths under .obs_factor/" <> _} = t["write_file"].(%{"path" => ".obs_factor/../x", "content" => "x"})
      assert {:ok, _} = t["write_file"].(%{"path" => ".obs_factor/build.json", "content" => "{}"})
      assert File.read!(Path.join(dir, ".obs_factor/build.json")) == "{}"
    end
  end

  # A chat completions server that answers from a script, one reply per call,
  # and records what it was sent.
  defmodule FakeLLM do
    use Plug.Router
    plug :match
    plug Plug.Parsers, parsers: [:json], json_decoder: Jason
    plug :dispatch

    post "/chat/completions" do
      {agent, _} = conn.private.script
      send(conn.private.test_pid, {:request, conn.body_params, get_req_header(conn, "authorization")})
      reply = Elixir.Agent.get_and_update(agent, fn [r | rest] -> {r, rest} end)
      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(reply))
    end

    def call(conn, opts) do
      conn |> put_private(:script, opts) |> put_private(:test_pid, elem(opts, 1)) |> super(opts)
    end
  end

  defp tool_call(id, name, args),
    do: %{"id" => id, "type" => "function", "function" => %{"name" => name, "arguments" => Jason.encode!(args)}}

  defp reply(msg, usage \\ %{"prompt_tokens" => 10, "completion_tokens" => 5}),
    do: %{"choices" => [%{"message" => msg}], "usage" => usage}

  defp serve(script) do
    {:ok, agent} = Elixir.Agent.start_link(fn -> script end)
    {:ok, pid} = Bandit.start_link(plug: {FakeLLM, {agent, self()}}, port: 0, ip: {127, 0, 0, 1}, startup_log: false)
    {:ok, {_, port}} = ThousandIsland.listener_info(pid)
    %{url: "http://127.0.0.1:#{port}", key: "test-key", model: "fake-1"}
  end

  test "the loop runs tool calls, feeds results back, and returns the final answer", %{dir: dir} do
    llm =
      serve([
        reply(%{"role" => "assistant", "content" => "", "tool_calls" => [tool_call("c1", "read_file", %{"path" => "README.md"})]}),
        reply(%{"role" => "assistant", "content" => nil, "tool_calls" => [tool_call("c2", "write_file", %{"path" => ".obs_factor/build.json", "content" => "{}"}), tool_call("c3", "nope", %{})]}),
        reply(%{"role" => "assistant", "content" => "Done: it serves on 8080."})
      ])

    {:ok, lines} = Elixir.Agent.start_link(fn -> [] end)
    log = fn l -> Elixir.Agent.update(lines, &(&1 ++ [l])) end

    assert {:ok, "Done: it serves on 8080.", %{prompt: 30, completion: 15, turns: [_, _, _]}} =
             Agent.run(llm, "sys", "user", Recipe.tools(dir), log)

    assert_received {:request, first, ["Bearer test-key"]}
    assert first["model"] == "fake-1"
    assert Enum.map(first["tools"], & &1["function"]["name"]) == ~w(list_files read_file grep write_file)

    assert_received {:request, second, _}
    [_sys, _user, %{"role" => "assistant"}, %{"role" => "tool", "tool_call_id" => "c1", "content" => readme}] = second["messages"]
    assert readme =~ "listen on 8080"

    assert_received {:request, third, _}
    tool_msgs = Enum.filter(third["messages"], &(&1["role"] == "tool"))
    assert Enum.map(tool_msgs, & &1["tool_call_id"]) == ~w(c1 c2 c3)
    assert List.last(tool_msgs)["content"] == "no tool named nope"

    assert File.exists?(Path.join(dir, ".obs_factor/build.json"))
    assert Enum.any?(Elixir.Agent.get(lines, & &1), &(&1 =~ "agent nope"))
  end

  test "compaction stubs old tool results in one batch and leaves recent ones" do
    msgs = [
      %{role: "system", content: "s"},
      %{role: "assistant", content: nil, tool_calls: []},
      %{role: "tool", tool_call_id: "a", content: String.duplicate("x", 5000), turn: 1, label: "read_file README.md"},
      %{role: "tool", tool_call_id: "b", content: "recent", turn: 3, label: "grep \"port\""}
    ]

    {out, 1} = Agent.compact(msgs, 2)
    assert Enum.at(out, 2).content == "[read_file README.md: 5000 bytes of output, removed to save context. Call the tool again if you need it.]"
    assert Enum.at(out, 3).content == "recent"
    # Already stubbed results are not touched again, so the prefix stays stable.
    assert {^out, 0} = Agent.compact(out, 2)
  end

  test "past the threshold the loop compacts before the next request", %{dir: dir} do
    big = %{"prompt_tokens" => 50_000, "completion_tokens" => 5}

    llm =
      serve([
        reply(%{"role" => "assistant", "content" => "", "tool_calls" => [tool_call("c1", "read_file", %{"path" => "README.md"})]}),
        reply(%{"role" => "assistant", "content" => "", "tool_calls" => [tool_call("c2", "list_files", %{})]}, big),
        reply(%{"role" => "assistant", "content" => "done"})
      ])

    assert {:ok, "done", %{compactions: 1}} = Agent.run(llm, "s", "u", Recipe.tools(dir), fn _ -> :ok end, compact_at: 20_000, keep_turns: 1)
    assert_received {:request, _, _}
    assert_received {:request, _, _}
    assert_received {:request, third, _}
    [c1, c2] = Enum.filter(third["messages"], &(&1["role"] == "tool"))
    assert c1["content"] =~ "[read_file README.md:" and c1["content"] =~ "removed to save context"
    assert c2["content"] =~ "README.md"
    refute Map.has_key?(c1, "turn") or Map.has_key?(c1, "label")
  end

  test "a model that never stops is cut off, not trusted", %{dir: dir} do
    loop = reply(%{"role" => "assistant", "content" => "", "tool_calls" => [tool_call("c", "list_files", %{})]})
    llm = serve(List.duplicate(loop, 5))
    assert {:error, "the agent did not finish in 3 turns"} = Agent.run(llm, "s", "u", Recipe.tools(dir), fn _ -> :ok end, max_turns: 3)
  end
end

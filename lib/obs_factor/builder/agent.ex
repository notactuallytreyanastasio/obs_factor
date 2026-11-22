defmodule ObsFactor.Builder.Agent do
  @moduledoc """
  A small tool-using agent over any OpenAI-compatible chat completions API
  (`POST {base}/chat/completions` with `tools`). DeepSeek in the lab; nothing
  here is specific to it.

  The loop: send the conversation; if the reply has `tool_calls`, run each
  one with the caller's handler and append the results as `tool` messages;
  repeat until the model answers without tool calls (that answer is the
  result) or `max_turns` is reached (an error, not a guess).

  Tools are `%{name, description, parameters (JSON Schema), run: fn args -> {:ok | :error, text}}`.
  A tool that raises, or gets arguments that are not JSON, answers the model
  with the error, so it can correct itself; the loop does not crash on it.
  """

  @doc """
  `run(llm, system, user, tools, log, opts)`. `llm` is `%{url, key, model}`.
  Options:

  - `:max_turns` (default 30)
  - `:compact_at` (prompt tokens, default 24_000) and `:keep_turns`
    (default 2): see "Compaction" below. `compact_at: nil` turns it off.

  Returns `{:ok, final_text, usage}` or `{:error, message}`. `usage` sums
  prompt, cached and completion tokens, lists them per turn, and counts
  compactions.

  ## Compaction

  Every turn resends the whole conversation, so a file read on turn 2 is
  paid for again on every later turn. When the provider reports a prompt
  above `:compact_at`, every tool result older than the last `:keep_turns`
  turns is replaced by a one-line stub naming the call, all at once. Doing
  it in one batch, and only past the threshold, keeps the conversation's
  prefix unchanged between compactions, which is what a provider's prefix
  cache needs (DeepSeek bills cache hits at a fraction of a miss). The
  model is told the stubbed results can be fetched again.
  """
  def run(llm, system, user, tools, log, opts \\ []) do
    messages = [%{role: "system", content: system}, %{role: "user", content: user}]

    st = %{
      llm: llm,
      specs: Enum.map(tools, &spec/1),
      tools: Map.new(tools, &{&1.name, &1}),
      log: log,
      max: Keyword.get(opts, :max_turns, 30),
      compact_at: Keyword.get(opts, :compact_at, 24_000),
      keep: Keyword.get(opts, :keep_turns, 2)
    }

    loop(st, messages, 1, %{prompt: 0, cached: 0, completion: 0, turns: [], compactions: 0})
  end

  defp loop(%{max: max}, _messages, turn, _usage) when turn > max,
    do: {:error, "the agent did not finish in #{max} turns"}

  defp loop(st, messages, turn, usage) do
    with {:ok, %{"choices" => [%{"message" => msg} | _]} = body} <- complete(st.llm, messages, st.specs) do
      usage = add_usage(usage, body["usage"], length(msg["tool_calls"] || []))
      text = msg["content"] || ""
      calls = msg["tool_calls"] || []
      if String.trim(text) != "" and calls != [], do: st.log.("agent: " <> String.trim(text))

      case calls do
        [] ->
          {:ok, String.trim(text), usage}

        calls ->
          # Send back only what the API defines for an assistant turn.
          assistant = %{role: "assistant", content: msg["content"], tool_calls: calls}

          results =
            Enum.map(calls, fn %{"id" => id, "function" => %{"name" => name, "arguments" => raw}} ->
              {status, out} = call(st.tools, name, raw)
              st.log.("agent #{name} #{brief(raw)}#{if status == :error, do: " -> " <> String.slice(out, 0, 160), else: ""}")
              # :turn and :label stay on our side (stripped before sending).
              %{role: "tool", tool_call_id: id, content: out, turn: turn, label: "#{name} #{brief(raw)}"}
            end)

          messages = messages ++ [assistant | results]
          prompt = body["usage"]["prompt_tokens"] || 0

          {messages, usage} =
            if st.compact_at && prompt > st.compact_at do
              {compacted, n} = compact(messages, turn - st.keep)
              if n > 0, do: st.log.("agent: context at #{prompt} tokens; replaced #{n} old tool results with stubs")
              {compacted, %{usage | compactions: usage.compactions + 1}}
            else
              {messages, usage}
            end

          loop(st, messages, turn + 1, usage)
      end
    else
      {:ok, body} -> {:error, "unexpected reply from #{st.llm.url}: #{inspect(body, limit: 5) |> String.slice(0, 300)}"}
      {:error, _} = e -> e
    end
  end

  @doc false
  # Stubs every tool result from turns up to `upto`. Returns {messages, count}.
  def compact(messages, upto) do
    Enum.map_reduce(messages, 0, fn
      %{role: "tool", turn: t, label: label, content: c} = m, n when t <= upto and not is_map_key(m, :stub) ->
        stub = "[#{label}: #{byte_size(c)} bytes of output, removed to save context. Call the tool again if you need it.]"
        {m |> Map.put(:content, stub) |> Map.put(:stub, true), n + 1}

      m, n ->
        {m, n}
    end)
  end

  defp complete(llm, messages, specs) do
    result =
      Req.post(llm.url <> "/chat/completions",
        auth: {:bearer, llm.key},
        json: %{model: llm.model, messages: Enum.map(messages, &Map.drop(&1, [:turn, :label, :stub])), tools: specs},
        receive_timeout: 300_000,
        retry: :transient,
        max_retries: 3
      )

    case result do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) -> {:ok, body}
      {:ok, %Req.Response{status: s, body: body}} -> {:error, "#{llm.url} answered #{s}: #{inspect(body) |> String.slice(0, 300)}"}
      {:error, e} -> {:error, "#{llm.url}: #{Exception.message(e)}"}
    end
  end

  defp call(tools, name, raw) do
    with %{} = tool <- Map.get(tools, name) || {:error, "no tool named #{name}"},
         {:ok, args} when is_map(args) <- Jason.decode(raw || "{}") do
      tool.run.(args)
    else
      {:error, %Jason.DecodeError{}} -> {:error, "arguments are not JSON"}
      {:ok, _} -> {:error, "arguments must be a JSON object"}
      {:error, msg} -> {:error, msg}
    end
  rescue
    e -> {:error, "tool #{name} failed: #{Exception.message(e)}"}
  end

  defp spec(t), do: %{type: "function", function: %{name: t.name, description: t.description, parameters: t.parameters}}

  defp brief(raw) do
    case Jason.decode(raw || "{}") do
      {:ok, %{"path" => p}} -> p
      {:ok, %{"pattern" => p}} -> inspect(p)
      _ -> ""
    end
  end

  # Per turn: prompt tokens, how many of them the provider's prefix cache
  # served (DeepSeek: prompt_cache_hit_tokens; OpenAI: cached_tokens),
  # completion tokens, tool calls made.
  defp add_usage(u, %{"prompt_tokens" => p, "completion_tokens" => c} = raw, calls) do
    hit = raw["prompt_cache_hit_tokens"] || get_in(raw, ["prompt_tokens_details", "cached_tokens"]) || 0

    %{u | prompt: u.prompt + p, cached: u.cached + hit, completion: u.completion + c, turns: u.turns ++ [%{prompt: p, cached: hit, completion: c, calls: calls}]}
  end

  defp add_usage(u, _, _), do: u
end

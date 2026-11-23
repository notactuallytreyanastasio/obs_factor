defmodule ObsFactor.ObserverProxy do
  @moduledoc """
  The floor's way into a building's BEAM: `/api/nodes/:id/observer/*path`
  (docs/contract.md, "Observer").

  * `id == "observer"`: the observer's own VM, answered in-process by
    `FactoryReport.Observer.dispatch/4`. No HTTP, no reporter.
  * any topology node with a `report` URL: forwarded to the `/observer/...`
    beside that report (same scheme, host, port and mount path; `/report`
    at the end of the path is replaced), with `REPORT_TOKEN` for reads and
    `OBSERVER_ACTIONS_TOKEN` for actions. A node whose report host has
    several members (a scaled service) needs `member=<address>`, and the
    address must be one of the members the reports collector read last.

  Reads time out after 3 s, actions after 5 s. Every answer is
  `{status, json_body}`; an upstream that cannot be reached or does not
  answer JSON is `{502 | upstream status, %{"error" => ...}}`. Every action
  is logged here at warning with `source: "actions"`, whatever came of it.
  """

  require Logger

  alias FactoryReport.Observer

  @read_timeout 3_000
  @action_timeout 5_000
  @max_body 4 * 1024 * 1024
  @segment ~r/\A[A-Za-z0-9_.\-]{1,200}\z/

  @doc "The observer's own node id on the floor."
  def self_id, do: "observer"

  @doc """
  One request. `params` are the query parameters (GET) or the JSON body
  (POST), without `id`, `path` or `member`. `opts`: `member:` (an address
  or nil), `by:` (who asked; required for POST).
  """
  def call(method, id, path, params, opts) do
    started = System.monotonic_time()

    result =
      with :ok <- check_path(path),
           :ok <- check_by(method, opts[:by]),
           :ok <- check_member(id, opts[:member]) do
        route(method, id, path, params, opts)
      end

    if method == "POST" do
      record_action(id, path, params, Keyword.put(opts, :took_ms, since(started)), result)
      refetch_after(id, opts[:member], result)
    end

    result
  end

  @doc """
  Whether `id` (and `member`, an address or nil) is something the
  pass-through would reach: `:ok` or `{status, %{"error" => ...}}`, the same
  answer a request would get. The node must be `"observer"` or a topology
  node with a `report` URL; the member is checked against the members the
  reports collector read last (what the snapshot's `inside.members` shows).
  No request is made.
  """
  def check_target(id, member) do
    with :ok <- check_member(id, member) do
      if id == self_id() do
        :ok
      else
        with {:ok, node} <- topology_node(id),
             {:ok, _base} <- base(node, member),
             do: :ok
      end
    end
  end

  @doc """
  Who is acting, as the pass-through accepts it: non-printing characters
  removed, surrounding blanks trimmed, cut at 80 characters; nil for
  anything that is not a string or is empty after that (so a blank name is
  "nobody said", and a POST with it is refused).
  """
  def clean_by(by) when is_binary(by) do
    case by |> String.replace(~r/[^[:print:]]/u, "") |> String.trim() |> String.slice(0, 80) do
      "" -> nil
      clean -> clean
    end
  end

  def clean_by(_), do: nil

  @doc """
  The prefix of every feed topic of `id` / `member`
  (`observer:<id>:<member or ->:`), the ones refetched after an action there.
  """
  def topic_prefix(id, member) do
    m = if is_binary(member) and member != "", do: member, else: "-"
    "observer:#{id}:#{m}:"
  end

  # An action that reached the engine (done, or a supervisor call that failed
  # or timed out half way) may have changed what the feeds show: fetch
  # them now rather than at their next period.
  defp refetch_after(id, member, {status, _}) when status in 200..299 or status in [500, 504],
    do: ObsFactor.Feeds.refetch_prefix(topic_prefix(id, member))

  defp refetch_after(_, _, _), do: :ok

  @doc """
  The PubSub topic every action is broadcast on, as
  `{:action, %{"at", "node", "member", "path", "params", "by", "status", "result", "error"}}`
  (docs/contract.md, "Observer").
  """
  def actions_topic, do: "actions"

  defp check_path(path) do
    case Enum.find(path, &(not Regex.match?(@segment, &1))) do
      nil -> :ok
      bad -> {400, %{"error" => "bad path segment #{inspect(String.slice(bad, 0, 60))}"}}
    end
  end

  defp check_by("POST", by) when is_binary(by) and by != "", do: :ok
  defp check_by("POST", _), do: {400, %{"error" => "say who is acting: an x-factory-by header or \"by\" in the body"}}
  defp check_by(_, _), do: :ok

  defp check_member("observer", member) when is_binary(member) and member != "",
    do: {400, %{"error" => "the observer is one VM: member= does not apply to node observer"}}

  defp check_member(_, _), do: :ok

  defp route(method, "observer", path, params, opts) do
    if method == "POST" and is_nil(actions_token()) do
      {403, %{"error" => "actions are off: OBSERVER_ACTIONS_TOKEN is not set on the observer"}}
    else
      {status, body} = Observer.dispatch(method, path, params, by: opts[:by], log: false)
      {status, if(path == [], do: Map.put(body, "proxy", proxy_info()), else: body)}
    end
  end

  defp route(method, id, path, params, opts) do
    with {:ok, node} <- topology_node(id),
         {:ok, base} <- base(node, opts[:member]) do
      forward(method, base, path, params, opts)
    end
  end

  defp proxy_info, do: %{"actions" => not is_nil(actions_token())}

  defp topology_node(id) do
    case Enum.find(ObsFactor.topology().nodes, &(&1.id == id)) do
      nil -> {404, %{"error" => "no node #{inspect(id)} in the topology"}}
      %{report: nil} -> {404, %{"error" => "node #{id} has no report URL, so no observer"}}
      node -> {:ok, node}
    end
  end

  # The URL the request goes to, without the observer path: the report URL
  # with its host replaced by the member's address when there is one.
  defp base(node, member) do
    uri = URI.parse(node.report)
    members = members(node.id)

    cond do
      is_binary(member) and member != "" ->
        case members do
          {:ok, []} ->
            {400, %{"error" => "#{node.id} is one node, not a cluster: member= does not apply"}}

          {:ok, addrs} ->
            if member in addrs,
              do: {:ok, base_uri(uri, member)},
              else: {400, %{"error" => "#{inspect(member)} is not one of #{node.id}'s current members (#{Enum.join(addrs, ", ")})"}}

          {:error, reason} ->
            {400, %{"error" => "#{node.id}'s members are not known: #{reason}"}}
        end

      match?({:ok, [_, _ | _]}, members) ->
        {:ok, addrs} = members
        {400, %{"error" => "#{node.id} has #{length(addrs)} members: say which with member= (#{Enum.join(addrs, ", ")})"}}

      length(ObsFactor.Reports.expand(node.report)) > 1 ->
        {400, %{"error" => "#{node.id}'s report host resolves to several addresses: say which with member="}}

      true ->
        {:ok, base_uri(uri, nil)}
    end
  end

  defp base_uri(uri, member) do
    path = (uri.path || "") |> String.replace_suffix("/report", "") |> String.trim_trailing("/")
    host = if member, do: member, else: uri.host
    %URI{scheme: uri.scheme, host: host, port: uri.port, path: path <> "/observer"}
  end

  @doc """
  The members of a clustered node, as the reports collector last read them:
  `{:ok, [address]}` (empty for a single node) or `{:error, reason}`.
  """
  def members(id) do
    case ObsFactor.Sources.get(:reports) do
      %{ok: true, data: %{^id => %{members: members}}} when is_list(members) -> {:ok, Enum.map(members, & &1.address)}
      %{ok: true, data: %{^id => _}} -> {:ok, []}
      %{ok: true} -> {:error, "the reports collector has no result for #{id}"}
      %{error: error} -> {:error, "reports source: #{error}"}
    end
  end

  defp forward(method, base, path, params, opts) do
    uri = %{base | path: Enum.join([base.path | path], "/")}
    target = "#{uri.host}:#{uri.port}"

    {uri, req_opts} =
      case method do
        "GET" ->
          query = if params == %{}, do: nil, else: URI.encode_query(params)
          {%{uri | query: query}, [timeout: @read_timeout, headers: bearer(report_token())]}

        "POST" ->
          case actions_token() do
            nil ->
              throw({403, %{"error" => "actions are off: OBSERVER_ACTIONS_TOKEN is not set on the observer"}})

            token ->
              headers = bearer(token) ++ [{"content-type", "application/json"}, {"x-factory-by", opts[:by]}]
              {uri, [timeout: @action_timeout, headers: headers, body: Jason.encode!(params)]}
          end
      end

    method_atom = if method == "POST", do: :post, else: :get

    case ObsFactor.Http.request(method_atom, URI.to_string(uri), [decode: false] ++ req_opts) do
      {:ok, status, body, _ms} when byte_size(body) <= @max_body ->
        case Jason.decode(body) do
          {:ok, %{} = json} ->
            {status, json}

          _ ->
            hint = if status == 404, do: " (a factory_report without the observer?)", else: ""
            {status, %{"error" => "#{target} answered #{status}: #{body |> String.slice(0, 120) |> String.trim()}#{hint}", "upstream_status" => status}}
        end

      {:ok, status, _body, _ms} ->
        {502, %{"error" => "#{target} answered more than #{@max_body} bytes", "upstream_status" => status}}

      {:error, message} ->
        {502, %{"error" => "#{target}: #{message}", "upstream_status" => nil}}
    end
  catch
    {status, %{} = body} when is_integer(status) -> {status, body}
  end

  defp bearer(nil), do: []
  defp bearer(token), do: [{"authorization", "Bearer " <> token}]

  # Milliseconds since a System.monotonic_time/0 reading, to the microsecond.
  defp since(started), do: System.convert_time_unit(System.monotonic_time() - started, :native, :microsecond) / 1000

  defp report_token, do: Application.get_env(:obs_factor, :sources, [])[:report_token]
  defp actions_token, do: Application.get_env(:obs_factor, :observer_actions_token)

  @doc """
  Records one action, refused or done: one warning line (LogRing, source
  "actions") and one `{:action, map}` on `actions_topic/0` for every viewer.
  `call/5` does this for every POST; anything else that acts on behalf of a
  viewer (a refusal before `call/5` is reached, `POST /api/builds`) calls
  it directly. `opts`: `member:`, `by:`, `keys:` (the params shown, default
  reason, supervisor, child_id, level). `path` is a list of segments.
  """
  def record_action(id, path, params, opts, {status, body}) do
    member = if is_binary(opts[:member]) and opts[:member] != "", do: opts[:member]
    by = opts[:by]
    where = if member, do: "#{id} (#{member})", else: id
    shown = if is_map(params), do: Map.take(params, opts[:keys] || ~w(reason supervisor child_id level)), else: %{}
    body = if is_map(body), do: body, else: %{}
    args = shown |> Enum.map_join(" ", fn {k, v} -> "#{k}=#{inspect(v)}" end)
    ok? = status in 200..299
    outcome = if ok?, do: "ok", else: "#{status}: #{body["error"]}"
    path_text = path |> Enum.join("/") |> String.slice(0, 300)

    # action.done / action.refused: `action` the last path segment (gc, kill,
    # exit, restart, level, builds), `target` the segments between (a pid,
    # an application), `args` the params shown in the message.
    {action, target} =
      case path do
        [] -> {nil, nil}
        [one] -> {String.slice(one, 0, 200), nil}
        [_ | _] -> {path |> List.last() |> String.slice(0, 200), path |> Enum.slice(1..-2//1) |> Enum.join("/") |> String.slice(0, 300) |> then(&if(&1 == "", do: nil, else: &1))}
      end

    Logger.warning("action #{if path_text == "", do: "(no path)", else: path_text}#{if args != "", do: " " <> args} on #{where} by #{by || "nobody said"}: #{outcome}",
      event: if(ok?, do: "action.done", else: "action.refused"),
      source: "actions",
      node: id,
      member: member,
      action: action,
      target: target,
      args: if(args != "", do: args),
      path: path_text,
      by: by,
      status: status,
      took_ms: opts[:took_ms],
      error: if(ok?, do: nil, else: body["error"] || "status #{status}")
    )

    Phoenix.PubSub.broadcast(ObsFactor.PubSub, actions_topic(), {:action,
     %{
       "at" => DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601(),
       "node" => id,
       "member" => member,
       "path" => path_text,
       "params" => shown,
       "by" => by,
       "status" => status,
       "result" => if(ok?, do: body),
       "error" => if(ok?, do: nil, else: body["error"] || "status #{status}")
     }})
  end
end

defmodule ObsFactor.Jobs.Webhook do
  @moduledoc """
  A post to a webhook: an alert route's (`ObsFactor.Alerts`) or a scheduled
  writeup's. `%{"url", "body", "for" => "alert" | "schedule", "ref" => id}`.

  Five attempts, after 5 s, 30 s, 2 min and 10 min: a Slack that is down
  for a quarter of an hour still gets the message. The URL is checked again
  on every attempt (`ObsFactor.WebhookGuard.post/2`). The outcome is written
  where the panel that made it shows it: on success at once, on failure only
  once the last attempt has failed (the Oban tab shows the attempts in
  between), as the route's `last_error` or the schedule's.
  """
  use Oban.Worker, queue: :webhooks, max_attempts: 5
  require Logger

  alias ObsFactor.{Alerts, Jobs}
  alias ObsFactor.Writeup.{Scheduler, Schedules}

  @backoff [5, 30, 120, 600]

  @doc "A job for `body` to `url`, on behalf of an alert route or a schedule."
  def new_post(for_what, ref, url, body) when for_what in [:alert, :schedule],
    do: new(%{url: url, body: body, for: for_what, ref: ref})

  @doc """
  A `post` function (`url, body -> :ok | {:error, e}`) that enqueues instead
  of posting: what `Schedules.run/3` and the alerts engine are given when
  Oban runs.
  """
  def enqueue_for(for_what, ref) do
    fn url, body ->
      case Jobs.insert(new_post(for_what, ref, url, body)) do
        {:ok, _} ->
          :ok

        {:error, %Ecto.Changeset{} = c} ->
          {:error, "could not enqueue the webhook: #{inspect(c.errors)}"}

        {:error, e} ->
          {:error, "could not enqueue the webhook: #{ObsFactor.Tape.message(e)}"}
      end
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: n}), do: Enum.at(@backoff, n - 1, List.last(@backoff))

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"url" => url, "body" => body} = a, attempt: n, max_attempts: max}) do
    post = Application.get_env(:obs_factor, :webhook_post, &ObsFactor.WebhookGuard.post/2)

    case post.(url, body) do
      :ok ->
        record(a, :ok)
        :ok

      {:error, e} ->
        if n >= max do
          Logger.warning("webhook for #{a["for"]} #{a["ref"]} failed #{n} times: #{e}",
            event: "jobs.webhook_failed",
            reason: e
          )

          record(a, {:error, "#{e} (#{n} tries)"})
        end

        {:error, e}
    end
  end

  defp record(%{"for" => "alert", "ref" => id}, result) when is_integer(id) do
    Alerts.record(id, result)
    Alerts.broadcast()
  end

  defp record(%{"for" => "schedule", "ref" => id}, result) when is_integer(id) do
    Schedules.record_webhook(id, result)
    Scheduler.broadcast()
  end

  defp record(_, _), do: :ok
end

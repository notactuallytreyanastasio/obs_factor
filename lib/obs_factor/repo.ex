defmodule ObsFactor.Repo do
  @moduledoc """
  The Ecto repo Oban runs on (`ObsFactor.Jobs`): the objectives database
  (OBJECTIVES_PG_URL), through a pool of its own, two connections.

  Nothing else in the observer goes through it. The tape, the objectives and
  everything that writes beside them keep their own Postgrex pool
  (`ObsFactor.Tape.db/0`), so a slow job never queues a tape write and the
  tape never starves a job. The role's CONNECTION LIMIT is 4 for this
  reason: 2 there, 2 here (deploy/objectives-db.sql).

  Started with its URL by `ObsFactor.Jobs.child_specs/1`; there is no repo
  config to read at compile time.
  """
  use Ecto.Repo, otp_app: :obs_factor, adapter: Ecto.Adapters.Postgres
end

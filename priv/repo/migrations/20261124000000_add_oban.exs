defmodule ObsFactor.Repo.Migrations.AddOban do
  use Ecto.Migration

  # Oban's tables (oban_jobs, oban_peers), at the version Oban 2.24 ships.
  def up, do: Oban.Migration.up(version: 14)
  def down, do: Oban.Migration.down(version: 1)
end

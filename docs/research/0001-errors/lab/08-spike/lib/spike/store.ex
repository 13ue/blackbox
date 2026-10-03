defmodule Spike.Repo do
  use Ecto.Repo, otp_app: :spike, adapter: Ecto.Adapters.Postgres
end

defmodule Spike.DownRepo do
  use Ecto.Repo, otp_app: :spike, adapter: Ecto.Adapters.Postgres
end

defmodule Spike.Store do
  @moduledoc "issues (one row per fingerprint, upserted) + occurrences (the samples)."
  import Ecto.Query

  def setup!(repo) do
    repo.query!("""
    CREATE TABLE IF NOT EXISTS issues (
      id bigserial PRIMARY KEY, fingerprint text NOT NULL UNIQUE, type text NOT NULL,
      title text, count bigint NOT NULL, first_seen timestamptz NOT NULL, last_seen timestamptz NOT NULL,
      status text NOT NULL DEFAULT 'open')
    """)

    repo.query!("""
    CREATE TABLE IF NOT EXISTS occurrences (
      id bigserial PRIMARY KEY, issue_id bigint NOT NULL REFERENCES issues ON DELETE CASCADE,
      payload jsonb NOT NULL, inserted_at timestamptz NOT NULL DEFAULT now())
    """)

    repo.query!("CREATE INDEX IF NOT EXISTS occurrences_issue_id ON occurrences (issue_id, id DESC)")
  end

  def writer(repo), do: fn batch -> write(repo, batch) end

  def write(repo, batch) do
    now = DateTime.utc_now()
    # Sorted so two writers on two nodes lock rows in the same order (no deadlock).
    batch = Enum.sort_by(batch, & &1.fingerprint)

    rows =
      for i <- batch do
        %{fingerprint: i.fingerprint, type: i.type, title: String.slice(hd(i.samples).message || "", 0, 200),
          count: i.count, first_seen: now, last_seen: now}
      end

    upsert = from(i in "issues", update: [set: [count: fragment("? + EXCLUDED.count", i.count), last_seen: fragment("EXCLUDED.last_seen")]])

    repo.transaction(fn ->
      {_, ids} = repo.insert_all("issues", rows, on_conflict: upsert, conflict_target: :fingerprint, returning: [:id, :fingerprint])
      id_of = Map.new(ids, &{&1.fingerprint, &1.id})
      occ = for i <- batch, s <- i.samples, do: %{issue_id: id_of[i.fingerprint], payload: s}
      repo.insert_all("occurrences", occ)
    end)

    :ok
  rescue
    e -> {:error, e}
  catch
    :exit, r -> {:error, r}
  end
end

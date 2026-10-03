if Code.ensure_loaded?(Ecto.Migration) do
  defmodule Blackbox.Migration do
    @moduledoc """
    Blackbox's tables, as versioned migrations. `mix blackbox.gen.migration`
    writes a host migration that calls these:

        def up, do: Blackbox.Migration.up(version: 1)
        def down, do: Blackbox.Migration.down(version: 1)

    A later Blackbox release adds version 2; the host adds a migration that
    calls `up(version: 2)`.
    """
    use Ecto.Migration

    @current 1

    def current_version, do: @current

    def up(opts \\ []), do: change(:up, Keyword.get(opts, :version, @current))
    def down(opts \\ []), do: change(:down, Keyword.get(opts, :version, @current))

    defp change(:up, 1) do
      execute("""
      CREATE TABLE blackbox_issues (
        id bigserial PRIMARY KEY,
        fingerprint text NOT NULL UNIQUE,
        grouping_version integer NOT NULL,
        kind text NOT NULL,
        type text NOT NULL,
        title text NOT NULL,
        state text NOT NULL DEFAULT 'open' CHECK (state IN ('open', 'resolved', 'muted')),
        count bigint NOT NULL,
        first_seen timestamptz NOT NULL,
        last_seen timestamptz NOT NULL,
        first_build text NOT NULL,
        last_build text NOT NULL,
        builds text[] NOT NULL,
        resolved_at timestamptz,
        resolved_build text,
        resolved_builds text[],
        muted_until timestamptz,
        muted_count bigint,
        note text
      )
      """)

      execute("""
      CREATE TABLE blackbox_occurrences (
        id bigserial PRIMARY KEY,
        issue_id bigint NOT NULL REFERENCES blackbox_issues ON DELETE CASCADE,
        fingerprint text NOT NULL,
        kind text NOT NULL,
        type text NOT NULL,
        message text NOT NULL,
        source text NOT NULL,
        build text NOT NULL,
        node text NOT NULL,
        at timestamptz NOT NULL,
        payload jsonb NOT NULL
      )
      """)

      execute(
        "CREATE INDEX blackbox_occurrences_issue ON blackbox_occurrences (issue_id, id DESC)"
      )

      execute("CREATE INDEX blackbox_occurrences_at ON blackbox_occurrences (at)")
      execute("CREATE INDEX blackbox_issues_last_seen ON blackbox_issues (last_seen DESC)")
    end

    defp change(:down, 1) do
      execute("DROP TABLE blackbox_occurrences")
      execute("DROP TABLE blackbox_issues")
    end
  end
end

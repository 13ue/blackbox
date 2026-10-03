if Code.ensure_loaded?(Ecto.Adapters.SQL) do
  defmodule Blackbox.Issues do
    @moduledoc false
    # Reads and state changes for the page and the API. Reads use the host's
    # Repo (the store's own pool is for writes); state is derived on read:
    #
    #   regressed  resolved, and seen since in a build it had not been seen in
    #   muted      until a date or a count, whichever comes first
    #   new        first seen in the last 24 h
    #
    # An occurrence from an old build still running during a deploy stays on
    # the resolved issue.

    @status """
    CASE
      WHEN state = 'resolved' AND last_seen > resolved_at AND NOT (builds <@ coalesce(resolved_builds, '{}')) THEN 'regressed'
      WHEN state = 'resolved' THEN 'resolved'
      WHEN state = 'muted' AND (muted_until IS NULL OR muted_until > now()) AND (muted_count IS NULL OR count < muted_count) THEN 'muted'
      WHEN first_seen > now() - interval '24 hours' THEN 'new'
      ELSE 'open'
    END
    """

    @columns "id, fingerprint, kind, type, title, count, first_seen, last_seen, first_build, last_build, builds, " <>
               "resolved_at, resolved_build, muted_until, muted_count, note, grouping_version, (#{@status}) AS status"

    def repo, do: Application.get_env(:blackbox, :repo) || raise("Blackbox: no store attached")

    @doc "Issues by status and recency; regressed and new first."
    def list(params \\ %{}) do
      {where, args} = filters(params)
      limit = params |> Map.get("limit", "100") |> to_int(100) |> min(500)

      sql = """
      SELECT * FROM (SELECT #{@columns} FROM blackbox_issues) i
      WHERE #{Enum.join(where, " AND ")}
      ORDER BY CASE status WHEN 'regressed' THEN 0 WHEN 'new' THEN 1 WHEN 'open' THEN 2 WHEN 'muted' THEN 3 ELSE 4 END,
               last_seen DESC
      LIMIT #{limit}
      """

      rows(repo().query!(sql, args))
    end

    # Each filter adds a clause; `with_arg` numbers its placeholder.
    defp filters(params) do
      with_arg = fn {where, args}, clause, v ->
        {[clause.("$#{length(args) + 1}") | where], args ++ [v]}
      end

      acc = {[], []}

      acc =
        case params["state"] do
          nil ->
            put_elem(acc, 0, ["status IN ('regressed', 'new', 'open')"])

          "all" ->
            acc

          s when s in ~w(regressed new open muted resolved) ->
            with_arg.(acc, &"status = #{&1}", s)

          _ ->
            put_elem(acc, 0, ["false"])
        end

      # Browser events are an ingest anyone with a page can write to: shown only when asked for.
      acc =
        case params["source"] do
          nil -> {["kind <> 'browser'" | elem(acc, 0)], elem(acc, 1)}
          "all" -> acc
          s -> with_arg.(acc, &"kind = #{&1}", s)
        end

      acc =
        case params["since_build"] do
          nil ->
            acc

          b ->
            with_arg.(
              acc,
              &"last_seen >= (SELECT coalesce(min(at), 'infinity') FROM blackbox_occurrences WHERE build = #{&1})",
              b
            )
        end

      case acc do
        {[], args} -> {["true"], args}
        {where, args} -> {where, args}
      end
    end

    def get(id) do
      with {id, ""} <- Integer.parse(to_string(id)),
           [issue] <-
             rows(repo().query!("SELECT #{@columns} FROM blackbox_issues WHERE id = $1", [id])) do
        Map.put(issue, :recommended, recommended(id))
      else
        _ -> nil
      end
    end

    # The occurrence with the most context among the latest 20.
    defp recommended(issue_id) do
      %{rows: rows} =
        repo().query!(
          """
          SELECT id, ref, build, node, at, payload::text FROM (
            SELECT * FROM blackbox_occurrences WHERE issue_id = $1 ORDER BY id DESC LIMIT 20) o
          ORDER BY coalesce(jsonb_array_length(payload->'crumbs'), 0)
                 + coalesce(jsonb_array_length(payload->'caller_crumbs'), 0)
                 + (SELECT count(*) FROM jsonb_object_keys(coalesce(payload->'locals', '{}'))) DESC, id DESC
          LIMIT 1
          """,
          [issue_id]
        )

      case rows do
        [[id, ref, build, node, at, payload]] ->
          %{id: id, ref: ref, build: build, node: node, at: at, payload: JSON.decode!(payload)}

        [] ->
          nil
      end
    end

    @doc "The issue a quoted ref belongs to: its occurrence, or the issue by fingerprint prefix."
    def by_ref(ref) do
      ref = to_string(ref)

      case repo().query!("SELECT issue_id FROM blackbox_occurrences WHERE ref = $1 LIMIT 1", [ref]).rows do
        [[id]] ->
          id

        [] ->
          with [prefix | _] <- String.split(ref, "-"),
               true <- String.match?(prefix, ~r/^[0-9a-f]{6}$/),
               [[id]] <-
                 repo().query!(
                   "SELECT id FROM blackbox_issues WHERE fingerprint LIKE $1 LIMIT 1",
                   [prefix <> "%"]
                 ).rows do
            id
          else
            _ -> nil
          end
      end
    end

    ## Actions

    def resolve(id, build) do
      update(
        id,
        """
        UPDATE blackbox_issues SET state = 'resolved', resolved_at = now(),
          resolved_build = coalesce($2, last_build), resolved_builds = builds, muted_until = NULL, muted_count = NULL
        WHERE id = $1
        """,
        [build]
      )
    end

    def mute(id, until, more) do
      update(
        id,
        """
        UPDATE blackbox_issues SET state = 'muted', muted_until = $2,
          muted_count = CASE WHEN $3::bigint IS NULL THEN NULL ELSE count + $3::bigint END
        WHERE id = $1
        """,
        [until, more]
      )
    end

    def reopen(id),
      do:
        update(
          id,
          "UPDATE blackbox_issues SET state = 'open', muted_until = NULL, muted_count = NULL WHERE id = $1",
          []
        )

    def note(id, text),
      do:
        update(id, "UPDATE blackbox_issues SET note = $2 WHERE id = $1", [
          String.slice(text, 0, 4_000)
        ])

    defp update(id, sql, args) do
      with {id, ""} <- Integer.parse(to_string(id)),
           %{num_rows: 1} <- repo().query!(sql, [id | args]) do
        get(id)
      else
        _ -> nil
      end
    end

    defp rows(%{columns: cols, rows: rows}) do
      cols = Enum.map(cols, &String.to_atom/1)
      for row <- rows, do: cols |> Enum.zip(row) |> Map.new()
    end

    defp to_int(v, default) do
      case Integer.parse(to_string(v)) do
        {n, ""} when n > 0 -> n
        _ -> default
      end
    end
  end
end

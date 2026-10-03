if Code.ensure_loaded?(Ecto.Adapters.SQL) do
  defmodule Blackbox.Store do
    @moduledoc false
    # Attached in the host's tree, right after its Repo:
    #
    #     {Blackbox, repo: MyApp.Repo, build: "abc123", spool_dir: "/data/blackbox"}
    #
    # Starts its own one-connection pool of the host's Repo, so the tracker
    # never queues with a starving app (05-42), and becomes the buffer's
    # writer. It stops before the Repo (children stop in reverse order) and
    # flushes the buffer on the way out.
    use GenServer
    alias Blackbox.Buffer

    @flush_ms 4_000
    @prune_ms 600_000
    @keep_per_issue 100
    @keep_days 30
    @grouping_version 1

    def child_spec(opts) do
      %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, shutdown: @flush_ms + 1_000}
    end

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(opts) do
      Logger.metadata(blackbox: true)
      Process.flag(:trap_exit, true)
      repo = Keyword.fetch!(opts, :repo)
      build = to_string(Keyword.get(opts, :build) || "unknown")
      if dir = opts[:spool_dir], do: Application.put_env(:blackbox, :spool_dir, dir)
      # The page and the API read through the host's Repo.
      Application.put_env(:blackbox, :repo, repo)

      {:ok, pool} = repo.start_link(name: nil, pool_size: 1, log: false)
      query = (repo.config()[:telemetry_prefix] || []) ++ [:query]
      Blackbox.Capture.attach_query(query)
      Buffer.import_spool()
      Buffer.set_writer(writer(repo, pool, build))
      Process.send_after(self(), :prune, @prune_ms)
      {:ok, %{repo: repo, pool: pool, query: query}}
    end

    @impl true
    def handle_info(:prune, s) do
      Process.send_after(self(), :prune, @prune_ms)

      Task.Supervisor.start_child(Blackbox.TaskSup, fn ->
        Logger.metadata(blackbox: true)
        s.repo.put_dynamic_repo(s.pool)

        s.repo.query(
          "DELETE FROM blackbox_occurrences WHERE at < now() - make_interval(days => $1)",
          [@keep_days]
        )
      end)

      {:noreply, s}
    end

    def handle_info({:EXIT, pool, reason}, %{pool: pool} = s), do: {:stop, reason, s}
    def handle_info(_, s), do: {:noreply, s}

    @impl true
    def terminate(_, s) do
      Blackbox.Capture.detach_query(s.query)
      Buffer.drain(@flush_ms)
      Buffer.set_writer(nil)
      Process.exit(s.pool, :shutdown)
    end

    def writer(repo, pool, build) do
      fn batch ->
        repo.put_dynamic_repo(pool)
        write(repo, batch, build)
      end
    end

    # One transaction: upsert the issues, insert their samples, keep the
    # last 100 per issue. Sorted, so two nodes lock rows in the same order.
    def write(repo, batch, build) do
      batch = Enum.sort_by(batch, & &1.fingerprint)
      col = fn key -> Enum.map(batch, key) end
      at = &DateTime.from_unix!(&1, :microsecond)

      repo.transaction(fn ->
        %{rows: ids} =
          repo.query!(
            """
            INSERT INTO blackbox_issues AS i
              (fingerprint, kind, type, title, count, first_seen, last_seen, first_build, last_build, builds, grouping_version)
            SELECT f, k, t, ti, c, fs, ls, $8, $8, ARRAY[$8], #{@grouping_version}
            FROM unnest($1::text[], $2::text[], $3::text[], $4::text[], $5::bigint[], $6::timestamptz[], $7::timestamptz[])
              AS u(f, k, t, ti, c, fs, ls)
            ON CONFLICT (fingerprint) DO UPDATE SET
              count = i.count + EXCLUDED.count,
              last_seen = GREATEST(i.last_seen, EXCLUDED.last_seen),
              last_build = EXCLUDED.last_build,
              builds = CASE WHEN EXCLUDED.last_build = ANY(i.builds) THEN i.builds
                            ELSE i.builds || EXCLUDED.last_build END
            RETURNING fingerprint, id
            """,
            [
              col.(& &1.fingerprint),
              col.(&kind/1),
              col.(& &1.type),
              col.(& &1.title),
              col.(& &1.count),
              col.(&at.(&1.first_at)),
              col.(&at.(&1.last_at)),
              build
            ]
          )

        id_of = Map.new(ids, fn [f, id] -> {f, id} end)
        occ = for i <- batch, s <- i.samples, do: {id_of[i.fingerprint], i.fingerprint, s}

        if occ != [] do
          o = fn fun -> Enum.map(occ, fun) end

          repo.query!(
            """
            INSERT INTO blackbox_occurrences (issue_id, fingerprint, kind, type, message, source, build, node, at, payload, ref)
            SELECT id, f, k, t, m, src, $7, $8, a, p::jsonb, r
            FROM unnest($1::bigint[], $2::text[], $3::text[], $4::text[], $5::text[], $6::text[], $9::timestamptz[], $10::text[], $11::text[])
              AS u(id, f, k, t, m, src, a, p, r)
            """,
            [
              o.(&elem(&1, 0)),
              o.(&elem(&1, 1)),
              o.(&to_string(elem(&1, 2).kind)),
              o.(&elem(&1, 2).type),
              o.(&String.slice(elem(&1, 2).message || "", 0, 1024)),
              o.(&elem(&1, 2).source),
              build,
              to_string(node()),
              o.(&at.(elem(&1, 2).at)),
              o.(&JSON.encode!(elem(&1, 2))),
              o.(&Map.get(elem(&1, 2), :ref))
            ]
          )

          repo.query!(
            """
            DELETE FROM blackbox_occurrences o
            WHERE o.issue_id = ANY($1) AND o.id < (
              SELECT id FROM blackbox_occurrences x WHERE x.issue_id = o.issue_id
              ORDER BY id DESC OFFSET $2 LIMIT 1)
            """,
            [Map.values(id_of), @keep_per_issue - 1]
          )
        end
      end)

      :ok
    rescue
      e -> {:error, e}
    catch
      :exit, r -> {:error, r}
    end

    defp kind(%{samples: [s | _]}), do: to_string(s.kind)
    defp kind(%{type: "log"}), do: "log"
    defp kind(%{type: "throw"}), do: "throw"
    defp kind(%{type: "exit" <> _}), do: "exit"
    defp kind(_), do: "error"
  end
end

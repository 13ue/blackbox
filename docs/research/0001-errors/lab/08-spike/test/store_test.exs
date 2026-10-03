defmodule Spike.StoreTest do
  use ExUnit.Case, async: false
  alias Spike.{Repo, Store}

  setup do
    Repo.query!("TRUNCATE occurrences, issues RESTART IDENTITY")
    :ok
  end

  defp issue(fp, count, n_samples) do
    %{fingerprint: fp, type: "RuntimeError", count: count, first_at: 1, last_at: 2,
      samples: for(i <- 1..n_samples, do: %{kind: :error, message: "m#{i}", stacktrace: ["a.ex:1"], crumbs: []})}
  end

  test "08-24: upsert by fingerprint: counts add up, one issue row per fingerprint, samples become occurrences" do
    batch = [issue("a", 500, 3), issue("b", 300, 3), issue("c", 200, 3)]
    :ok = Store.write(Repo, batch)
    :ok = Store.write(Repo, batch)
    assert Repo.query!("select fingerprint, count from issues order by fingerprint").rows ==
             [["a", 1000], ["b", 600], ["c", 400]]
    assert Repo.query!("select count(*) from occurrences").rows == [[18]]
  end

  test "08-25: 8 concurrent writers upserting the same fingerprint keep an exact count" do
    1..8
    |> Task.async_stream(fn _ -> for _ <- 1..25, do: :ok = Store.write(Repo, [issue("hot", 1, 1)]) end, max_concurrency: 8)
    |> Stream.run()
    assert Repo.query!("select count from issues where fingerprint = 'hot'").rows == [[200]]
  end

  test "08-26: the DB being down is an error return, not a crash, and takes under 2 s" do
    start_supervised!(Spike.DownRepo)
    {us, res} = :timer.tc(fn -> Store.write(Spike.DownRepo, [issue("x", 1, 1)]) end)
    assert {:error, _} = res
    assert us < 2_000_000
  end
end

defmodule Blackbox.DB do
  @moduledoc "Test helpers over the store's tables."
  alias Blackbox.TestRepo, as: Repo

  def reset, do: Repo.query!("TRUNCATE blackbox_occurrences, blackbox_issues RESTART IDENTITY")
  def one(sql, args \\ []), do: Repo.query!(sql, args).rows |> hd() |> hd()
  def rows(sql, args \\ []), do: Repo.query!(sql, args).rows
  def total, do: one("SELECT coalesce(sum(count), 0)::bigint FROM blackbox_issues")
end

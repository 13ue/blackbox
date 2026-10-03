defmodule Blackbox.TestRepo do
  use Ecto.Repo, otp_app: :blackbox, adapter: Ecto.Adapters.Postgres
end

# A repo pointed at a port where nothing listens: "the database is down".
defmodule Blackbox.DownRepo do
  use Ecto.Repo, otp_app: :blackbox, adapter: Ecto.Adapters.Postgres
end

defmodule Blackbox.TestRepo.Migration do
  use Ecto.Migration
  def up, do: Blackbox.Migration.up(version: 1)
  def down, do: Blackbox.Migration.down(version: 1)
end

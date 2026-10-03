defmodule Lab05.Repo do
  use Ecto.Repo, otp_app: :lab05, adapter: Ecto.Adapters.Postgres
end

defmodule Lab05.Thing do
  use Ecto.Schema
  schema "things" do
    field :name, :string
  end
end

defmodule Lab05.Repo.Migrations.Init do
  use Ecto.Migration
  def up do
    Oban.Migration.up()
    create table(:things) do
      add :name, :string, null: false
    end
    create unique_index(:things, [:name])
  end
  def down, do: Oban.Migration.down(version: 1)
end

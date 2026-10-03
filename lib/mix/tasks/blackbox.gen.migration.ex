defmodule Mix.Tasks.Blackbox.Gen.Migration do
  @shortdoc "Writes the migration that creates Blackbox's tables"
  @moduledoc """
  Writes `priv/repo/migrations/<timestamp>_add_blackbox.exs` (or the
  directory given with `--migrations-path`), calling `Blackbox.Migration`.

      mix blackbox.gen.migration
  """
  use Mix.Task

  @impl true
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [migrations_path: :string])
    dir = opts[:migrations_path] || "priv/repo/migrations"
    app = Mix.Project.config()[:app] |> to_string() |> Macro.camelize()
    {{y, m, d}, {hh, mm, ss}} = :calendar.universal_time()
    stamp = :io_lib.format(~c"~4..0B~2..0B~2..0B~2..0B~2..0B~2..0B", [y, m, d, hh, mm, ss])
    path = Path.join(dir, "#{stamp}_add_blackbox.exs")

    File.mkdir_p!(dir)

    File.write!(path, """
    defmodule #{app}.Repo.Migrations.AddBlackbox do
      use Ecto.Migration

      def up, do: Blackbox.Migration.up(version: 1)
      def down, do: Blackbox.Migration.down(version: 1)
    end
    """)

    Mix.shell().info("* creating #{path}")
    path
  end
end

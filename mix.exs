defmodule Blackbox.MixProject do
  use Mix.Project

  @source_url "https://github.com/13ue/blackbox"

  def project do
    [
      app: :blackbox,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      description:
        "A flight recorder for the BEAM: every failure it can see, and what came before it.",
      package: [
        licenses: ["MIT"],
        links: %{"GitHub" => @source_url},
        files: ~w(lib mix.exs README.md LICENSE CHANGELOG.md)
      ],
      source_url: @source_url,
      docs: [main: "readme", extras: ["README.md", "CHANGELOG.md"]]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Blackbox.Application, []}
    ]
  end

  def cli, do: [preferred_envs: [ci: :test]]

  # What CI runs, before a push: `mix ci` here, `bin/ci` for both toolchains.
  defp aliases do
    [
      ci: [
        "format --check-formatted",
        "compile --warnings-as-errors --force",
        &compile_without_optional_deps/1,
        &no_host_names/1,
        "test"
      ]
    ]
  end

  # As a host without ecto_sql, postgrex and plug compiles it (`mix cmd`
  # differs between Elixir 1.18 and 1.20, so this calls mix directly).
  defp compile_without_optional_deps(_) do
    args = ~w(compile --no-optional-deps --warnings-as-errors --force)
    {_, status} = System.cmd("mix", args, env: [{"MIX_ENV", "prod"}], into: IO.stream())
    if status != 0, do: Mix.raise("lib does not compile without the optional deps")
  end

  defp no_host_names(_) do
    hits = for f <- Path.wildcard("lib/**/*.ex"), File.read!(f) =~ ~r/Charta|Hologram/, do: f
    if hits != [], do: Mix.raise("lib names its first host: #{Enum.join(hits, ", ")}")
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:telemetry, "~> 1.0"},
      # the Postgres store
      {:ecto_sql, "~> 3.10", optional: true},
      {:postgrex, "~> 0.17", optional: true},
      # the page and the API
      {:plug, "~> 1.14", optional: true},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end
end

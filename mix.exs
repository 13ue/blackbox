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

defmodule Blackbox.MixProject do
  use Mix.Project

  def project do
    [
      app: :blackbox,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "A flight recorder for the BEAM: every failure it can see, and what came before it.",
      package: [
        licenses: ["MIT"],
        links: %{"GitHub" => "https://github.com/13ue/blackbox"},
        files: ~w(lib mix.exs README.md LICENSE)
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Blackbox.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:telemetry, "~> 1.0"},
      # the Postgres store
      {:ecto_sql, "~> 3.10", optional: true},
      {:postgrex, "~> 0.17", optional: true},
      # the page and the API
      {:plug, "~> 1.14", optional: true}
    ]
  end
end

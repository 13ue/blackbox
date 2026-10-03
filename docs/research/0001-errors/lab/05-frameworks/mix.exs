defmodule Lab05.MixProject do
  use Mix.Project

  def project do
    [app: :lab05, version: "0.1.0", elixir: "~> 1.18", start_permanent: false, elixirc_paths: elixirc_paths(Mix.env()), deps: deps()]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application, do: [extra_applications: [:logger, :inets]]

  defp deps do
    [
      {:phoenix, "~> 1.8"},
      {:phoenix_live_view, "~> 1.1"},
      {:bandit, "~> 1.6"},
      {:plug_cowboy, "~> 2.7"},
      {:ecto_sql, "~> 3.12"},
      {:postgrex, ">= 0.0.0"},
      {:oban, "~> 2.19"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end
end

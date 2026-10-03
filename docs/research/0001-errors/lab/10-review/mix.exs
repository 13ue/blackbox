defmodule Spike.MixProject do
  use Mix.Project

  def project do
    [app: :spike, version: "0.1.0", elixir: "~> 1.20", deps: deps(),
     elixirc_paths: if(Mix.env() == :test, do: ["lib", "test/support"], else: ["lib"])]
  end

  def application, do: [extra_applications: [:logger], mod: {Spike.Application, []}]

  defp deps do
    [{:ecto_sql, "~> 3.12"}, {:postgrex, ">= 0.0.0"}, {:telemetry, "~> 1.2"},
     {:jason, "~> 1.4"}, {:benchee, "~> 1.3", only: :test}]
  end
end

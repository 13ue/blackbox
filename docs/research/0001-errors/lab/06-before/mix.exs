defmodule BeforeLab.MixProject do
  use Mix.Project

  def project do
    [app: :before_lab, version: "0.1.0", elixir: "~> 1.18", start_permanent: false, deps: deps()]
  end

  def application, do: [extra_applications: [:logger, :runtime_tools]]

  defp deps do
    [
      {:benchee, "~> 1.3"},
      {:telemetry, "~> 1.3"},
      {:plug, "~> 1.16"},
      {:bandit, "~> 1.6"},
      {:req, "~> 0.5"},
      {:opentelemetry_api, "~> 1.4"}
    ]
  end
end

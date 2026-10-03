defmodule Lab01.MixProject do
  use Mix.Project

  def project do
    [app: :lab01, version: "0.1.0", elixir: "~> 1.18", start_permanent: false, deps: deps()]
  end

  def application, do: [extra_applications: [:logger]]

  defp deps do
    [
      {:sentry, "13.5.1"},
      {:bandit, "~> 1.12"},
      {:plug, "~> 1.18"},
      {:req, "~> 0.5"}
    ]
  end
end

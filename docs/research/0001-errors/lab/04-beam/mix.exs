defmodule BeamLab.MixProject do
  use Mix.Project

  def project do
    [app: :beam_lab, version: "0.1.0", elixir: "~> 1.20", start_permanent: false,
     elixirc_paths: if(Mix.env() == :test, do: ["lib", "test/support"], else: ["lib"]),
     deps: [{:telemetry, "~> 1.3"}]]
  end

  def application, do: [extra_applications: [:logger]]
end

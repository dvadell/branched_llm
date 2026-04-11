defmodule BranchedLlm.MixProject do
  use Mix.Project

  def project do
    [
      app: :branched_llm,
      version: "0.1.0",
      elixir: "~> 1.19",
      aliases: aliases(),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:req_llm, "~> 1.0.0"},
      {:jason, "~> 1.2"},
      {:retry, "~> 0.18"},
      # For UUID generation
      {:ecto, "~> 3.10"},
      {:telemetry, "~> 1.0"},
      {:mox, "~> 1.0", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "credo --strict",
        ~s(cmd sh -c "MIX_ENV=test mix dialyzer"),
        ~s(cmd sh -c "MIX_ENV=test mix test --cover")
      ]
    ]
  end
end

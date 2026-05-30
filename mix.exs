defmodule BranchedLLM.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/dvadell/branched_llm"

  def project do
    [
      app: :branched_llm,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      aliases: aliases(),
      package: package(),
      description: "A branched conversation library for LLM interactions with tool support",
      test_coverage: test_coverage(),
      dialyzer: [plt_add_deps: :app_tree, plt_add_apps: [:llm_db]]
    ]
  end

  defp test_coverage do
    [
      summary: [threshold: 90],
      ignore_modules: [
        BranchedLLM.Chat,
        BranchedLLM.ToolCache
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:req_llm, "~> 1.13.0"},
      {:ecto, "~> 3.13", optional: true},
      {:jason, "~> 1.2"},
      {:ex_json_schema, "~> 0.10"},
      {:retry, "~> 0.18"},
      {:telemetry, "~> 1.0"},
      {:opentelemetry_api, "~> 1.0", optional: true},
      {:opentelemetry_req, "~> 0.2", optional: true},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:mox, "~> 1.0", only: :test},
      {:ex_slop, "~> 0.1", only: [:dev, :test], runtime: false},
      {:credo_contrib, "~> 0.2.0", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      name: "branched_llm",
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib .formatter.exs mix.exs README* LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      extras: [
        "README.md",
        "guides/getting_started.md",
        "guides/tutorial_iex.md"
      ],
      groups_for_extras: [
        Guides: Path.wildcard("guides/*.md")
      ],
      nest_modules_by_prefix: [BranchedLLM.LLM]
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

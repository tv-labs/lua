defmodule Lua.MixProject do
  use Mix.Project

  @url "https://github.com/tv-labs/lua"
  @version "0.4.0"

  def project do
    [
      app: :lua,
      version: @version,
      elixir: "~> 1.16",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),

      # Dialyzer
      dialyzer: [
        plt_add_apps: [:ex_unit, :mix]
      ],

      # Docs
      name: "Lua",
      description: "A Lua VM implementation in Elixir",
      source_url: @url,
      homepage_url: @url,
      package: package(),
      docs: [
        # The main page in the docs
        main: "Lua",
        source_url: @url,
        source_ref: "v#{@version}",
        extras: ["CHANGELOG.md", "guides/working-with-lua.livemd"]
      ]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: elixirc_paths(:dev) ++ ["test/support"]
  defp elixirc_paths(:dev), do: ["lib", "tasks"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      maintainers: ["davydog187"],
      files: ["lib", "mix.exs", "README.md", "LICENSE"],
      links: %{
        "GitHub" => @url
      }
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:usage_rules, "~> 0.1", only: [:dev]},
      {:ex_doc, "~> 0.38", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.1", only: [:test]},
      {:styler, "~> 1.10", only: [:dev, :test], runtime: false}
    ]
  end
end

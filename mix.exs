defmodule Lua.MixProject do
  use Mix.Project

  alias Lua.Parser.Error
  alias Mix.Tasks.Lua.Eval

  @url "https://github.com/tv-labs/lua"
  @version "1.0.0-rc.3"

  # The curated public API surface rendered on HexDocs. Everything else is an
  # implementation detail: its @moduledoc stays intact for source readers and
  # `h Mod` in IEx, but `filter_modules/2` keeps it out of the published sidebar.
  @public_modules [
    Lua,
    Lua.API,
    Lua.Table,
    Lua.Chunk,
    Lua.RuntimeException,
    Lua.CompilerException,
    Error,
    Eval
  ]

  def project do
    [
      app: :lua,
      version: @version,
      elixir: "~> 1.16",
      elixirc_paths: elixirc_paths(Mix.env()),
      # test/lua53_skips.exs is suite config data (loaded via Code.eval_file),
      # not a test file — tell the loader to ignore it instead of warning.
      test_ignore_filters: [&String.ends_with?(&1, "_skips.exs")],
      start_permanent: Mix.env() == :prod,
      deps: deps(),

      # Dialyzer
      dialyzer: [
        plt_add_apps: [:ex_unit, :mix],
        plt_core_path: "priv/plts/core",
        plt_local_path: "priv/plts/local"
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
        logo: "priv/logo.svg",
        source_url: @url,
        source_ref: "v#{@version}",
        # Render only the curated public surface; keep internals in source/IEx.
        filter_modules: fn module, _meta -> module in @public_modules end,
        # Docs (CHANGELOG, moduledocs) name internal plumbing that stays
        # filtered — the VM exception structs behind `Lua.RuntimeException` and
        # their helpers. Render those references as plain code instead of
        # autolinking to filtered pages, which errors under
        # `--warnings-as-errors`.
        skip_code_autolink_to: [
          "Lua.VM.Executor.current_position/0",
          "Lua.VM.ErrorFormatter.to_map/3",
          "Lua.VM.RuntimeError",
          "Lua.VM.TypeError",
          "Lua.VM.ArgumentError",
          "Lua.VM.AssertionError",
          "Lua.VM.InternalError"
        ],
        groups_for_modules: [
          Core: [Lua, Lua.API, Lua.Table, Lua.Chunk],
          Errors: [
            Lua.RuntimeException,
            Lua.CompilerException,
            Error
          ],
          "Mix Tasks": [Eval]
        ],
        extras: [
          "guides/working-with-lua.livemd": [title: "Working with Lua"],
          "guides/sandboxing.md": [title: "Security & Sandboxing"],
          "guides/mix_tasks.md": [title: "Mix Tasks & the ~LUA sigil"],
          "guides/examples/quickstart.livemd": [title: "Quickstart"],
          "guides/examples/userdata.livemd": [title: "Userdata"],
          "guides/examples/custom_stdlib.livemd": [title: "Custom stdlib"],
          "guides/examples/sandboxing.livemd": [title: "Sandboxing"],
          "guides/examples/chunks.livemd": [title: "Chunks"],
          "guides/examples/error_handling.livemd": [title: "Error handling"],
          "CHANGELOG.md": []
        ],
        groups_for_extras: [
          Guides: [
            "guides/working-with-lua.livemd",
            "guides/sandboxing.md",
            "guides/mix_tasks.md"
          ],
          Examples: ~r{guides/examples/}
        ]
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
      {:tidewave, "~> 0.5", only: [:dev]},
      {:usage_rules, "~> 0.1", only: [:dev]},
      {:ex_doc, "~> 0.38", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.1", only: [:test]},
      {:styler, "~> 1.10", only: [:dev, :test], runtime: false},
      {:benchee, "~> 1.3", only: :benchmark},
      {:luerl, "~> 1.5", only: :benchmark}
    ]
  end
end

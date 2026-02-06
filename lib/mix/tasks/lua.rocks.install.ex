defmodule Mix.Tasks.Lua.Rocks.Install do
  @shortdoc "Installs Lua dependencies from a rockspec file via LuaRocks"
  @moduledoc """
  Installs Lua dependencies specified in a rockspec file.

  The `luarocks` CLI must be installed and available on your PATH.

  ## Usage

      $ mix lua.rocks.install [options]

  ## Options

    * `--rockspec` - Path to the rockspec file (default: auto-detected from project root)
    * `--tree` - Directory for vendored packages (default: `priv/lua_deps/`)

  ## Examples

      # Install from auto-detected rockspec
      $ mix lua.rocks.install

      # Install from a specific rockspec with a custom tree
      $ mix lua.rocks.install --rockspec deps.rockspec --tree vendor/lua
  """
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [rockspec: :string, tree: :string]
      )

    case Lua.Rocks.check_luarocks() do
      {:ok, version} ->
        Mix.shell().info("Using #{version}")

      {:error, :not_found} ->
        Mix.raise("""
        luarocks CLI not found on PATH.

        Install it from https://luarocks.org or via your package manager:

            brew install luarocks    # macOS
            apt install luarocks     # Debian/Ubuntu
        """)
    end

    tree = Keyword.get(opts, :tree, Lua.Rocks.default_tree())

    rockspec_path =
      case Keyword.get(opts, :rockspec) do
        nil ->
          case Lua.Rocks.find_rockspec() do
            {:ok, path} ->
              path

            {:error, :not_found} ->
              Mix.raise(
                "No .rockspec file found in project root. Create one or specify --rockspec path"
              )
          end

        path ->
          path
      end

    Mix.shell().info("Reading #{rockspec_path}...")

    case Lua.Rocks.parse_rockspec(rockspec_path) do
      {:ok, []} ->
        Mix.shell().info("No dependencies found in rockspec.")

      {:ok, deps} ->
        install_dependencies(deps, tree)

      {:error, reason} ->
        Mix.raise("Failed to parse rockspec: #{reason}")
    end
  end

  defp install_dependencies(deps, tree) do
    Mix.shell().info("Installing #{length(deps)} Lua package(s) to #{tree}/...\n")

    results =
      Enum.map(deps, fn {name, constraint} ->
        label = if constraint != "", do: "#{name} (#{constraint})", else: name
        Mix.shell().info("  * #{label}")

        case Lua.Rocks.install(name, tree: tree) do
          :ok ->
            {:ok, name}

          {:error, reason} ->
            Mix.shell().error("    Failed: #{reason}")
            {:error, name, reason}
        end
      end)

    errors = for {:error, name, reason} <- results, do: {name, reason}
    successful = for {:ok, name} <- results, do: name

    if errors != [] do
      Mix.shell().error("\nFailed to install #{length(errors)} package(s):")

      for {name, reason} <- errors do
        Mix.shell().error("  * #{name}: #{reason}")
      end
    end

    case Lua.Rocks.validate_tree(tree: tree) do
      :ok ->
        :ok

      {:warning, paths} ->
        Mix.shell().info("")
        Mix.shell().info("WARNING: C extensions detected!")
        Mix.shell().info("The following files will NOT work with Luerl:")

        for path <- paths do
          Mix.shell().info("  #{path}")
        end

        Mix.shell().info("\nOnly pure Lua packages are compatible with Luerl.")
    end

    Mix.shell().info("\nInstalled #{length(successful)} package(s) to #{tree}/")
  end
end

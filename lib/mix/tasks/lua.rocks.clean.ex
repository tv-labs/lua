defmodule Mix.Tasks.Lua.Rocks.Clean do
  @shortdoc "Removes the vendored Lua dependencies directory"
  @moduledoc """
  Removes the vendored Lua dependencies directory.

  ## Usage

      $ mix lua.rocks.clean [options]

  ## Options

    * `--tree` - Directory to clean (default: `priv/lua_deps/`)
  """
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [tree: :string])
    tree = Keyword.get(opts, :tree, Lua.Rocks.default_tree())

    if File.dir?(tree) do
      Lua.Rocks.clean(tree: tree)
      Mix.shell().info("Removed #{tree}/")
    else
      Mix.shell().info("Nothing to clean (#{tree}/ does not exist)")
    end
  end
end

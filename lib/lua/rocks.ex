defmodule Lua.Rocks do
  @moduledoc """
  Manages Lua dependencies via LuaRocks.

  Provides functions for parsing rockspec files, installing pure-Lua
  packages from LuaRocks, and configuring the Lua VM to find vendored modules.

  ## Prerequisites

  The `luarocks` CLI must be installed and available on your PATH.

  ## Usage

  Specify dependencies in a `.rockspec` file at your project root:

      -- myapp-dev-1.rockspec
      package = "myapp"
      version = "dev-1"
      source = { url = "." }
      dependencies = {
        "lua >= 5.1",
        "inspect >= 3.0",
      }

  Then install them:

      $ mix lua.rocks.install

  And use them in your Lua VM:

      lua =
        Lua.new(exclude: [[:package], [:require]])
        |> Lua.with_rocks()

      {[result], _lua} = Lua.eval!(lua, "local inspect = require('inspect'); return inspect({1,2,3})")
  """

  @default_tree "priv/lua_deps"

  @doc """
  Returns the default vendor tree path.
  """
  def default_tree, do: @default_tree

  @doc """
  Checks that the `luarocks` CLI is available on the system PATH.

  Returns `{:ok, version_string}` or `{:error, :not_found}`.
  """
  def check_luarocks do
    case System.cmd("luarocks", ["--version"], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output |> String.split("\n") |> hd() |> String.trim()}
      _ -> {:error, :not_found}
    end
  rescue
    ErlangError -> {:error, :not_found}
  end

  @doc """
  Finds a rockspec file in the given directory.

  Returns `{:ok, path}` or `{:error, :not_found}`.
  """
  def find_rockspec(dir \\ ".") do
    case Path.wildcard(Path.join(dir, "*.rockspec")) do
      [path | _] -> {:ok, path}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Parses a rockspec file and extracts the `dependencies` list.

  Uses Luerl to evaluate the rockspec (which is valid Lua), then extracts
  the `dependencies` table. The `"lua >= X.Y"` entry is filtered out since
  it refers to the Lua runtime itself, not a package.

  Returns `{:ok, deps}` where deps is a list of `{name, constraint}` tuples,
  or `{:error, reason}`.

  ## Examples

      iex> Lua.Rocks.parse_rockspec("myapp.rockspec")
      {:ok, [{"inspect", ">= 3.0"}, {"middleclass", ">= 3.0"}]}
  """
  def parse_rockspec(path) do
    with {:ok, contents} <- File.read(path) do
      lua = Lua.new(sandboxed: [])
      {_, lua} = Lua.eval!(lua, contents)

      case Lua.get!(lua, [:dependencies]) do
        nil ->
          {:ok, []}

        deps when is_list(deps) ->
          parsed =
            deps
            |> Lua.Table.as_list(sort: true)
            |> Enum.map(&parse_dep_string/1)
            |> Enum.reject(fn {name, _} -> name == "lua" end)

          {:ok, parsed}
      end
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp parse_dep_string(str) when is_binary(str) do
    case String.split(str, " ", parts: 2) do
      [name, constraint] -> {String.trim(name), String.trim(constraint)}
      [name] -> {String.trim(name), ""}
    end
  end

  @doc """
  Installs a single LuaRocks package into the given tree directory.

  ## Options

    * `:tree` - installation directory (default: `"priv/lua_deps"`)
    * `:version` - exact version string, e.g. `"3.1.3"` (optional)

  Returns `:ok` or `{:error, reason}`.
  """
  def install(package, opts \\ []) do
    tree = Keyword.get(opts, :tree, @default_tree)
    version = Keyword.get(opts, :version)

    args =
      ["install", "--tree", tree, package] ++
        if(version, do: [version], else: [])

    case System.cmd("luarocks", args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, _} -> {:error, String.trim(output)}
    end
  end

  @doc """
  Installs all dependencies from a rockspec file.

  ## Options

    * `:tree` - installation directory (default: `"priv/lua_deps"`)
    * `:rockspec` - path to rockspec file (default: auto-detected from project root)

  Returns `{:ok, results}` or `{:error, reason}` where results is a list of
  `{:ok, name}` or `{:error, name, reason}` tuples.
  """
  def install_deps(opts \\ []) do
    tree = Keyword.get(opts, :tree, @default_tree)

    rockspec_path =
      case Keyword.get(opts, :rockspec) do
        nil ->
          case find_rockspec() do
            {:ok, path} -> path
            {:error, :not_found} -> raise "No .rockspec file found in project root"
          end

        path ->
          path
      end

    case parse_rockspec(rockspec_path) do
      {:ok, deps} ->
        results =
          Enum.map(deps, fn {name, _constraint} ->
            case install(name, tree: tree) do
              :ok -> {:ok, name}
              {:error, reason} -> {:error, name, reason}
            end
          end)

        case validate_tree(tree: tree) do
          :ok -> :ok
          {:warning, paths} -> {:warning, paths}
        end

        {:ok, results}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Removes the vendored tree directory entirely.
  """
  def clean(opts \\ []) do
    tree = Keyword.get(opts, :tree, @default_tree)
    File.rm_rf!(tree)
    :ok
  end

  @doc """
  Returns the `package.path` patterns for the vendored tree.

  These patterns are suitable for passing to `Lua.set_lua_paths/2`.

  The Lua version subdirectory is auto-detected by scanning the tree.
  If no tree exists yet, defaults to `5.3` (Luerl's Lua version).

  ## Options

    * `:tree` - path to the vendored tree (default: `"priv/lua_deps"`)
    * `:root` - project root directory (default: `File.cwd!()`)
  """
  def lua_paths(opts \\ []) do
    tree = Keyword.get(opts, :tree, @default_tree)
    root = Keyword.get(opts, :root, File.cwd!())
    base = Path.join(root, tree)

    lua_version = detect_lua_version(base)

    [
      Path.join([base, "share", "lua", lua_version, "?.lua"]),
      Path.join([base, "share", "lua", lua_version, "?", "init.lua"])
    ]
  end

  defp detect_lua_version(base) do
    share_lua = Path.join([base, "share", "lua"])

    case File.ls(share_lua) do
      {:ok, [version | _]} -> version
      _ -> "5.3"
    end
  end

  @doc """
  Scans the vendored tree for C extensions (`.so`, `.dll`, `.dylib` files)
  and returns a list of paths to any found.
  """
  def detect_c_extensions(opts \\ []) do
    tree = Keyword.get(opts, :tree, @default_tree)
    lib_dir = Path.join(tree, "lib")

    if File.dir?(lib_dir) do
      Path.wildcard(Path.join(lib_dir, "**/*.{so,dll,dylib}"))
    else
      []
    end
  end

  @doc """
  Validates the vendored tree has no C extensions.

  Returns `:ok` or `{:warning, paths}` with the list of C extension file paths.
  """
  def validate_tree(opts \\ []) do
    case detect_c_extensions(opts) do
      [] -> :ok
      paths -> {:warning, paths}
    end
  end
end

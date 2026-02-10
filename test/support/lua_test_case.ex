defmodule Lua.TestCase do
  @moduledoc """
  Test support for running Lua 5.3 test suite files.

  Provides helpers for running .lua test files and treating Lua assert()
  failures as ExUnit failures.
  """

  use ExUnit.CaseTemplate

  @doc """
  Runs a .lua file, treating Lua assert() failures as ExUnit failures.

  ## Options

  * `:sandbox` - Whether to run in sandbox mode (default: true)
  * `:path` - Additional paths to add to package.path
  """
  def run_lua_file(path, opts \\ []) do
    source = File.read!(path)
    # Exclude package and require from sandbox so tests can use them
    lua = Lua.new(exclude: [[:package], [:require]])

    # Add the test directory to package.path so require() can find test modules
    test_dir = Path.dirname(path)
    lua = add_test_paths(lua, test_dir)

    # Install test helpers
    lua = install_test_helpers(lua)

    # Execute the test file
    {_results, _lua} = Lua.eval!(lua, source)
    :ok
  end

  # Add test directory to package.path
  defp add_test_paths(lua, test_dir) do
    # Add both the test directory and libs subdirectory to package.path
    path_templates = [
      Path.join(test_dir, "?.lua"),
      Path.join([test_dir, "libs", "?.lua"])
    ]

    Lua.set_lua_paths(lua, path_templates)
  end

  # Install test helpers
  defp install_test_helpers(lua) do
    # Override print to capture output (for now, just use standard print)
    # In the future, we could capture this to test output

    # Add dostring helper (loads and executes Lua code)
    lua = Lua.set!(lua, ["dostring"], fn [code], state ->
      case Lua.Parser.parse(code) do
        {:ok, ast} ->
          case Lua.Compiler.compile(ast, source: "<dostring>") do
            {:ok, proto} ->
              case Lua.VM.execute(proto, state) do
                {:ok, results, state} -> {results, state}
                {:error, error} -> raise Lua.VM.RuntimeError, value: "dostring error: #{inspect(error)}"
              end
            {:error, error} ->
              raise Lua.VM.RuntimeError, value: "compile error: #{inspect(error)}"
          end
        {:error, error} ->
          raise Lua.VM.RuntimeError, value: "parse error: #{inspect(error)}"
      end
    end)

    # Add load function (returns a function that executes the code when called)
    lua = Lua.set!(lua, ["load"], fn args, state ->
      code = List.first(args)
      chunk_name = Enum.at(args, 1, "<load>")

      case Lua.Parser.parse(code) do
        {:ok, ast} ->
          case Lua.Compiler.compile(ast, source: chunk_name) do
            {:ok, proto} ->
              # Return a closure that will execute the proto when called
              closure = {:lua_closure, proto, []}
              {[closure], state}
            {:error, error} ->
              {[nil, "compile error: #{inspect(error)}"], state}
          end
        {:error, error} ->
          {[nil, "parse error: #{inspect(error)}"], state}
      end
    end)

    # Add checkerr helper (expects an error to be raised)
    lua = Lua.set!(lua, ["checkerr"], fn [pattern, func | _], state ->
      try do
        Lua.VM.Executor.call_function(func, [], state)
        raise Lua.VM.RuntimeError, value: "expected error matching '#{pattern}' but no error was raised"
      rescue
        e in [Lua.VM.RuntimeError, Lua.VM.TypeError, Lua.VM.AssertionError] ->
          error_msg = extract_error_message(e)
          if String.contains?(error_msg, pattern) do
            {[true], state}
          else
            raise Lua.VM.RuntimeError,
              value: "expected error matching '#{pattern}' but got: #{error_msg}"
          end
      end
    end)

    lua
  end

  # Extract error message from exception
  defp extract_error_message(%{value: value}) when is_binary(value), do: value
  defp extract_error_message(%{value: value}) when not is_nil(value), do: Lua.VM.Value.to_string(value)
  defp extract_error_message(e), do: Exception.message(e)
end

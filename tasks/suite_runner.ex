defmodule Lua.SuiteRunner do
  @moduledoc false

  # Runs Lua 5.3 official test suite files under a shared sandbox config.
  #
  # Internal helper used by `Mix.Tasks.Lua.Suite` and `Lua.TestCase`.
  # Lives in `tasks/` rather than `lib/` because both consumers are
  # contributor-only — this module is intentionally not part of the
  # public API and is not shipped to Hex.

  alias Lua.VM.RuntimeError, as: VMRuntimeError

  @doc """
  Prepare a `%Lua{}` configured the way every suite file expects:

    * `package` and `require` are unsandboxed (suite files `require`
      sibling test modules).
    * `package.path` includes `<test_dir>/?.lua` and `<test_dir>/libs/?.lua`.
    * `dostring`, `load`, and `checkerr` helpers are installed as
      global functions.

  `test_dir` is the directory containing the file being run; it is
  used only to populate `package.path`.
  """
  @spec prepare(Path.t()) :: Lua.t()
  def prepare(test_dir) do
    [exclude: [[:package], [:require]]]
    |> Lua.new()
    |> add_test_paths(test_dir)
    |> install_helpers()
  end

  @doc """
  Run a `.lua` file under the suite sandbox.

  Returns `:ok` on success, `{:error, exception}` if the file raises.
  No exceptions escape this function.

  Use `prepare/1` if you need to inspect or modify the VM before
  running.
  """
  @spec run_file(Path.t()) :: :ok | {:error, Exception.t()}
  def run_file(path) do
    source = File.read!(path)
    lua = prepare(Path.dirname(path))

    try do
      {_results, _lua} = Lua.eval!(lua, source, source: Path.basename(path))
      :ok
    rescue
      e -> {:error, e}
    end
  end

  defp add_test_paths(lua, test_dir) do
    Lua.set_lua_paths(lua, [
      Path.join(test_dir, "?.lua"),
      Path.join([test_dir, "libs", "?.lua"])
    ])
  end

  defp install_helpers(lua) do
    lua
    |> install_dostring()
    |> install_load()
    |> install_checkerr()
  end

  defp install_dostring(lua) do
    Lua.set!(lua, ["dostring"], fn [code], state ->
      case Lua.Parser.parse(code) do
        {:ok, ast} ->
          case Lua.Compiler.compile(ast, source: "<dostring>") do
            {:ok, proto} ->
              {:ok, results, state} = Lua.VM.execute(proto, state)
              {results, state}

            {:error, error} ->
              raise VMRuntimeError, value: "compile error: #{inspect(error)}"
          end

        {:error, error} ->
          raise VMRuntimeError, value: "parse error: #{inspect(error)}"
      end
    end)
  end

  defp install_load(lua) do
    Lua.set!(lua, ["load"], fn args, state ->
      code = List.first(args)
      chunk_name = Enum.at(args, 1, "<load>")

      case Lua.Parser.parse(code) do
        {:ok, ast} ->
          case Lua.Compiler.compile(ast, source: chunk_name) do
            {:ok, proto} ->
              closure = {:lua_closure, proto, {}}
              {[closure], state}

            {:error, error} ->
              {[nil, "compile error: #{inspect(error)}"], state}
          end

        {:error, error} ->
          {[nil, "parse error: #{inspect(error)}"], state}
      end
    end)
  end

  defp install_checkerr(lua) do
    Lua.set!(lua, ["checkerr"], fn [pattern, func | _], state ->
      try do
        Lua.VM.Executor.call_function(func, [], state)

        raise VMRuntimeError,
          value: "expected error matching '#{pattern}' but no error was raised"
      rescue
        e in [VMRuntimeError, Lua.VM.TypeError, Lua.VM.AssertionError] ->
          error_msg = extract_error_message(e)

          if String.contains?(error_msg, pattern) do
            {[true], state}
          else
            raise VMRuntimeError,
              value: "expected error matching '#{pattern}' but got: #{error_msg}"
          end
      end
    end)
  end

  defp extract_error_message(%{value: value}) when is_binary(value), do: value

  defp extract_error_message(%{value: value}) when not is_nil(value), do: Lua.VM.Value.to_string(value)

  defp extract_error_message(e), do: Exception.message(e)
end

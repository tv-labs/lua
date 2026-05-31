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

  ## Options

    * `:skip_ranges` — a list of `Range` values. Each line in any of
      the ranges is replaced with a one-line comment before the source
      is evaluated. Line numbers are preserved, so assertion errors
      still report the original source position.

  Use `prepare/1` if you need to inspect or modify the VM before
  running.
  """
  @spec run_file(Path.t(), keyword) :: :ok | {:error, Exception.t()}
  def run_file(path, opts \\ []) do
    source =
      path
      |> File.read!()
      |> apply_skip_ranges(Keyword.get(opts, :skip_ranges, []))

    lua = prepare(Path.dirname(path))

    try do
      {_results, _lua} = Lua.eval!(lua, source, source: Path.basename(path))
      :ok
    rescue
      e -> {:error, e}
    end
  end

  @doc """
  Load and validate the suite skip map from an `.exs` file.

  Raises if a file mixes `lines: :all` with specific ranges, since the
  test driver treats `:all` as a hard skip and silently drops any
  ranges alongside it.
  """
  @spec load_skip_map!(Path.t()) :: %{optional(String.t()) => [map()]}
  def load_skip_map!(path) do
    map = path |> Code.eval_file() |> elem(0)
    validate_skip_map!(map, path)
    map
  end

  defp validate_skip_map!(map, path) do
    Enum.each(map, fn {file, entries} ->
      has_all? = Enum.any?(entries, &(&1.lines == :all))
      has_range? = Enum.any?(entries, &(&1.lines != :all))

      if has_all? and has_range? do
        raise ArgumentError,
              "#{path}: #{file} mixes `lines: :all` with specific ranges. " <>
                "Use one or the other — `:all` skips the whole file, so any " <>
                "ranges alongside it would be silently ignored."
      end
    end)
  end

  @doc """
  Replace each line covered by `ranges` with a one-line `--` comment,
  preserving total line count. Used by `run_file/2` and the audit
  helpers in `Mix.Tasks.Lua.Suite`.
  """
  @spec apply_skip_ranges(String.t(), [Range.t()]) :: String.t()
  def apply_skip_ranges(source, []), do: source

  def apply_skip_ranges(source, ranges) do
    skip = ranges |> Enum.flat_map(&Enum.to_list/1) |> MapSet.new()

    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {line, n} ->
      if MapSet.member?(skip, n), do: "-- skipped (suite triage): was line #{n}", else: line
    end)
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
          proto = Lua.Compiler.compile!(ast, source: "<dostring>")
          {:ok, results, state} = Lua.VM.execute(proto, state)
          {results, state}

        {:error, error} ->
          raise VMRuntimeError, value: "parse error: #{inspect(error)}"
      end
    end)
  end

  defp install_load(lua) do
    Lua.set!(lua, ["load"], fn args, lua ->
      code = List.first(args)
      chunk_name = Enum.at(args, 1, "<load>")
      vm = lua.state

      # A loaded chunk's sole upvalue is `_ENV`. Back it with a real cell
      # holding the requested environment (the optional 4th arg, defaulting to
      # `_G`) so `debug.getupvalue`/`setupvalue` and custom-env writes work —
      # mirroring `Lua.VM.Stdlib.compile_loaded_chunk/3`.
      env =
        case Enum.at(args, 3) do
          nil -> Lua.VM.State.g_ref(vm)
          env -> env
        end

      case Lua.Parser.parse(code) do
        {:ok, ast} ->
          proto = Lua.Compiler.compile!(ast, source: chunk_name)
          env_cell = make_ref()
          vm = %{vm | upvalue_cells: Map.put(vm.upvalue_cells, env_cell, env)}
          closure = {:lua_closure, proto, {env_cell}}
          {[closure], %{lua | state: vm}}

        {:error, error} ->
          {[nil, "parse error: #{inspect(error)}"], lua}
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

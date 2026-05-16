defmodule Mix.Tasks.Lua.Suite do
  @shortdoc "Runs the Lua 5.3 official test suite"
  @moduledoc """
  Runs every `.lua` file in `test/lua53_tests/` against this VM and
  prints a pass/fail summary.

  Unlike `mix test --only lua53`, this task does not consult the
  hand-curated `@ready_tests` / `@deferred_permanent` lists in
  `test/lua53_suite_test.exs`. It runs every file and reports
  whatever happens, which makes it useful for spotting newly-passing
  files (candidates to promote) and for sanity-checking the suite
  set during development.

  ## Usage

      mix lua.suite
      mix lua.suite --filter math
      mix lua.suite --dir test/lua53_tests
      mix lua.suite --verbose

  ## Options

    * `--dir DIR` — Directory containing the suite `.lua` files
      (default: `test/lua53_tests`).
    * `--filter PATTERN` — Run only files whose basename contains
      `PATTERN` (case-sensitive substring).
    * `--timeout MS` — Per-file timeout in milliseconds. Files that
      exceed it are reported as `timeout` (default: `30000`).
    * `--verbose` — Print the full error message for each failing
      file, not just the first line.

  ## Output

  A summary like:

      passing: 6
      failing: 23
      skipped: 0

      passing files: api, bitwise, code, simple_test, tpack, vararg
      failing files (top reason):
        attrib.lua          'require' is sandboxed
        big.lua             attempt to compare a string with a number
        ...

  ## Exit codes

    * `0` — at least one file passed and `--filter` matched something.
    * `1` — directory missing, filter matched no files, or no files
      passed at all.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _positional} =
      OptionParser.parse!(args,
        strict: [dir: :string, filter: :string, timeout: :integer, verbose: :boolean]
      )

    dir = Keyword.get(opts, :dir, "test/lua53_tests")
    filter = Keyword.get(opts, :filter)
    timeout = Keyword.get(opts, :timeout, 30_000)
    verbose? = Keyword.get(opts, :verbose, false)

    if !File.dir?(dir) do
      Mix.raise("Suite directory #{dir} does not exist. Run `mix lua.get_tests` first.")
    end

    files =
      dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".lua"))
      |> maybe_filter(filter)
      |> Enum.sort()

    if files == [] do
      message =
        if filter,
          do: "no .lua files in #{dir} match --filter #{inspect(filter)}",
          else: "no .lua files in #{dir}"

      Mix.raise(message)
    end

    results = Enum.map(files, &run_one(dir, &1, timeout))

    print_summary(results, verbose?)

    passing_count = Enum.count(results, &match?({:pass, _}, &1))
    if passing_count == 0, do: exit({:shutdown, 1})
  end

  defp maybe_filter(files, nil), do: files

  defp maybe_filter(files, filter) when is_binary(filter), do: Enum.filter(files, &String.contains?(&1, filter))

  defp run_one(dir, file, timeout) do
    path = Path.join(dir, file)
    task = Task.async(fn -> Lua.SuiteRunner.run_file(path) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, :ok} -> {:pass, file}
      {:ok, {:error, e}} -> {:fail, file, e}
      nil -> {:timeout, file, timeout}
      {:exit, reason} -> {:fail, file, %RuntimeError{message: "exited: #{inspect(reason)}"}}
    end
  end

  defp print_summary(results, verbose?) do
    passes = Enum.filter(results, &match?({:pass, _}, &1))
    fails = Enum.filter(results, &match?({:fail, _, _}, &1))
    timeouts = Enum.filter(results, &match?({:timeout, _, _}, &1))

    pass_count = length(passes)
    fail_count = length(fails)
    timeout_count = length(timeouts)

    Mix.shell().info("passing: #{pass_count}")
    Mix.shell().info("failing: #{fail_count}")
    if timeout_count > 0, do: Mix.shell().info("timeout: #{timeout_count}")

    if pass_count > 0 do
      names =
        passes
        |> Enum.map(fn {:pass, file} -> Path.basename(file, ".lua") end)
        |> Enum.sort()
        |> Enum.join(", ")

      Mix.shell().info("")
      Mix.shell().info("passing files: #{names}")
    end

    if fail_count > 0 do
      Mix.shell().info("")
      Mix.shell().info("failing files (top reason):")
      width = fails |> Enum.map(fn {:fail, f, _} -> String.length(f) end) |> Enum.max()

      Enum.each(fails, fn {:fail, file, e} ->
        reason = if verbose?, do: Exception.message(e), else: top_line(e)
        Mix.shell().info("  #{String.pad_trailing(file, width + 2)}#{reason}")
      end)
    end

    if timeout_count > 0 do
      Mix.shell().info("")
      Mix.shell().info("timed out:")
      width = timeouts |> Enum.map(fn {:timeout, f, _} -> String.length(f) end) |> Enum.max()

      Enum.each(timeouts, fn {:timeout, file, ms} ->
        Mix.shell().info("  #{String.pad_trailing(file, width + 2)}> #{ms}ms")
      end)
    end
  end

  defp top_line(e) do
    e
    |> Exception.message()
    |> String.split("\n", parts: 2)
    |> List.first()
  end
end

defmodule Mix.Tasks.Lua.Suite do
  @shortdoc "Runs the Lua 5.3 official test suite (contributors only)"
  @moduledoc """
  Runs every `.lua` file in `test/lua53_tests/` against this VM and
  prints a pass/fail summary.

  > #### Contributor-only task {: .info}
  >
  > This task is intended for development of the `:lua` library itself.
  > It is not shipped to Hex: the suite files under `test/lua53_tests/`
  > are downloaded into this repo via `mix lua.get_tests` and are not
  > part of the Hex package.

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
      mix lua.suite --status
      mix lua.suite --audit

  ## Options

    * `--dir DIR` — Directory containing the suite `.lua` files
      (default: `test/lua53_tests`).
    * `--filter PATTERN` — Run only files whose basename contains
      `PATTERN` (case-sensitive substring).
    * `--timeout MS` — Per-file timeout in milliseconds. Files that
      exceed it are reported as `timeout` (default: `30000`).
    * `--verbose` — Print the full error message for each failing
      file, not just the first line.
    * `--status` — Print a per-file conformance summary from
      `test/lua53_skips.exs`. Fast, no tests run.
    * `--audit` — For each skip entry, re-run the file with that
      entry removed and report whether it is stale (file passes
      without it). Slow.

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

  @skip_file "test/lua53_skips.exs"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _positional} =
      OptionParser.parse!(args,
        strict: [
          dir: :string,
          filter: :string,
          timeout: :integer,
          verbose: :boolean,
          status: :boolean,
          audit: :boolean,
          skip_file: :string
        ]
      )

    cond do
      Keyword.get(opts, :status, false) -> run_status(opts)
      Keyword.get(opts, :audit, false) -> run_audit(opts)
      true -> run_suite(opts)
    end
  end

  defp run_suite(opts) do
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
      {:ok, :ok} ->
        {:pass, file}

      {:ok, {:error, e}} ->
        {:fail, file, e}

      # Task was still running when we called shutdown — treat as timeout
      # regardless of whether brutal_kill returns nil or {:exit, :killed}.
      nil ->
        {:timeout, file, timeout}

      {:exit, :killed} ->
        {:timeout, file, timeout}

      {:exit, reason} ->
        {:fail, file, %Lua.RuntimeException{message: "exited: #{inspect(reason)}"}}
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

  # --- --status ---------------------------------------------------------

  defp run_status(opts) do
    skip_map = load_skip_map!(Keyword.get(opts, :skip_file, @skip_file))
    files = Map.keys(skip_map) |> Enum.sort()

    if files == [] do
      Mix.shell().info("No skip entries — suite is fully ranged.")
    else
      width = files |> Enum.map(&String.length/1) |> Enum.max()

      total_lines =
        skip_map
        |> Map.values()
        |> List.flatten()
        |> Enum.reject(&(&1.lines == :all))
        |> Enum.reduce(0, fn e, acc -> Enum.count(e.lines) + acc end)

      total_ranges =
        skip_map
        |> Map.values()
        |> List.flatten()
        |> Enum.reject(&(&1.lines == :all))
        |> length()

      all_count =
        skip_map
        |> Map.values()
        |> List.flatten()
        |> Enum.filter(&(&1.lines == :all))
        |> length()

      Enum.each(files, fn file ->
        entries = Map.get(skip_map, file)
        all? = Enum.any?(entries, &(&1.lines == :all))

        if all? do
          Mix.shell().info("  #{String.pad_trailing(file, width + 2)}:all pending triage")
        else
          lines = Enum.reduce(entries, 0, fn e, acc -> Enum.count(e.lines) + acc end)
          cats = entries |> Enum.map(& &1.category) |> Enum.frequencies()
          cats_str = cats |> Enum.map(fn {c, n} -> "#{c}×#{n}" end) |> Enum.join(", ")
          Mix.shell().info("  #{String.pad_trailing(file, width + 2)}#{lines} lines, #{length(entries)} ranges (#{cats_str})")
        end
      end)

      Mix.shell().info("")
      Mix.shell().info("Total: #{total_lines} skipped lines across #{total_ranges} ranges in #{length(files) - all_count} files. #{all_count} files pending initial triage.")

      categories =
        skip_map
        |> Map.values()
        |> List.flatten()
        |> Enum.reject(&(&1.lines == :all))
        |> Enum.map(& &1.category)
        |> Enum.frequencies()

      if categories != %{} do
        cats_str = categories |> Enum.sort_by(fn {_, n} -> -n end) |> Enum.map(fn {c, n} -> "#{c} #{n}" end) |> Enum.join(", ")
        Mix.shell().info("By category: #{cats_str}")
      end

      issues =
        skip_map
        |> Map.values()
        |> List.flatten()
        |> Enum.reject(&(&1.lines == :all))
        |> Enum.map(& &1.issue)

      with_issue = Enum.count(issues, &(&1 != nil))
      Mix.shell().info("By issue: #{with_issue} ranges linked, #{length(issues) - with_issue} unassigned.")
    end
  end

  # --- --audit ----------------------------------------------------------

  defp run_audit(opts) do
    dir = Keyword.get(opts, :dir, "test/lua53_tests")
    timeout = Keyword.get(opts, :timeout, 30_000)
    skip_map = load_skip_map!(Keyword.get(opts, :skip_file, @skip_file))

    files = Map.keys(skip_map) |> Enum.sort()
    total_entries =
      skip_map |> Map.values() |> List.flatten() |> length()

    Mix.shell().info("Auditing #{total_entries} skip entries across #{length(files)} files...")
    Mix.shell().info("")

    {stale, candidates} =
      Enum.reduce(files, {0, 0}, fn file, {stale_acc, cand_acc} ->
        entries = Map.get(skip_map, file)
        path = Path.join(dir, file)
        cond do
          Enum.any?(entries, &(&1.lines == :all)) ->
            case run_with_ranges(path, [], timeout) do
              :ok ->
                report(file, nil, "CANDIDATE", "file passes with no ranges — try promoting")
                {stale_acc, cand_acc + 1}

              {:error, e} ->
                line = error_line(e) || "?"
                report(file, nil, "ACTIVE", ":all entry, first failure at line #{line}")
                {stale_acc, cand_acc}

              :timeout ->
                report(file, nil, "TIMEOUT", "exceeded #{timeout}ms with no ranges")
                {stale_acc, cand_acc}
            end

          true ->
            Enum.reduce(entries, {stale_acc, cand_acc}, fn entry, {s, c} ->
              others = Enum.reject(entries, &(&1 == entry)) |> Enum.map(& &1.lines)

              case run_with_ranges(path, others, timeout) do
                :ok ->
                  report(file, entry.lines, "STALE", "file passes without this range — try removing")
                  {s + 1, c}

                {:error, e} ->
                  new_line = error_line(e)
                  if new_line && new_line not in entry.lines do
                    report(file, entry.lines, "MOVED", "failure now at line #{new_line} — consider narrowing")
                    {s, c}
                  else
                    {s, c}
                  end

                :timeout ->
                  report(file, entry.lines, "TIMEOUT", "exceeded #{timeout}ms without this range")
                  {s, c}
              end
            end)
        end
      end)

    Mix.shell().info("")
    Mix.shell().info("#{stale} stale entries, #{candidates} promotion candidates.")
  end

  defp run_with_ranges(path, ranges, timeout) do
    task = Task.async(fn -> Lua.SuiteRunner.run_file(path, skip_ranges: ranges) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, :ok} -> :ok
      {:ok, {:error, e}} -> {:error, e}
      _ -> :timeout
    end
  end

  defp error_line(e) when is_exception(e), do: Map.get(e, :line)
  defp error_line(_), do: nil

  defp report(file, nil, status, msg) do
    Mix.shell().info("  #{String.pad_trailing(file, 24)}#{String.pad_trailing(status, 12)}#{msg}")
  end

  defp report(file, range, status, msg) do
    label = "#{file}:#{range_to_string(range)}"
    Mix.shell().info("  #{String.pad_trailing(label, 24)}#{String.pad_trailing(status, 12)}#{msg}")
  end

  defp range_to_string(%Range{first: a, last: a}), do: "#{a}"
  defp range_to_string(%Range{first: a, last: b}), do: "#{a}..#{b}"

  defp load_skip_map!(path) do
    if !File.exists?(path) do
      Mix.raise("#{path} not found — nothing to report.")
    end

    path |> Code.eval_file() |> elem(0)
  end
end

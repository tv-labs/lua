defmodule Mix.Tasks.Lua.Bench do
  @shortdoc "Runs the benchmarks harness in benchmarks/ (contributors only)"
  @moduledoc """
  Runs one of the Benchee scripts in `benchmarks/`.

  > #### Contributor-only task {: .info}
  >
  > This task is intended for development of the `:lua` library itself.
  > It is not shipped to Hex: it shells out to `mix run` under
  > `MIX_ENV=benchmark`, which requires Benchee/Luerl/luaport deps that
  > only exist in this repo's `mix.exs`, and it reads from
  > `benchmarks/`, which is not part of the Hex package.

  Each script is a standalone `.exs` file that already compares this
  VM against Luerl (and C Lua via `:luaport` when available). The
  task is a convenience wrapper that

    * discovers the available workloads from `benchmarks/*.exs`,
    * re-runs each under `MIX_ENV=benchmark` (the Benchee, Luerl, and
      luaport deps are gated to that env in `mix.exs`),
    * forwards the child process's stdout/stderr.

  ## Usage

      mix lua.bench                          # run all workloads
      mix lua.bench --workload fibonacci     # run one
      mix lua.bench --list                   # print available workloads
      mix lua.bench --workload fibonacci --workload closures
                                             # run several

  ## Options

    * `--workload NAME` — Workload to run (basename of a file under
      `benchmarks/`, without the `.exs`). May be repeated; if omitted,
      every workload is run.
    * `--list` — Print the available workloads and exit.

  ## Notes

  This task shells out to `mix run` in the `:benchmark` env so the
  Benchee/Luerl/luaport deps are available. If `mix deps.get` hasn't
  been run in that env, the child process will print Mix's standard
  "could not find dependency" error.
  """

  use Mix.Task

  @bench_dir "benchmarks"

  @impl Mix.Task
  def run(args) do
    {opts, _positional} =
      OptionParser.parse!(args,
        strict: [workload: :keep, list: :boolean]
      )

    workloads = available_workloads()

    if workloads == [] do
      Mix.raise("no benchmark scripts found in #{@bench_dir}/")
    end

    if Keyword.get(opts, :list, false) do
      Enum.each(workloads, fn name -> Mix.shell().info(name) end)
      :ok
    else
      requested = Keyword.get_values(opts, :workload)
      to_run = pick_workloads(workloads, requested)
      Enum.each(to_run, &run_workload/1)
    end
  end

  defp available_workloads do
    case File.ls(@bench_dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".exs"))
        |> Enum.map(&Path.rootname(&1, ".exs"))
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end

  defp pick_workloads(available, []), do: available

  defp pick_workloads(available, requested) do
    unknown = requested -- available

    if unknown != [] do
      Mix.raise(
        "unknown workload(s): #{Enum.join(unknown, ", ")}. " <>
          "Available: #{Enum.join(available, ", ")}"
      )
    end

    Enum.filter(available, &(&1 in requested))
  end

  defp run_workload(name) do
    script = Path.join(@bench_dir, "#{name}.exs")
    Mix.shell().info("==> #{name}")

    {_output, status} =
      System.cmd("mix", ["run", script],
        env: [{"MIX_ENV", "benchmark"}],
        into: IO.stream(:stdio, :line),
        stderr_to_stdout: true
      )

    if status != 0 do
      Mix.raise("benchmark #{name} exited with status #{status}")
    end
  end
end

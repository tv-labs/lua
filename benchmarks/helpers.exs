# Shared configuration for the benchmark scripts under `benchmarks/`.
#
# Each script `Code.require_file/2`s this file at the top so the harness
# stays consistent across workloads. There is one knob — the
# `LUA_BENCH_MODE` env var — which selects between two pre-canned
# Benchee profiles:
#
#   * `quick` (default) — short windows for iteration during development.
#     Each Benchee.run takes ~4 seconds. Memory measurement is off.
#     Five workloads × 4 implementations ≈ 80 seconds wall clock.
#
#   * `full` — longer windows + memory measurement, suitable for
#     end-of-cycle definitive numbers and for the figures we paste into
#     PR descriptions or ROADMAP.md.
#
# Usage:
#
#     mix run benchmarks/fibonacci.exs                       # quick
#     LUA_BENCH_MODE=full mix run benchmarks/fibonacci.exs   # full
#     mix lua.bench                                          # quick across all
#     LUA_BENCH_MODE=full mix lua.bench                      # full across all
#
# Quick mode is intended for "did my change move the needle?" loops.
# Full mode is the source of truth for any number we publish.

defmodule Bench do
  @moduledoc false

  @doc """
  Returns the Benchee options keyword list for the current run mode.

  Mode is selected via the `LUA_BENCH_MODE` environment variable. Any
  value other than `"full"` is treated as quick mode.
  """
  def opts(extra \\ []) do
    base =
      case System.get_env("LUA_BENCH_MODE") do
        "full" -> [time: 10, warmup: 2, memory_time: 1]
        _ -> [time: 3, warmup: 1, memory_time: 0]
      end

    Keyword.merge(base, extra)
  end

  @doc """
  Returns the n-size sweep used by the multi-input table benchmarks.

  Quick mode runs a single representative size to keep iteration cheap.
  Full mode runs a sweep so we can see how a workload's perf curve
  changes with input size.
  """
  def table_inputs do
    case System.get_env("LUA_BENCH_MODE") do
      "full" -> [{"small (n=10)", 10}, {"medium (n=100)", 100}, {"large (n=1000)", 1000}]
      _ -> [{"medium (n=100)", 100}]
    end
  end

  @doc """
  Convenience helper. Prints the current mode at the top of a script so
  the run output is self-describing.
  """
  def banner(name) do
    mode = if System.get_env("LUA_BENCH_MODE") == "full", do: "full", else: "quick"
    IO.puts("\n=== #{name} (mode: #{mode}) ===\n")
  end
end

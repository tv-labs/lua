defmodule Website.Benchmarks do
  @moduledoc """
  The recorded cross-version benchmark results, read from `bench_results/`.

  Every released version has a directory of committed benchmark output at
  `bench_results/<version>/`, and this module turns those `summary.json` files
  into the rows rendered by `/benchmarks`.

  Version directories are **discovered by glob** and ordered by
  `Version.compare/2`, so recording a new release is the whole update: drop
  `bench_results/<version>/summary.json` in place and the page grows a column.
  The same goes for the report link, which tracks the newest
  `bench_results/versions-<date>.md`.

  What is *not* automatic is `@rows` below — the editorial choice of which
  workload cases are worth showing, and under what name. A new workload only
  appears once it has a row spec. A version that lacks a workload another
  version has renders as `—` in that cell rather than failing.

  All file reads happen at compile time and are registered as
  `@external_resource`, so editing recorded results recompiles the page.
  """

  @bench_results Path.expand("../../../bench_results", __DIR__)

  # label:  what the row is called on the page
  # sub:    second line, chart only
  # at:     {workload, case, input | nil} — case/input keys as normalised below
  # job:    the Benchee job whose number we quote
  # vs:     the same-run control job the ratio is taken against
  # metric:  :median (time) or :memory (allocation)
  # chart?:  whether the row also gets a dot in the ratio plot
  # warn?:   the newest release is behind the control here — flagged in both views
  # dagger?: the comparison is not like-for-like; the page footnotes why
  @rows [
    %{
      label: "Lua.new() — steady state",
      sub: "default options",
      at: {"vm_new", "VM instantiation: Lua.new/1 vs :luerl.init/0", nil},
      job: "lua (new)",
      vs: "luerl (init)",
      metric: :median,
      chart?: false,
      warn?: false,
      dagger?: false
    },
    %{
      label: "Lua.new() — allocation",
      sub: "default options",
      at: {"vm_new", "VM instantiation: Lua.new/1 vs :luerl.init/0", nil},
      job: "lua (new)",
      vs: "luerl (init)",
      metric: :memory,
      chart?: false,
      warn?: false,
      dagger?: false
    },
    %{
      label: "fibonacci fib(30)",
      sub: "recursive calls",
      at: {"fibonacci", "default", nil},
      job: "lua (chunk)",
      vs: "luerl",
      metric: :median,
      chart?: true,
      warn?: false,
      dagger?: false
    },
    %{
      label: "fibonacci — allocation",
      sub: "recursive calls",
      at: {"fibonacci", "default", nil},
      job: "lua (chunk)",
      vs: "luerl",
      metric: :memory,
      chart?: false,
      warn?: false,
      dagger?: false
    },
    %{
      label: "string.format (literal-heavy)",
      sub: "literal-heavy template",
      at: {"string_format", "string.format: long literal-heavy format string (n=1000)", nil},
      job: "lua (chunk)",
      vs: "luerl",
      metric: :median,
      chart?: true,
      warn?: false,
      dagger?: false
    },
    %{
      label: "pcall success path (n=500)",
      sub: "protected call, no raise",
      at: {"pcall_varargs", "call protocol: pcall, success path (n=500)", nil},
      job: "lua (chunk)",
      vs: "luerl",
      metric: :median,
      chart?: true,
      warn?: false,
      dagger?: false
    },
    %{
      label: "pairs over hash part (n=1000)",
      sub: "hash-part iteration",
      at: {"table_ops", "Table Pairs (hash)", "large (n=1000)"},
      job: "lua (chunk)",
      vs: "luerl",
      metric: :median,
      chart?: true,
      warn?: false,
      dagger?: false
    },
    %{
      label: "__index 3-level chain",
      sub: "prototype lookup",
      at: {"metamethods", "metamethods: 3-level __index chain (n=200)", nil},
      job: "lua (chunk)",
      vs: "luerl",
      metric: :median,
      chart?: true,
      warn?: false,
      dagger?: false
    },
    %{
      label: "closures",
      sub: "factory + upvalue mutation",
      at: {"closures", "default", nil},
      job: "lua (chunk)",
      vs: "luerl",
      metric: :median,
      chart?: true,
      warn?: false,
      dagger?: false
    },
    %{
      label: "table.sort (n=1000)",
      sub: "reverse-ordered input",
      at: {"table_ops", "Table Sort", "large (n=1000)"},
      job: "lua (chunk)",
      vs: "luerl",
      metric: :median,
      chart?: true,
      warn?: false,
      dagger?: false
    },
    %{
      label: "varargs + multi-return (n=500)",
      sub: "call protocol",
      at: {"pcall_varargs", "call protocol: varargs + multiple returns (n=500)", nil},
      job: "lua (chunk)",
      vs: "luerl",
      metric: :median,
      chart?: true,
      warn?: true,
      dagger?: false
    },
    %{
      label: "pcall raise + catch (n=500)",
      sub: "does strictly more work",
      at: {"pcall_varargs", "call protocol: pcall, raise + catch (n=500)", nil},
      job: "lua (chunk)",
      vs: "luerl",
      metric: :median,
      chart?: true,
      warn?: true,
      dagger?: true
    }
  ]

  summaries = Path.wildcard(Path.join(@bench_results, "*/summary.json"))

  if summaries == [] do
    raise """
    no benchmark summaries found under #{@bench_results}

    /benchmarks renders the committed results in bench_results/<version>/. If \
    this is a container build, the image needs the directory:

        COPY bench_results /app/bench_results
    """
  end

  for path <- summaries do
    @external_resource path
  end

  reports = Path.wildcard(Path.join(@bench_results, "versions-*.md"))

  # --- compile-time loading ------------------------------------------------

  # v0.4.0's run labelled cases differently: banners carry a " (mode: full)"
  # suffix, the single-case workloads say "(single case)" where later runs say
  # "default", per-input results sit under "inputs" rather than "by_input", and
  # input labels are prefixed "With input ". Normalise so one row spec resolves
  # against every ref.
  normalise_case = fn name ->
    case String.replace_suffix(name, " (mode: full)", "") do
      "(single case)" -> "default"
      other -> other
    end
  end

  normalise_input = fn name -> String.replace_prefix(name, "With input ", "") end

  parse = fn
    nil ->
      nil

    value ->
      case Regex.run(~r/^([\d.]+)\s*(\S+)$/, String.replace(value, "μ", "µ")) do
        [_, number, unit] ->
          scale =
            case unit do
              "ns" -> 1
              "µs" -> 1_000
              "ms" -> 1_000_000
              "s" -> 1_000_000_000
              "B" -> 1
              "KB" -> 1_024
              "MB" -> 1_024 * 1_024
              "GB" -> 1_024 * 1_024 * 1_024
              _ -> nil
            end

          # Benchee drops the decimal point on some values ("216 µs"), so
          # Float.parse rather than String.to_float.
          with true <- is_integer(scale), {number, ""} <- Float.parse(number) do
            number * scale
          else
            _ -> nil
          end

        _ ->
          nil
      end
  end

  data =
    for path <- summaries, into: %{} do
      version = path |> Path.dirname() |> Path.basename() |> String.trim_leading("v")

      cases =
        path
        |> File.read!()
        |> Jason.decode!()
        |> Map.new(fn {workload, body} ->
          normalised =
            case body do
              %{"raw" => _} ->
                %{}

              cases ->
                Map.new(cases, fn {name, one} ->
                  by_input = Map.get(one, "by_input") || Map.get(one, "inputs")

                  value =
                    if by_input,
                      do: Map.new(by_input, fn {k, v} -> {normalise_input.(k), v} end),
                      else: one

                  {normalise_case.(name), value}
                end)
            end

          {workload, normalised}
        end)

      {version, cases}
    end

  @versions data |> Map.keys() |> Enum.sort(&(Version.compare(&1, &2) != :gt))

  table_rows =
    for spec <- @rows do
      {workload, case_name, input} = spec.at

      values =
        for version <- @versions, into: %{} do
          jobs =
            with %{^workload => workloads} <- data[version],
                 %{^case_name => one} <- workloads do
              case input do
                nil -> Map.get(one, "jobs")
                key -> one |> Map.get(key, %{}) |> Map.get("jobs")
              end
            else
              _ -> nil
            end

          find = fn name ->
            jobs && Enum.find(jobs, &(&1["name"] == name))
          end

          field = if spec.metric == :memory, do: "memory", else: "median"
          mine = find.(spec.job)
          control = find.(spec.vs)

          shown = mine && mine[field]
          against = control && control[field]

          mine_number = parse.(shown)
          against_number = parse.(against)

          ratio =
            if is_number(mine_number) and is_number(against_number) and against_number > 0 do
              Float.round(mine_number / against_number, 2)
            end

          {version, %{value: shown, control: against, ratio: ratio, numeric: mine_number}}
        end

      Map.put(spec, :values, values)
    end

  @table_rows table_rows

  @report reports |> Enum.map(&Path.basename/1) |> Enum.max(fn -> nil end)

  @report_date (case @report && Regex.run(~r/(\d{4}-\d{2}-\d{2})/, @report) do
                  [_, date] -> Date.from_iso8601!(date)
                  _ -> nil
                end)

  # --- public API ----------------------------------------------------------

  @doc """
  Recorded versions, oldest first.
  """
  def versions, do: @versions

  @doc """
  The newest recorded version — the one the page's headline numbers describe.
  """
  def latest, do: List.last(@versions)

  @doc """
  Table rows: one per row spec, each carrying a value per version.
  """
  def rows, do: @table_rows

  @doc """
  The subset of rows plotted as ratio-vs-control dots.
  """
  def chart_rows, do: Enum.filter(@table_rows, & &1.chart?)

  @doc """
  Look up one row by label, for the headline tiles.
  """
  def row(label), do: Enum.find(@table_rows, &(&1.label == label))

  @doc """
  The value a row recorded for a version, or `nil` if that version lacks it.
  """
  def value(row, version), do: get_in(row.values, [version, :value])

  @doc """
  Whether a version holds the best (lowest) number in its row. Both metrics —
  duration and allocation — are better when smaller.
  """
  def best?(row, version) do
    numbers = for {_, %{numeric: n}} <- row.values, is_number(n), do: n
    mine = get_in(row.values, [version, :numeric])

    is_number(mine) and numbers != [] and mine == Enum.min(numbers)
  end

  @doc """
  The version before the newest — what the headline improvements are measured against.
  """
  def previous, do: Enum.at(@versions, -2)

  @doc """
  The figures quoted in the page's headline tiles and callout, derived from the
  rows so that recording a new release moves them without an edit here.
  """
  def headline do
    new = row("Lua.new() — steady state")
    new_memory = row("Lua.new() — allocation")
    fib = row("fibonacci fib(30)")
    fib_memory = row("fibonacci — allocation")
    raise_catch = row("pcall raise + catch (n=500)")
    varargs = row("varargs + multi-return (n=500)")

    %{
      previous: previous(),
      new_median: value(new, latest()),
      new_median_prev: value(new, previous()),
      new_speedup: improvement(new, previous(), latest()),
      new_memory: value(new_memory, latest()),
      new_memory_prev: value(new_memory, previous()),
      new_memory_factor: improvement(new_memory, previous(), latest()),
      fib_median: value(fib, latest()),
      fib_median_prev: value(fib, previous()),
      fib_speedup: inverse(ratio(fib, latest())),
      fib_prev_ratio: ratio(fib, previous()),
      fib_memory: value(fib_memory, latest()),
      fib_memory_control: get_in(fib_memory.values, [latest(), :control]),
      raise_ratio: ratio(raise_catch, latest()),
      raise_prev_ratio: ratio(raise_catch, previous()),
      varargs_ratio: ratio(varargs, latest())
    }
  end

  @doc """
  A row's ratio against its same-run control for one version.
  """
  def ratio(row, version), do: get_in(row.values, [version, :ratio])

  @doc """
  How many times better `to` is than `from` in a row, as display text.
  """
  def improvement(row, from, to) do
    with a when is_number(a) <- get_in(row.values, [from, :numeric]),
         b when is_number(b) <- get_in(row.values, [to, :numeric]),
         true <- b > 0 do
      format_factor(a / b)
    else
      _ -> nil
    end
  end

  @doc """
  Opacity for a version's colour, ramping oldest (faintest) to newest (solid).
  """
  def version_weight(_index, count) when count < 2, do: 1.0
  def version_weight(index, count), do: Float.round(0.35 + 0.65 * (index / (count - 1)), 2)

  @doc """
  Filename of the newest campaign report, e.g. `versions-2026-07-28.md`.
  """
  def report, do: @report

  @doc """
  Date of the newest campaign report, parsed from its filename.
  """
  def report_date, do: @report_date

  @doc """
  Log-scale x position, as a 0..100 percentage, for a ratio in the dot plot.
  """
  def plot_x(ratio) when is_number(ratio) do
    :math.log(ratio / xmin()) / :math.log(xmax() / xmin()) * 100
  end

  def xmin, do: 0.15
  def xmax, do: 2.1

  @doc """
  Gridline/tick positions for the plot axis.
  """
  def ticks, do: [{0.25, "4× faster"}, {0.5, "2× faster"}, {1.0, "parity"}, {2.0, "2× slower"}]

  # A ratio below parity, restated as the speedup it represents.
  defp inverse(ratio) when is_number(ratio) and ratio > 0, do: format_factor(1 / ratio)
  defp inverse(_ratio), do: nil

  # Large factors read better whole ("63×"); small ones need the decimal ("1.7×").
  defp format_factor(factor) when factor >= 10, do: factor |> round() |> Integer.to_string()
  defp format_factor(factor), do: :erlang.float_to_binary(factor, decimals: 1)
end

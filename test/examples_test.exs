defmodule ExamplesTest do
  use ExUnit.Case, async: true

  @examples_dir Path.expand("../guides/examples", __DIR__)

  notebooks =
    @examples_dir
    |> Path.join("*.livemd")
    |> Path.wildcard()
    |> Enum.sort()

  # Each notebook chains bindings across its cells (e.g. `lua` flows from one
  # cell to the next), so the cells are concatenated and evaluated as a single
  # unit. The `Mix.install/1` setup cell is dropped: the library is already a
  # dependency of the test app, and re-installing it inside the suite is both
  # unnecessary and unsupported.
  for notebook <- notebooks do
    name = Path.basename(notebook)

    test "#{name} evaluates cleanly" do
      code =
        unquote(notebook)
        |> File.read!()
        |> elixir_cells()
        |> Enum.reject(&String.contains?(&1, "Mix.install"))
        |> Enum.join("\n")

      # Concatenating the cells turns each intermediate cell's trailing result
      # variable (e.g. `answer`) into a non-final expression, so eval emits
      # "variable has no effect" warnings to stderr. They are eval-time, not
      # compile-time, so they never trip `--warnings-as-errors`; capture stdout
      # and stderr to keep the suite output clean. A genuinely stale snippet
      # still raises, failing the test.
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        ExUnit.CaptureIO.capture_io(fn ->
          Code.eval_string(code, [], __ENV__)
        end)
      end)
    end
  end

  defp elixir_cells(source) do
    ~r/```elixir\n(.*?)```/s
    |> Regex.scan(source, capture: :all_but_first)
    |> Enum.map(fn [cell] -> cell end)
  end
end

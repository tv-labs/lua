defmodule Mix.Tasks.Lua.BenchTest do
  # The bench task shells out to `mix run` under MIX_ENV=benchmark,
  # which is too expensive to do in a unit test. These tests cover
  # argument parsing and discovery — the path that runs benchmarks
  # is exercised manually.

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Lua.Bench

  describe "--list" do
    test "prints every benchmark workload found in benchmarks/" do
      output = capture_io(fn -> Bench.run(["--list"]) end)

      expected =
        "benchmarks"
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".exs"))
        |> Enum.map(&Path.rootname(&1, ".exs"))
        |> Enum.sort()

      for name <- expected do
        assert output =~ name, "expected `mix lua.bench --list` to print #{name}"
      end
    end
  end

  describe "argument validation" do
    test "raises Mix error when --workload names something that does not exist" do
      assert_raise Mix.Error, ~r/unknown workload/, fn ->
        Bench.run(["--workload", "definitely_not_a_workload_4912"])
      end
    end
  end
end

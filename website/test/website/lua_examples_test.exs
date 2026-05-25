defmodule Website.LuaExamplesTest do
  use ExUnit.Case, async: true

  alias Website.LuaSandbox

  @all Enum.map(LuaSandbox.home_snippets(), &{"home", &1}) ++
         Enum.map(LuaSandbox.examples(), &{"playground", &1}) ++
         Enum.map(LuaSandbox.tour_lessons(), &{"tour", &1})

  for {source, example} <- @all do
    @example example
    @expect Map.get(example, :expect, :ok)
    @label "#{source}/#{example[:id] || example[:slug]}"

    test "#{@label} (#{@expect})" do
      result = LuaSandbox.run(@example.source, timeout_ms: 2_000)

      case @expect do
        :ok ->
          assert result.status == :ok,
                 "expected #{@label} to run cleanly, got: #{inspect(result.error)}"

          assert match?({:ok, _chunk, _blocks}, LuaSandbox.compile(@example.source)),
                 "expected #{@label} to compile cleanly"

        :compile_error ->
          assert result.status == :error,
                 "expected #{@label} to fail, but it succeeded"

          assert match?({:error, _msgs}, LuaSandbox.compile(@example.source)),
                 "expected #{@label} to fail compilation"

        :runtime_error ->
          assert result.status == :error,
                 "expected #{@label} to fail at runtime, but it succeeded"

          assert match?({:ok, _chunk, _blocks}, LuaSandbox.compile(@example.source)),
                 "expected #{@label} to compile cleanly (runtime-only failure)"
      end
    end
  end
end

defmodule ExamplesTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  for path <- Path.wildcard("examples/*.exs") do
    @path path

    test "#{@path} runs without errors" do
      capture_io(fn ->
        assert {_result, _bindings} = Code.eval_file(@path)
      end)
    end
  end
end

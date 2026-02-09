defmodule Lua.Compiler.SourceLineTest do
  use ExUnit.Case, async: true

  alias Lua.{Parser, Compiler}

  describe "source line tracking" do
    test "emits source_line instructions before statements" do
      code = """
      local x = 1
      local y = 2
      return x + y
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")

      # Check that source_line instructions are present
      source_line_instructions =
        proto.instructions
        |> Enum.filter(fn
          {:source_line, _, _} -> true
          _ -> false
        end)

      # Should have source_line before each of the 3 statements
      assert length(source_line_instructions) >= 3
    end

    test "source_line instructions contain correct line numbers" do
      code = """
      local x = 1
      local y = 2
      local z = 3
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")

      # Extract line numbers from source_line instructions
      line_numbers =
        proto.instructions
        |> Enum.filter(fn
          {:source_line, _, _} -> true
          _ -> false
        end)
        |> Enum.map(fn {:source_line, line, _} -> line end)

      # Should track lines 1, 2, 3
      assert 1 in line_numbers
      assert 2 in line_numbers
      assert 3 in line_numbers
    end

    test "source_line instructions reference correct source file" do
      code = "return 42"

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "my_file.lua")

      # Find a source_line instruction
      source_line_instr =
        Enum.find(proto.instructions, fn
          {:source_line, _, _} -> true
          _ -> false
        end)

      assert {:source_line, _line, "my_file.lua"} = source_line_instr
    end

    test "computes correct line range for chunk" do
      code = """
      local x = 1


      local y = 5
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")

      # Lines should span from 1 to at least 4
      assert {first, last} = proto.lines
      assert first == 1
      assert last >= 4
    end

    test "computes line range for nested functions" do
      code = """
      local x = function()
        local y = 2
        return y
      end
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")

      # Should have a nested prototype for the function
      assert length(proto.prototypes) >= 1
      nested_proto = hd(proto.prototypes)

      # Nested function should have lines 2-3
      assert {first, last} = nested_proto.lines
      assert first >= 2
      assert last >= 3
    end
  end
end

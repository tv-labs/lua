defmodule Lua.AST.PrettyPrinterTest do
  use ExUnit.Case, async: true

  import Lua.AST.Builder
  alias Lua.AST.PrettyPrinter

  describe "literals" do
    test "prints nil" do
      assert PrettyPrinter.print(chunk([return_stmt([nil_lit()])])) == "return nil\n"
    end

    test "prints booleans" do
      assert PrettyPrinter.print(chunk([return_stmt([bool(true)])])) == "return true\n"
      assert PrettyPrinter.print(chunk([return_stmt([bool(false)])])) == "return false\n"
    end

    test "prints numbers" do
      assert PrettyPrinter.print(chunk([return_stmt([number(42)])])) == "return 42\n"
      assert PrettyPrinter.print(chunk([return_stmt([number(3.14)])])) == "return 3.14\n"
      assert PrettyPrinter.print(chunk([return_stmt([number(1.0)])])) == "return 1.0\n"
    end

    test "prints strings" do
      assert PrettyPrinter.print(chunk([return_stmt([string("hello")])])) == "return \"hello\"\n"
    end

    test "escapes special characters in strings" do
      ast = chunk([return_stmt([string("hello\nworld")])])
      result = PrettyPrinter.print(ast)
      assert result == "return \"hello\\nworld\"\n"
    end

    test "prints vararg" do
      assert PrettyPrinter.print(chunk([return_stmt([vararg()])])) == "return ...\n"
    end
  end

  describe "variables and access" do
    test "prints variable reference" do
      assert PrettyPrinter.print(chunk([return_stmt([var("x")])])) == "return x\n"
    end

    test "prints property access" do
      ast = chunk([return_stmt([property(var("io"), "write")])])
      assert PrettyPrinter.print(ast) == "return io.write\n"
    end

    test "prints index access" do
      ast = chunk([return_stmt([index(var("t"), number(1))])])
      assert PrettyPrinter.print(ast) == "return t[1]\n"
    end

    test "prints chained property access" do
      ast = chunk([return_stmt([
        property(property(var("a"), "b"), "c")
      ])])
      assert PrettyPrinter.print(ast) == "return a.b.c\n"
    end
  end

  describe "operators" do
    test "prints binary operators" do
      ast = chunk([return_stmt([binop(:add, number(2), number(3))])])
      assert PrettyPrinter.print(ast) == "return 2 + 3\n"
    end

    test "prints unary operators" do
      ast = chunk([return_stmt([unop(:neg, var("x"))])])
      assert PrettyPrinter.print(ast) == "return -x\n"

      ast = chunk([return_stmt([unop(:not, var("flag"))])])
      assert PrettyPrinter.print(ast) == "return not flag\n"

      ast = chunk([return_stmt([unop(:len, var("list"))])])
      assert PrettyPrinter.print(ast) == "return #list\n"
    end

    test "handles operator precedence with parentheses" do
      # 2 + 3 * 4 should print as is (multiplication has higher precedence)
      ast = chunk([return_stmt([
        binop(:add, number(2), binop(:mul, number(3), number(4)))
      ])])
      assert PrettyPrinter.print(ast) == "return 2 + 3 * 4\n"

      # (2 + 3) * 4 should have parentheses
      ast = chunk([return_stmt([
        binop(:mul, binop(:add, number(2), number(3)), number(4))
      ])])
      assert PrettyPrinter.print(ast) == "return (2 + 3) * 4\n"
    end

    test "handles right-associative operators" do
      # 2 ^ 3 ^ 4 should print as 2 ^ 3 ^ 4 (right-associative)
      ast = chunk([return_stmt([
        binop(:pow, number(2), binop(:pow, number(3), number(4)))
      ])])
      assert PrettyPrinter.print(ast) == "return 2 ^ 3 ^ 4\n"

      # (2 ^ 3) ^ 4 should have parentheses
      ast = chunk([return_stmt([
        binop(:pow, binop(:pow, number(2), number(3)), number(4))
      ])])
      assert PrettyPrinter.print(ast) == "return (2 ^ 3) ^ 4\n"
    end

    test "handles unary minus with power" do
      # -2^3 should print with parentheses as -(2^3) is not needed because parser handles it
      ast = chunk([return_stmt([unop(:neg, binop(:pow, number(2), number(3)))])])
      result = PrettyPrinter.print(ast)
      # Either -2^3 or -(2^3) is acceptable
      assert result == "return -(2 ^ 3)\n" or result == "return -2 ^ 3\n"
    end
  end

  describe "table constructors" do
    test "prints empty table" do
      ast = chunk([return_stmt([table([])])])
      assert PrettyPrinter.print(ast) == "return {}\n"
    end

    test "prints array-style table" do
      ast = chunk([return_stmt([
        table([
          {:list, number(1)},
          {:list, number(2)},
          {:list, number(3)}
        ])
      ])])
      assert PrettyPrinter.print(ast) == "return {1, 2, 3}\n"
    end

    test "prints record-style table" do
      ast = chunk([return_stmt([
        table([
          {:record, string("x"), number(10)},
          {:record, string("y"), number(20)}
        ])
      ])])
      assert PrettyPrinter.print(ast) == "return {x = 10, y = 20}\n"
    end

    test "prints mixed table fields" do
      ast = chunk([return_stmt([
        table([
          {:list, number(1)},
          {:record, string("x"), number(10)}
        ])
      ])])
      assert PrettyPrinter.print(ast) == "return {1, x = 10}\n"
    end
  end

  describe "function calls" do
    test "prints simple function call" do
      ast = chunk([call_stmt(call(var("print"), [string("hello")]))])
      assert PrettyPrinter.print(ast) == "print(\"hello\")\n"
    end

    test "prints function call with multiple arguments" do
      ast = chunk([call_stmt(call(var("print"), [number(1), number(2), number(3)]))])
      assert PrettyPrinter.print(ast) == "print(1, 2, 3)\n"
    end

    test "prints method call" do
      ast = chunk([call_stmt(method_call(var("file"), "read", [string("*a")]))])
      assert PrettyPrinter.print(ast) == "file:read(\"*a\")\n"
    end
  end

  describe "function expressions" do
    test "prints simple function" do
      ast = chunk([return_stmt([
        function_expr(["x"], [return_stmt([var("x")])])
      ])])
      result = PrettyPrinter.print(ast)
      assert result =~ "function(x)"
      assert result =~ "return x"
      assert result =~ "end"
    end

    test "prints function with multiple parameters" do
      ast = chunk([return_stmt([
        function_expr(["a", "b"], [return_stmt([binop(:add, var("a"), var("b"))])])
      ])])
      result = PrettyPrinter.print(ast)
      assert result =~ "function(a, b)"
      assert result =~ "return a + b"
    end

    test "prints function with vararg" do
      ast = chunk([return_stmt([
        function_expr([], [return_stmt([vararg()])], vararg: true)
      ])])
      result = PrettyPrinter.print(ast)
      assert result =~ "function(...)"
    end
  end

  describe "statements" do
    test "prints assignment" do
      ast = chunk([assign([var("x")], [number(42)])])
      assert PrettyPrinter.print(ast) == "x = 42\n"
    end

    test "prints multiple assignment" do
      ast = chunk([assign([var("x"), var("y")], [number(1), number(2)])])
      assert PrettyPrinter.print(ast) == "x, y = 1, 2\n"
    end

    test "prints local declaration" do
      ast = chunk([local(["x"], [number(42)])])
      assert PrettyPrinter.print(ast) == "local x = 42\n"
    end

    test "prints local declaration without value" do
      ast = chunk([local(["x"], [])])
      assert PrettyPrinter.print(ast) == "local x\n"
    end

    test "prints local function" do
      ast = chunk([local_func("add", ["a", "b"], [return_stmt([binop(:add, var("a"), var("b"))])])])
      result = PrettyPrinter.print(ast)
      assert result =~ "local function add(a, b)"
      assert result =~ "return a + b"
      assert result =~ "end"
    end

    test "prints function declaration" do
      ast = chunk([func_decl("add", ["a", "b"], [return_stmt([binop(:add, var("a"), var("b"))])])])
      result = PrettyPrinter.print(ast)
      assert result =~ "function add(a, b)"
      assert result =~ "return a + b"
      assert result =~ "end"
    end

    test "prints return statement" do
      ast = chunk([return_stmt([])])
      assert PrettyPrinter.print(ast) == "return\n"

      ast = chunk([return_stmt([number(42)])])
      assert PrettyPrinter.print(ast) == "return 42\n"
    end

    test "prints break statement" do
      ast = chunk([break_stmt()])
      assert PrettyPrinter.print(ast) == "break\n"
    end
  end

  describe "control flow" do
    test "prints if statement" do
      ast = chunk([
        if_stmt(var("x"), [return_stmt([number(1)])])
      ])
      result = PrettyPrinter.print(ast)
      assert result =~ "if x then"
      assert result =~ "return 1"
      assert result =~ "end"
    end

    test "prints if-else statement" do
      ast = chunk([
        if_stmt(
          var("x"),
          [return_stmt([number(1)])],
          else: [return_stmt([number(0)])]
        )
      ])
      result = PrettyPrinter.print(ast)
      assert result =~ "if x then"
      assert result =~ "else"
      assert result =~ "end"
    end

    test "prints if-elseif-else statement" do
      ast = chunk([
        if_stmt(
          binop(:gt, var("x"), number(0)),
          [return_stmt([number(1)])],
          elseif: [{binop(:lt, var("x"), number(0)), [return_stmt([unop(:neg, number(1))])]}],
          else: [return_stmt([number(0)])]
        )
      ])
      result = PrettyPrinter.print(ast)
      assert result =~ "if x > 0 then"
      assert result =~ "elseif x < 0 then"
      assert result =~ "else"
      assert result =~ "end"
    end

    test "prints while loop" do
      ast = chunk([
        while_stmt(binop(:gt, var("x"), number(0)), [
          assign([var("x")], [binop(:sub, var("x"), number(1))])
        ])
      ])
      result = PrettyPrinter.print(ast)
      assert result =~ "while x > 0 do"
      assert result =~ "x = x - 1"
      assert result =~ "end"
    end

    test "prints repeat-until loop" do
      ast = chunk([
        repeat_stmt(
          [assign([var("x")], [binop(:sub, var("x"), number(1))])],
          binop(:le, var("x"), number(0))
        )
      ])
      result = PrettyPrinter.print(ast)
      assert result =~ "repeat"
      assert result =~ "x = x - 1"
      assert result =~ "until x <= 0"
    end

    test "prints numeric for loop" do
      ast = chunk([
        for_num("i", number(1), number(10), [
          call_stmt(call(var("print"), [var("i")]))
        ])
      ])
      result = PrettyPrinter.print(ast)
      assert result =~ "for i = 1, 10 do"
      assert result =~ "print(i)"
      assert result =~ "end"
    end

    test "prints numeric for loop with step" do
      ast = chunk([
        for_num("i", number(1), number(10), [
          call_stmt(call(var("print"), [var("i")]))
        ], step: number(2))
      ])
      result = PrettyPrinter.print(ast)
      assert result =~ "for i = 1, 10, 2 do"
    end

    test "prints generic for loop" do
      ast = chunk([
        for_in(
          ["k", "v"],
          [call(var("pairs"), [var("t")])],
          [call_stmt(call(var("print"), [var("k"), var("v")]))]
        )
      ])
      result = PrettyPrinter.print(ast)
      assert result =~ "for k, v in pairs(t) do"
      assert result =~ "print(k, v)"
      assert result =~ "end"
    end

    test "prints do block" do
      ast = chunk([
        do_block([
          local(["x"], [number(10)]),
          call_stmt(call(var("print"), [var("x")]))
        ])
      ])
      result = PrettyPrinter.print(ast)
      assert result =~ "do"
      assert result =~ "local x = 10"
      assert result =~ "print(x)"
      assert result =~ "end"
    end
  end

  describe "indentation" do
    test "indents nested blocks" do
      ast = chunk([
        if_stmt(var("x"), [
          if_stmt(var("y"), [
            return_stmt([number(1)])
          ])
        ])
      ])
      result = PrettyPrinter.print(ast)
      # Check that nested blocks are indented
      lines = String.split(result, "\n", trim: true)
      assert Enum.any?(lines, fn line -> String.starts_with?(line, "    ") end)
    end

    test "respects custom indent size" do
      ast = chunk([
        if_stmt(var("x"), [
          return_stmt([number(1)])
        ])
      ])
      result = PrettyPrinter.print(ast, indent: 4)
      assert result =~ "    return 1"
    end
  end

  describe "round-trip" do
    test "can round-trip simple expressions" do
      original = "return 2 + 3\n"
      {:ok, ast} = Lua.Parser.parse(original)
      printed = PrettyPrinter.print(ast)
      assert printed == original
    end

    test "can round-trip local assignments" do
      original = "local x = 42\n"
      {:ok, ast} = Lua.Parser.parse(original)
      printed = PrettyPrinter.print(ast)
      assert printed == original
    end

    test "can round-trip function declarations" do
      code = """
      function add(a, b)
        return a + b
      end
      """

      {:ok, ast} = Lua.Parser.parse(code)
      printed = PrettyPrinter.print(ast)

      # Parse again to verify structure matches
      {:ok, ast2} = Lua.Parser.parse(printed)

      # Compare AST structures (ignoring meta)
      assert ast.block.stmts |> length() == ast2.block.stmts |> length()
    end
  end
end

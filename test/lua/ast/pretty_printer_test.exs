defmodule Lua.AST.PrettyPrinterTest do
  use ExUnit.Case, async: true

  import Lua.AST.Builder

  alias Lua.AST.Block
  alias Lua.AST.Chunk
  alias Lua.AST.Meta
  alias Lua.AST.PrettyPrinter
  alias Lua.Parser

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
      ast =
        chunk([
          return_stmt([
            property(property(var("a"), "b"), "c")
          ])
        ])

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
      ast =
        chunk([
          return_stmt([
            binop(:add, number(2), binop(:mul, number(3), number(4)))
          ])
        ])

      assert PrettyPrinter.print(ast) == "return 2 + 3 * 4\n"

      # (2 + 3) * 4 should have parentheses
      ast =
        chunk([
          return_stmt([
            binop(:mul, binop(:add, number(2), number(3)), number(4))
          ])
        ])

      assert PrettyPrinter.print(ast) == "return (2 + 3) * 4\n"
    end

    test "handles right-associative operators" do
      # 2 ^ 3 ^ 4 should print as 2 ^ 3 ^ 4 (right-associative)
      ast =
        chunk([
          return_stmt([
            binop(:pow, number(2), binop(:pow, number(3), number(4)))
          ])
        ])

      assert PrettyPrinter.print(ast) == "return 2 ^ 3 ^ 4\n"

      # (2 ^ 3) ^ 4 should have parentheses
      ast =
        chunk([
          return_stmt([
            binop(:pow, binop(:pow, number(2), number(3)), number(4))
          ])
        ])

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
      ast =
        chunk([
          return_stmt([
            table([
              {:list, number(1)},
              {:list, number(2)},
              {:list, number(3)}
            ])
          ])
        ])

      assert PrettyPrinter.print(ast) == "return {1, 2, 3}\n"
    end

    test "prints record-style table" do
      ast =
        chunk([
          return_stmt([
            table([
              {:record, string("x"), number(10)},
              {:record, string("y"), number(20)}
            ])
          ])
        ])

      assert PrettyPrinter.print(ast) == "return {x = 10, y = 20}\n"
    end

    test "prints mixed table fields" do
      ast =
        chunk([
          return_stmt([
            table([
              {:list, number(1)},
              {:record, string("x"), number(10)}
            ])
          ])
        ])

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
      ast =
        chunk([
          return_stmt([
            function_expr(["x"], [return_stmt([var("x")])])
          ])
        ])

      result = PrettyPrinter.print(ast)
      assert result =~ "function(x)"
      assert result =~ "return x"
      assert result =~ "end"
    end

    test "prints function with multiple parameters" do
      ast =
        chunk([
          return_stmt([
            function_expr(["a", "b"], [return_stmt([binop(:add, var("a"), var("b"))])])
          ])
        ])

      result = PrettyPrinter.print(ast)
      assert result =~ "function(a, b)"
      assert result =~ "return a + b"
    end

    test "prints function with vararg" do
      ast =
        chunk([
          return_stmt([
            function_expr([], [return_stmt([vararg()])], vararg: true)
          ])
        ])

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
      ast =
        chunk([local_func("add", ["a", "b"], [return_stmt([binop(:add, var("a"), var("b"))])])])

      result = PrettyPrinter.print(ast)
      assert result =~ "local function add(a, b)"
      assert result =~ "return a + b"
      assert result =~ "end"
    end

    test "prints function declaration" do
      ast =
        chunk([func_decl("add", ["a", "b"], [return_stmt([binop(:add, var("a"), var("b"))])])])

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
      ast =
        chunk([
          if_stmt(var("x"), [return_stmt([number(1)])])
        ])

      result = PrettyPrinter.print(ast)
      assert result =~ "if x then"
      assert result =~ "return 1"
      assert result =~ "end"
    end

    test "prints if-else statement" do
      ast =
        chunk([
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
      ast =
        chunk([
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
      ast =
        chunk([
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
      ast =
        chunk([
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
      ast =
        chunk([
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
      ast =
        chunk([
          for_num(
            "i",
            number(1),
            number(10),
            [
              call_stmt(call(var("print"), [var("i")]))
            ],
            step: number(2)
          )
        ])

      result = PrettyPrinter.print(ast)
      assert result =~ "for i = 1, 10, 2 do"
    end

    test "prints generic for loop" do
      ast =
        chunk([
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
      ast =
        chunk([
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
      ast =
        chunk([
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
      ast =
        chunk([
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
      {:ok, ast} = Parser.parse(original)
      printed = PrettyPrinter.print(ast)
      assert printed == original
    end

    test "can round-trip local assignments" do
      original = "local x = 42\n"
      {:ok, ast} = Parser.parse(original)
      printed = PrettyPrinter.print(ast)
      assert printed == original
    end

    test "can round-trip function declarations" do
      code = """
      function add(a, b)
        return a + b
      end
      """

      {:ok, ast} = Parser.parse(code)
      printed = PrettyPrinter.print(ast)

      # Parse again to verify structure matches
      {:ok, ast2} = Parser.parse(printed)

      # Compare AST structures (ignoring meta)
      assert length(ast.block.stmts) == length(ast2.block.stmts)
    end
  end

  describe "string escaping" do
    test "escapes backslash" do
      ast = chunk([return_stmt([string("path\\to\\file")])])
      result = PrettyPrinter.print(ast)
      assert result == "return \"path\\\\to\\\\file\"\n"
    end

    test "escapes double quotes" do
      ast = chunk([return_stmt([string("say \"hello\"")])])
      result = PrettyPrinter.print(ast)
      assert result == ~s(return "say \\"hello\\""\n)
    end

    test "escapes tab character" do
      ast = chunk([return_stmt([string("hello\tworld")])])
      result = PrettyPrinter.print(ast)
      assert result == "return \"hello\\tworld\"\n"
    end

    test "escapes all special characters together" do
      ast = chunk([return_stmt([string("line1\n\"quote\"\ttab\\back")])])
      result = PrettyPrinter.print(ast)
      assert result == ~s(return "line1\\n\\"quote\\"\\ttab\\\\back"\n)
    end
  end

  describe "all binary operators" do
    test "prints floor division" do
      ast = chunk([return_stmt([binop(:floor_div, number(10), number(3))])])
      assert PrettyPrinter.print(ast) == "return 10 // 3\n"
    end

    test "prints modulo" do
      ast = chunk([return_stmt([binop(:mod, number(10), number(3))])])
      assert PrettyPrinter.print(ast) == "return 10 % 3\n"
    end

    test "prints concatenation" do
      ast = chunk([return_stmt([binop(:concat, string("hello"), string("world"))])])
      assert PrettyPrinter.print(ast) == ~s(return "hello" .. "world"\n)
    end

    test "prints equality" do
      ast = chunk([return_stmt([binop(:eq, var("x"), var("y"))])])
      assert PrettyPrinter.print(ast) == "return x == y\n"
    end

    test "prints inequality" do
      ast = chunk([return_stmt([binop(:ne, var("x"), var("y"))])])
      assert PrettyPrinter.print(ast) == "return x ~= y\n"
    end

    test "prints less than or equal" do
      ast = chunk([return_stmt([binop(:le, var("x"), var("y"))])])
      assert PrettyPrinter.print(ast) == "return x <= y\n"
    end

    test "prints greater than or equal" do
      ast = chunk([return_stmt([binop(:ge, var("x"), var("y"))])])
      assert PrettyPrinter.print(ast) == "return x >= y\n"
    end

    test "prints logical and" do
      ast = chunk([return_stmt([binop(:and, var("x"), var("y"))])])
      assert PrettyPrinter.print(ast) == "return x and y\n"
    end

    test "prints logical or" do
      ast = chunk([return_stmt([binop(:or, var("x"), var("y"))])])
      assert PrettyPrinter.print(ast) == "return x or y\n"
    end
  end

  describe "operator associativity" do
    test "handles concat right-associativity" do
      # "a" .. "b" .. "c" should print as is (right-associative)
      ast =
        chunk([
          return_stmt([
            binop(:concat, string("a"), binop(:concat, string("b"), string("c")))
          ])
        ])

      assert PrettyPrinter.print(ast) == ~s(return "a" .. "b" .. "c"\n)

      # ("a" .. "b") .. "c" should have parentheses
      ast =
        chunk([
          return_stmt([
            binop(:concat, binop(:concat, string("a"), string("b")), string("c"))
          ])
        ])

      assert PrettyPrinter.print(ast) == ~s{return ("a" .. "b") .. "c"\n}
    end

    test "handles subtraction left-associativity" do
      # (10 - 5) - 2 should print as is (left-associative)
      ast =
        chunk([
          return_stmt([
            binop(:sub, binop(:sub, number(10), number(5)), number(2))
          ])
        ])

      assert PrettyPrinter.print(ast) == "return 10 - 5 - 2\n"

      # 10 - (5 - 2) should have parentheses
      ast =
        chunk([
          return_stmt([
            binop(:sub, number(10), binop(:sub, number(5), number(2)))
          ])
        ])

      assert PrettyPrinter.print(ast) == "return 10 - (5 - 2)\n"
    end
  end

  describe "table key formatting" do
    test "uses bracket notation for non-identifier strings" do
      ast =
        chunk([
          return_stmt([
            table([
              {:record, string("not-valid"), number(1)},
              {:record, string("123"), number(2)},
              {:record, string("with space"), number(3)}
            ])
          ])
        ])

      result = PrettyPrinter.print(ast)
      assert result =~ "[\"not-valid\"] = 1"
      assert result =~ "[\"123\"] = 2"
      assert result =~ "[\"with space\"] = 3"
    end

    test "uses bracket notation for Lua keywords" do
      ast =
        chunk([
          return_stmt([
            table([
              {:record, string("end"), number(1)},
              {:record, string("while"), number(2)},
              {:record, string("function"), number(3)}
            ])
          ])
        ])

      result = PrettyPrinter.print(ast)
      assert result =~ "[\"end\"] = 1"
      assert result =~ "[\"while\"] = 2"
      assert result =~ "[\"function\"] = 3"
    end

    test "uses bracket notation for non-string keys" do
      ast =
        chunk([
          return_stmt([
            table([
              {:record, number(1), string("first")},
              {:record, var("x"), string("variable")}
            ])
          ])
        ])

      result = PrettyPrinter.print(ast)
      assert result =~ "[1] = \"first\""
      assert result =~ "[x] = \"variable\""
    end
  end

  describe "dotted function names" do
    test "prints function with dotted name" do
      ast =
        chunk([
          func_decl(["math", "add"], ["a", "b"], [return_stmt([binop(:add, var("a"), var("b"))])])
        ])

      result = PrettyPrinter.print(ast)
      assert result =~ "function math.add(a, b)"
    end

    test "prints function with deeply nested name" do
      ast =
        chunk([
          func_decl(["a", "b", "c"], ["x"], [return_stmt([var("x")])])
        ])

      result = PrettyPrinter.print(ast)
      assert result =~ "function a.b.c(x)"
    end
  end

  describe "local statement variations" do
    test "prints local with nil values" do
      ast = chunk([local(["x"], nil)])
      assert PrettyPrinter.print(ast) == "local x\n"
    end

    test "prints multiple local variables" do
      ast = chunk([local(["x", "y", "z"], [])])
      assert PrettyPrinter.print(ast) == "local x, y, z\n"
    end

    test "prints multiple local variables with values" do
      ast = chunk([local(["x", "y"], [number(1), number(2)])])
      assert PrettyPrinter.print(ast) == "local x, y = 1, 2\n"
    end
  end

  describe "goto and label statements" do
    test "prints goto statement" do
      ast = chunk([goto_stmt("skip")])
      assert PrettyPrinter.print(ast) == "goto skip\n"
    end

    test "prints label statement" do
      ast = chunk([label("skip")])
      assert PrettyPrinter.print(ast) == "::skip::\n"
    end
  end

  describe "function calls with no arguments" do
    test "prints function call with no arguments" do
      ast = chunk([call_stmt(call(var("print"), []))])
      assert PrettyPrinter.print(ast) == "print()\n"
    end

    test "prints method call with no arguments" do
      ast = chunk([call_stmt(method_call(var("obj"), "method", []))])
      assert PrettyPrinter.print(ast) == "obj:method()\n"
    end
  end

  describe "if statement variations" do
    test "prints if statement without elseif" do
      ast =
        chunk([
          if_stmt(
            var("x"),
            [return_stmt([number(1)])],
            elseif: []
          )
        ])

      result = PrettyPrinter.print(ast)
      assert result =~ "if x then"
      assert result =~ "return 1"
      assert result =~ "end"
    end

    test "prints if statement with multiple elseifs" do
      ast =
        chunk([
          if_stmt(
            binop(:eq, var("x"), number(1)),
            [return_stmt([string("one")])],
            elseif: [
              {binop(:eq, var("x"), number(2)), [return_stmt([string("two")])]},
              {binop(:eq, var("x"), number(3)), [return_stmt([string("three")])]}
            ],
            else: [return_stmt([string("other")])]
          )
        ])

      result = PrettyPrinter.print(ast)
      assert result =~ "if x == 1 then"
      assert result =~ "elseif x == 2 then"
      assert result =~ "elseif x == 3 then"
      assert result =~ "else"
      assert result =~ "end"
    end
  end

  describe "local function with vararg" do
    test "prints local function with vararg parameter" do
      ast =
        chunk([
          local_func("variadic", [], [return_stmt([vararg()])], vararg: true)
        ])

      result = PrettyPrinter.print(ast)
      assert result =~ "local function variadic(...)"
      assert result =~ "return ..."
    end

    test "prints local function with mixed parameters and vararg" do
      ast =
        chunk([
          local_func("mixed", ["a", "b"], [return_stmt([vararg()])], vararg: true)
        ])

      result = PrettyPrinter.print(ast)
      assert result =~ "local function mixed(a, b, ...)"
    end
  end

  describe "function declaration with vararg" do
    test "prints function declaration with vararg parameter" do
      ast =
        chunk([
          func_decl("variadic", [], [return_stmt([vararg()])], vararg: true)
        ])

      result = PrettyPrinter.print(ast)
      assert result =~ "function variadic(...)"
      assert result =~ "return ..."
    end
  end

  describe "precedence edge cases" do
    test "handles division and multiplication precedence" do
      # 10 / 2 * 3 (same precedence, left-to-right)
      ast =
        chunk([
          return_stmt([
            binop(:mul, binop(:div, number(10), number(2)), number(3))
          ])
        ])

      assert PrettyPrinter.print(ast) == "return 10 / 2 * 3\n"
    end

    test "handles comparison operators with arithmetic" do
      # 2 + 3 < 10 (arithmetic has higher precedence)
      ast =
        chunk([
          return_stmt([
            binop(:lt, binop(:add, number(2), number(3)), number(10))
          ])
        ])

      assert PrettyPrinter.print(ast) == "return 2 + 3 < 10\n"
    end

    test "handles logical operators with comparisons" do
      # x < 10 and y > 5 (comparison has higher precedence)
      ast =
        chunk([
          return_stmt([
            binop(:and, binop(:lt, var("x"), number(10)), binop(:gt, var("y"), number(5)))
          ])
        ])

      assert PrettyPrinter.print(ast) == "return x < 10 and y > 5\n"
    end

    test "handles or with and (and has higher precedence)" do
      # a or b and c should print as a or (b and c)
      ast =
        chunk([
          return_stmt([
            binop(:or, var("a"), binop(:and, var("b"), var("c")))
          ])
        ])

      assert PrettyPrinter.print(ast) == "return a or b and c\n"
    end
  end

  describe "all comparison operators in precedence" do
    test "handles all comparison operators" do
      # Test that all comparison operators work together
      ast = chunk([return_stmt([binop(:lt, var("a"), var("b"))])])
      assert PrettyPrinter.print(ast) == "return a < b\n"

      ast = chunk([return_stmt([binop(:gt, var("a"), var("b"))])])
      assert PrettyPrinter.print(ast) == "return a > b\n"
    end
  end

  describe "nested structures" do
    test "handles deeply nested expressions" do
      # ((a + b) * c) / d
      ast =
        chunk([
          return_stmt([
            binop(
              :div,
              binop(:mul, binop(:add, var("a"), var("b")), var("c")),
              var("d")
            )
          ])
        ])

      result = PrettyPrinter.print(ast)
      assert result == "return (a + b) * c / d\n"
    end

    test "handles nested table access" do
      # a[b[c]]
      ast =
        chunk([
          return_stmt([
            index(var("a"), index(var("b"), var("c")))
          ])
        ])

      assert PrettyPrinter.print(ast) == "return a[b[c]]\n"
    end

    test "handles chained method calls" do
      # obj:method1():method2()
      ast =
        chunk([
          return_stmt([
            method_call(
              method_call(var("obj"), "method1", []),
              "method2",
              []
            )
          ])
        ])

      assert PrettyPrinter.print(ast) == "return obj:method1():method2()\n"
    end
  end

  describe "function name variations" do
    test "prints simple function name" do
      ast = chunk([func_decl("simple", [], [return_stmt([])])])
      result = PrettyPrinter.print(ast)
      assert result =~ "function simple()"
    end
  end

  describe "number formatting edge cases" do
    test "formats integer as integer" do
      ast = chunk([return_stmt([number(42)])])
      assert PrettyPrinter.print(ast) == "return 42\n"
    end

    test "formats float that equals integer with .0" do
      ast = chunk([return_stmt([number(5.0)])])
      assert PrettyPrinter.print(ast) == "return 5.0\n"
    end

    test "formats regular float normally" do
      ast = chunk([return_stmt([number(3.14159)])])
      assert PrettyPrinter.print(ast) == "return 3.14159\n"
    end

    test "formats negative numbers" do
      ast = chunk([return_stmt([number(-42)])])
      assert PrettyPrinter.print(ast) == "return -42\n"
    end
  end

  describe "precedence with various operators" do
    test "comparison operators with power" do
      # x < y ^ 2 (power has higher precedence)
      ast =
        chunk([
          return_stmt([
            binop(:lt, var("x"), binop(:pow, var("y"), number(2)))
          ])
        ])

      assert PrettyPrinter.print(ast) == "return x < y ^ 2\n"
    end

    test "equality with arithmetic" do
      # x == y + 1 (arithmetic has higher precedence)
      ast =
        chunk([
          return_stmt([
            binop(:eq, var("x"), binop(:add, var("y"), number(1)))
          ])
        ])

      assert PrettyPrinter.print(ast) == "return x == y + 1\n"
    end

    test "inequality with arithmetic" do
      # x ~= y * 2 (arithmetic has higher precedence)
      ast =
        chunk([
          return_stmt([
            binop(:ne, var("x"), binop(:mul, var("y"), number(2)))
          ])
        ])

      assert PrettyPrinter.print(ast) == "return x ~= y * 2\n"
    end

    test "less than or equal with addition" do
      # x <= y + 5 (arithmetic has higher precedence)
      ast =
        chunk([
          return_stmt([
            binop(:le, var("x"), binop(:add, var("y"), number(5)))
          ])
        ])

      assert PrettyPrinter.print(ast) == "return x <= y + 5\n"
    end

    test "greater than or equal with subtraction" do
      # x >= y - 5 (arithmetic has higher precedence)
      ast =
        chunk([
          return_stmt([
            binop(:ge, var("x"), binop(:sub, var("y"), number(5)))
          ])
        ])

      assert PrettyPrinter.print(ast) == "return x >= y - 5\n"
    end

    test "concat with comparison" do
      # (x < y) .. "test" (comparison has lower precedence than concat)
      ast =
        chunk([
          return_stmt([
            binop(:concat, binop(:lt, var("x"), var("y")), string("test"))
          ])
        ])

      assert PrettyPrinter.print(ast) == "return (x < y) .. \"test\"\n"
    end

    test "floor division with addition" do
      # (x + y) // 2 (addition has lower precedence)
      ast =
        chunk([
          return_stmt([
            binop(:floor_div, binop(:add, var("x"), var("y")), number(2))
          ])
        ])

      assert PrettyPrinter.print(ast) == "return (x + y) // 2\n"
    end

    test "modulo with addition" do
      # (x + y) % 10 (addition has lower precedence)
      ast =
        chunk([
          return_stmt([
            binop(:mod, binop(:add, var("x"), var("y")), number(10))
          ])
        ])

      assert PrettyPrinter.print(ast) == "return (x + y) % 10\n"
    end

    test "power with unary operator" do
      # 2 ^ (-x) (unary needs parens with power parent)
      ast =
        chunk([
          return_stmt([
            binop(:pow, number(2), unop(:neg, var("x")))
          ])
        ])

      assert PrettyPrinter.print(ast) == "return 2 ^ (-x)\n"
    end

    test "unary not with non-power operator" do
      # not x and y (unary has higher precedence than and)
      ast =
        chunk([
          return_stmt([
            binop(:and, unop(:not, var("x")), var("y"))
          ])
        ])

      assert PrettyPrinter.print(ast) == "return not x and y\n"
    end
  end

  describe "binary name for function declaration" do
    test "prints function with string name" do
      # When passing a simple string name (not a list)
      alias Lua.AST.Statement

      ast = %Chunk{
        block: %Block{
          stmts: [
            %Statement.FuncDecl{
              name: "simple",
              params: [],
              body: %Block{stmts: [return_stmt([])]},
              is_method: false,
              meta: nil
            }
          ]
        }
      }

      result = PrettyPrinter.print(ast)
      assert result =~ "function simple()"
    end
  end

  describe "unknown operators (defensive default cases)" do
    test "handles unknown binary operator" do
      # Create a BinOp with an invalid operator to test the default case
      alias Lua.AST.Expr

      ast = %Chunk{
        block: %Block{
          stmts: [
            return_stmt([
              %Expr.BinOp{
                op: :unknown_op,
                left: number(1),
                right: number(2),
                meta: nil
              }
            ])
          ]
        }
      }

      result = PrettyPrinter.print(ast)
      assert result =~ "<?>"
    end

    test "handles unknown unary operator" do
      # Create a UnOp with an invalid operator to test the default case
      alias Lua.AST.Expr

      ast = %Chunk{
        block: %Block{
          stmts: [
            return_stmt([
              %Expr.UnOp{
                op: :unknown_unop,
                operand: number(42),
                meta: nil
              }
            ])
          ]
        }
      }

      result = PrettyPrinter.print(ast)
      assert result =~ "<?>"
    end
  end

  describe "comment rendering" do
    test "prints single-line leading comment" do
      code = """
      -- This is a comment
      local x = 10
      """

      {:ok, ast} = Parser.parse(code)
      output = PrettyPrinter.print(ast)

      assert output =~ "-- This is a comment"
      assert output =~ "local x = 10"
    end

    test "prints single-line trailing comment" do
      code = "local x = 10  -- inline comment"

      {:ok, ast} = Parser.parse(code)
      output = PrettyPrinter.print(ast)

      assert output =~ "local x = 10  -- inline comment"
    end

    test "prints multi-line comment" do
      code = """
      --[[ This is a
      multi-line comment ]]
      local x = 10
      """

      {:ok, ast} = Parser.parse(code)
      output = PrettyPrinter.print(ast)

      assert output =~ "--[[ This is a\nmulti-line comment ]]"
      assert output =~ "local x = 10"
    end

    test "prints multiple leading comments" do
      code = """
      -- Comment 1
      -- Comment 2
      -- Comment 3
      local x = 10
      """

      {:ok, ast} = Parser.parse(code)
      output = PrettyPrinter.print(ast)

      assert output =~ "-- Comment 1"
      assert output =~ "-- Comment 2"
      assert output =~ "-- Comment 3"
      assert output =~ "local x = 10"
    end

    test "prints comments on different statement types" do
      code = """
      -- Assignment comment
      x = 10  -- trailing

      -- Return comment
      return x  -- return value
      """

      {:ok, ast} = Parser.parse(code)
      output = PrettyPrinter.print(ast)

      assert output =~ "-- Assignment comment"
      assert output =~ "x = 10  -- trailing"
      assert output =~ "-- Return comment"
      assert output =~ "return x  -- return value"
    end

    test "prints comments on function declarations" do
      code = """
      -- Define greeting function
      function greet(name)  -- takes a name parameter
        return "Hello"
      end
      """

      {:ok, ast} = Parser.parse(code)
      output = PrettyPrinter.print(ast)

      assert output =~ "-- Define greeting function"
      assert output =~ "function greet(name)"
      # Note: trailing comment may be placed inside function body
      assert output =~ "-- takes a name parameter"
    end

    test "prints comments on control structures" do
      code = """
      -- Check condition
      if x > 0 then  -- positive case
        return true
      end
      """

      {:ok, ast} = Parser.parse(code)
      output = PrettyPrinter.print(ast)

      assert output =~ "-- Check condition"
      assert output =~ "if x > 0 then"
      # Note: trailing comment may be placed inside if body
      assert output =~ "-- positive case"
    end

    test "empty comments" do
      code = "local x = 10  --\n"

      {:ok, ast} = Parser.parse(code)
      output = PrettyPrinter.print(ast)

      assert output =~ "local x = 10  --\n"
    end

    test "comments with only whitespace" do
      code = "local x = 10  --    \n"

      {:ok, ast} = Parser.parse(code)
      [stmt | _] = ast.block.stmts

      comment = Meta.get_trailing_comment(stmt.meta)
      assert comment.text == "    "
    end

    test "multiple consecutive comments" do
      code = """
      -- Line 1
      -- Line 2
      -- Line 3
      -- Line 4
      -- Line 5
      local x = 10
      """

      {:ok, ast} = Parser.parse(code)
      [stmt | _] = ast.block.stmts

      comments = Meta.get_leading_comments(stmt.meta)
      assert length(comments) == 5
    end

    test "statement without comments" do
      code = "local x = 10\n"

      {:ok, ast} = Parser.parse(code)
      [stmt | _] = ast.block.stmts

      assert Meta.get_leading_comments(stmt.meta) == []
      assert Meta.get_trailing_comment(stmt.meta) == nil
    end
  end

  describe "round-trip: parse -> print -> parse" do
    test "preserves simple statements" do
      code = "local x = 10\n"

      assert_roundtrip(code)
    end

    test "preserves statements with leading comments" do
      code = """
      -- Initialize variable
      local x = 10
      """

      assert_roundtrip_semantic(code)
    end

    test "preserves statements with trailing comments" do
      code = "local x = 10  -- ten\n"

      assert_roundtrip_semantic(code)
    end

    test "preserves statements with both leading and trailing comments" do
      code = """
      -- Set x
      local x = 10  -- to ten
      """

      assert_roundtrip_semantic(code)
    end

    test "preserves multi-line comments" do
      code = """
      --[[ This is a
      detailed comment ]]
      local x = 10
      """

      assert_roundtrip_semantic(code)
    end

    test "preserves multiple statements with comments" do
      code = """
      -- First
      local x = 10  -- x value

      -- Second
      local y = 20  -- y value

      -- Result
      return x + y  -- sum
      """

      assert_roundtrip_semantic(code)
    end

    test "preserves function with comments" do
      code = """
      -- Add two numbers
      function add(a, b)  -- parameters: a, b
        -- Calculate sum
        local result = a + b  -- addition
        -- Return result
        return result  -- final value
      end
      """

      assert_roundtrip_semantic(code)
    end

    test "preserves if statement with comments" do
      code = """
      -- Check positive
      if x > 0 then  -- test condition
        -- Positive case
        return true  -- yes
      else
        -- Negative case
        return false  -- no
      end
      """

      assert_roundtrip_semantic(code)
    end

    test "preserves while loop with comments" do
      code = """
      -- Count down
      while i > 0 do  -- loop condition
        -- Decrement
        i = i - 1  -- subtract one
      end
      """

      assert_roundtrip_semantic(code)
    end

    test "preserves for loop with comments" do
      code = """
      -- Iterate
      for i = 1, 10 do  -- from 1 to 10
        -- Process
        process(i)  -- handle item
      end
      """

      assert_roundtrip_semantic(code)
    end

    test "preserves complex nested structure with comments" do
      code = """
      -- Outer function
      function outer()  -- no params
        -- Inner function
        local function inner(x)  -- takes x
          -- Check x
          if x > 0 then  -- positive
            -- Return x
            return x  -- value
          end
        end

        -- Call inner
        return inner(10)  -- with 10
      end
      """

      assert_roundtrip_semantic(code)
    end

    test "comments between multiple statements" do
      code = """
      local x = 10

      -- Middle comment
      local y = 20

      return x + y
      """

      assert_roundtrip_semantic(code)
    end
  end

  describe "comment position preservation" do
    test "leading comments have correct positions" do
      code = """
      -- First comment
      -- Second comment
      local x = 10
      """

      {:ok, ast} = Parser.parse(code)
      [stmt | _] = ast.block.stmts

      comments = Meta.get_leading_comments(stmt.meta)
      assert length(comments) == 2

      [first, second] = comments
      assert first.position.line == 1
      assert first.text == " First comment"
      assert second.position.line == 2
      assert second.text == " Second comment"
    end

    test "trailing comments have correct positions" do
      code = "local x = 10  -- inline\n"

      {:ok, ast} = Parser.parse(code)
      [stmt | _] = ast.block.stmts

      comment = Meta.get_trailing_comment(stmt.meta)
      assert comment
      assert comment.position.line == 1
      assert comment.text == " inline"
    end

    test "comment text is preserved exactly" do
      code = "local x = 10  -- special chars: !@#$%\n"

      {:ok, ast} = Parser.parse(code)
      [stmt | _] = ast.block.stmts

      comment = Meta.get_trailing_comment(stmt.meta)
      assert comment.text == " special chars: !@#$%"
    end
  end

  # Helpers for round-trip testing

  # Assert exact round-trip (character-for-character)
  defp assert_roundtrip(code) do
    {:ok, ast1} = Parser.parse(code)
    printed = PrettyPrinter.print(ast1)
    {:ok, ast2} = Parser.parse(printed)

    # Compare printed output
    assert printed == code, """
    Round-trip failed: output doesn't match input

    Input:
    #{code}

    Output:
    #{printed}
    """

    # Verify ASTs are equivalent
    assert ast1 == ast2
  end

  # Assert semantic round-trip (same AST structure)
  defp assert_roundtrip_semantic(code) do
    {:ok, ast1} = Parser.parse(code)
    printed = PrettyPrinter.print(ast1)
    {:ok, ast2} = Parser.parse(printed)

    # Verify comments are preserved (text content, not exact positioning)
    assert_comments_preserved(ast1, ast2)

    # Verify code can be parsed again after printing
    assert match?({:ok, _}, Parser.parse(printed)), """
    Printed code could not be parsed

    Printed:
    #{printed}
    """
  end

  # Verify comments are preserved through round-trip
  defp assert_comments_preserved(ast1, ast2) do
    comments1 = extract_all_comments(ast1)
    comments2 = extract_all_comments(ast2)

    # Compare comment text (positions may differ due to formatting)
    texts1 = comments1 |> Enum.map(& &1.text) |> Enum.sort()
    texts2 = comments2 |> Enum.map(& &1.text) |> Enum.sort()

    assert texts1 == texts2, """
    Comments not preserved through round-trip

    Original comments: #{inspect(texts1)}
    After round-trip: #{inspect(texts2)}
    """
  end

  # Extract all comments from an AST
  defp extract_all_comments(node, acc \\ [])

  defp extract_all_comments(%{meta: meta} = node, acc) when is_struct(node) and not is_nil(meta) do
    leading = Meta.get_leading_comments(meta)
    trailing = Meta.get_trailing_comment(meta)
    trailing_list = if trailing, do: [trailing], else: []

    node_comments = leading ++ trailing_list

    # Recurse into child nodes
    children_comments =
      node
      |> Map.from_struct()
      |> Map.values()
      |> Enum.flat_map(&extract_all_comments_from_value/1)

    acc ++ node_comments ++ children_comments
  end

  defp extract_all_comments(node, acc) when is_struct(node) do
    # Node without meta, recurse into children
    children_comments =
      node
      |> Map.from_struct()
      |> Map.values()
      |> Enum.flat_map(&extract_all_comments_from_value/1)

    acc ++ children_comments
  end

  defp extract_all_comments(_node, acc), do: acc

  defp extract_all_comments_from_value(value) when is_list(value) do
    Enum.flat_map(value, &extract_all_comments(&1, []))
  end

  defp extract_all_comments_from_value(value) when is_struct(value) do
    extract_all_comments(value, [])
  end

  defp extract_all_comments_from_value(_value), do: []
end

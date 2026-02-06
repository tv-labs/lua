defmodule Lua.Parser.StatementTest do
  use ExUnit.Case, async: true
  alias Lua.Parser
  alias Lua.AST.{Statement, Expr}

  describe "local variable declarations" do
    test "parses local without initialization" do
      assert {:ok, chunk} = Parser.parse("local x")
      assert %{block: %{stmts: [%Statement.Local{names: ["x"], values: []}]}} = chunk
    end

    test "parses local with single initialization" do
      assert {:ok, chunk} = Parser.parse("local x = 42")

      assert %{
               block: %{
                 stmts: [%Statement.Local{names: ["x"], values: [%Expr.Number{value: 42}]}]
               }
             } = chunk
    end

    test "parses local with multiple variables" do
      assert {:ok, chunk} = Parser.parse("local x, y, z = 1, 2, 3")

      assert %{
               block: %{
                 stmts: [
                   %Statement.Local{
                     names: ["x", "y", "z"],
                     values: [
                       %Expr.Number{value: 1},
                       %Expr.Number{value: 2},
                       %Expr.Number{value: 3}
                     ]
                   }
                 ]
               }
             } = chunk
    end

    test "parses local function" do
      assert {:ok, chunk} =
               Parser.parse("""
               local function add(a, b)
                 return a + b
               end
               """)

      assert %{block: %{stmts: [%Statement.LocalFunc{name: "add", params: ["a", "b"]}]}} = chunk
    end
  end

  describe "assignments" do
    test "parses simple assignment" do
      assert {:ok, chunk} = Parser.parse("x = 42")

      assert %{
               block: %{
                 stmts: [
                   %Statement.Assign{
                     targets: [%Expr.Var{name: "x"}],
                     values: [%Expr.Number{value: 42}]
                   }
                 ]
               }
             } = chunk
    end

    test "parses multiple assignment" do
      assert {:ok, chunk} = Parser.parse("x, y = 1, 2")

      assert %{
               block: %{
                 stmts: [
                   %Statement.Assign{
                     targets: [%Expr.Var{name: "x"}, %Expr.Var{name: "y"}],
                     values: [%Expr.Number{value: 1}, %Expr.Number{value: 2}]
                   }
                 ]
               }
             } = chunk
    end

    test "parses table field assignment" do
      assert {:ok, chunk} = Parser.parse("t.field = 42")

      assert %{
               block: %{
                 stmts: [
                   %Statement.Assign{
                     targets: [%Expr.Property{}],
                     values: [%Expr.Number{value: 42}]
                   }
                 ]
               }
             } = chunk
    end

    test "parses indexed assignment" do
      assert {:ok, chunk} = Parser.parse("t[1] = 42")

      assert %{
               block: %{
                 stmts: [
                   %Statement.Assign{
                     targets: [%Expr.Index{}],
                     values: [%Expr.Number{value: 42}]
                   }
                 ]
               }
             } = chunk
    end
  end

  describe "function calls as statements" do
    test "parses function call statement" do
      assert {:ok, chunk} = Parser.parse("print(42)")

      assert %{
               block: %{
                 stmts: [%Statement.CallStmt{call: %Expr.Call{func: %Expr.Var{name: "print"}}}]
               }
             } = chunk
    end

    test "parses method call statement" do
      assert {:ok, chunk} = Parser.parse("obj:method()")

      assert %{
               block: %{stmts: [%Statement.CallStmt{call: %Expr.MethodCall{method: "method"}}]}
             } = chunk
    end
  end

  describe "if statements" do
    test "parses simple if statement" do
      assert {:ok, chunk} =
               Parser.parse("""
               if x > 0 then
                 return x
               end
               """)

      assert %{
               block: %{
                 stmts: [
                   %Statement.If{
                     condition: %Expr.BinOp{op: :gt},
                     then_block: %{stmts: [%Statement.Return{}]},
                     elseifs: [],
                     else_block: nil
                   }
                 ]
               }
             } = chunk
    end

    test "parses if with else" do
      assert {:ok, chunk} =
               Parser.parse("""
               if x > 0 then
                 return x
               else
                 return 0
               end
               """)

      assert %{
               block: %{
                 stmts: [
                   %Statement.If{
                     condition: %Expr.BinOp{op: :gt},
                     then_block: %{stmts: [%Statement.Return{}]},
                     elseifs: [],
                     else_block: %{stmts: [%Statement.Return{}]}
                   }
                 ]
               }
             } = chunk
    end

    test "parses if with elseif" do
      assert {:ok, chunk} =
               Parser.parse("""
               if x > 0 then
                 return 1
               elseif x < 0 then
                 return -1
               else
                 return 0
               end
               """)

      assert %{
               block: %{
                 stmts: [
                   %Statement.If{
                     condition: %Expr.BinOp{op: :gt},
                     then_block: %{stmts: [%Statement.Return{}]},
                     elseifs: [{%Expr.BinOp{op: :lt}, %{stmts: [%Statement.Return{}]}}],
                     else_block: %{stmts: [%Statement.Return{}]}
                   }
                 ]
               }
             } = chunk
    end

    test "parses if with multiple elseifs" do
      assert {:ok, chunk} =
               Parser.parse("""
               if x == 1 then
                 return "one"
               elseif x == 2 then
                 return "two"
               elseif x == 3 then
                 return "three"
               end
               """)

      assert %{
               block: %{
                 stmts: [
                   %Statement.If{
                     elseifs: [_, _]
                   }
                 ]
               }
             } = chunk
    end
  end

  describe "while loops" do
    test "parses while loop" do
      assert {:ok, chunk} =
               Parser.parse("""
               while x > 0 do
                 x = x - 1
               end
               """)

      assert %{
               block: %{
                 stmts: [
                   %Statement.While{
                     condition: %Expr.BinOp{op: :gt},
                     body: %{stmts: [%Statement.Assign{}]}
                   }
                 ]
               }
             } = chunk
    end
  end

  describe "repeat-until loops" do
    test "parses repeat-until loop" do
      assert {:ok, chunk} =
               Parser.parse("""
               repeat
                 x = x - 1
               until x == 0
               """)

      assert %{
               block: %{
                 stmts: [
                   %Statement.Repeat{
                     body: %{stmts: [%Statement.Assign{}]},
                     condition: %Expr.BinOp{op: :eq}
                   }
                 ]
               }
             } = chunk
    end
  end

  describe "for loops" do
    test "parses numeric for loop" do
      assert {:ok, chunk} =
               Parser.parse("""
               for i = 1, 10 do
                 print(i)
               end
               """)

      assert %{
               block: %{
                 stmts: [
                   %Statement.ForNum{
                     var: "i",
                     start: %Expr.Number{value: 1},
                     limit: %Expr.Number{value: 10},
                     step: nil,
                     body: %{stmts: [%Statement.CallStmt{}]}
                   }
                 ]
               }
             } = chunk
    end

    test "parses numeric for loop with step" do
      assert {:ok, chunk} =
               Parser.parse("""
               for i = 1, 10, 2 do
                 print(i)
               end
               """)

      assert %{
               block: %{
                 stmts: [
                   %Statement.ForNum{
                     var: "i",
                     start: %Expr.Number{value: 1},
                     limit: %Expr.Number{value: 10},
                     step: %Expr.Number{value: 2}
                   }
                 ]
               }
             } = chunk
    end

    test "parses generic for loop" do
      assert {:ok, chunk} =
               Parser.parse("""
               for k, v in pairs(t) do
                 print(k, v)
               end
               """)

      assert %{
               block: %{
                 stmts: [
                   %Statement.ForIn{
                     vars: ["k", "v"],
                     iterators: [%Expr.Call{}],
                     body: %{stmts: [%Statement.CallStmt{}]}
                   }
                 ]
               }
             } = chunk
    end

    test "parses generic for loop with single variable" do
      assert {:ok, chunk} =
               Parser.parse("""
               for line in io.lines() do
                 print(line)
               end
               """)

      assert %{
               block: %{
                 stmts: [
                   %Statement.ForIn{
                     vars: ["line"],
                     iterators: [%Expr.Call{func: %Expr.Property{}}]
                   }
                 ]
               }
             } = chunk
    end
  end

  describe "function declarations" do
    test "parses simple function declaration" do
      assert {:ok, chunk} =
               Parser.parse("""
               function add(a, b)
                 return a + b
               end
               """)

      assert %{
               block: %{
                 stmts: [
                   %Statement.FuncDecl{
                     name: ["add"],
                     params: ["a", "b"],
                     is_method: false,
                     body: %{stmts: [%Statement.Return{}]}
                   }
                 ]
               }
             } = chunk
    end

    test "parses function declaration with dot notation" do
      assert {:ok, chunk} =
               Parser.parse("""
               function math.abs(x)
                 return x
               end
               """)

      assert %{
               block: %{
                 stmts: [
                   %Statement.FuncDecl{
                     name: ["math", "abs"],
                     is_method: false
                   }
                 ]
               }
             } = chunk
    end

    test "parses method declaration" do
      assert {:ok, chunk} =
               Parser.parse("""
               function obj:method(x)
                 return self.field + x
               end
               """)

      assert %{
               block: %{
                 stmts: [
                   %Statement.FuncDecl{
                     name: ["obj", "method"],
                     is_method: true,
                     params: ["x"]
                   }
                 ]
               }
             } = chunk
    end

    test "parses nested function name" do
      assert {:ok, chunk} =
               Parser.parse("""
               function a.b.c.d()
               end
               """)

      assert %{
               block: %{
                 stmts: [
                   %Statement.FuncDecl{
                     name: ["a", "b", "c", "d"],
                     is_method: false
                   }
                 ]
               }
             } = chunk
    end
  end

  describe "do blocks" do
    test "parses do block" do
      assert {:ok, chunk} =
               Parser.parse("""
               do
                 local x = 42
                 print(x)
               end
               """)

      assert %{
               block: %{
                 stmts: [
                   %Statement.Do{
                     body: %{stmts: [%Statement.Local{}, %Statement.CallStmt{}]}
                   }
                 ]
               }
             } = chunk
    end
  end

  describe "break and goto" do
    test "parses break" do
      assert {:ok, chunk} = Parser.parse("break")
      assert %{block: %{stmts: [%Statement.Break{}]}} = chunk
    end

    test "parses goto" do
      assert {:ok, chunk} = Parser.parse("goto finish")
      assert %{block: %{stmts: [%Statement.Goto{label: "finish"}]}} = chunk
    end

    test "parses label" do
      assert {:ok, chunk} = Parser.parse("::finish::")
      assert %{block: %{stmts: [%Statement.Label{name: "finish"}]}} = chunk
    end

    test "parses goto and label together" do
      assert {:ok, chunk} =
               Parser.parse("""
               goto skip
               print("skipped")
               ::skip::
               print("not skipped")
               """)

      assert %{
               block: %{
                 stmts: [
                   %Statement.Goto{label: "skip"},
                   %Statement.CallStmt{},
                   %Statement.Label{name: "skip"},
                   %Statement.CallStmt{}
                 ]
               }
             } = chunk
    end
  end

  describe "return statements" do
    test "parses return with no values" do
      assert {:ok, chunk} = Parser.parse("return")
      assert %{block: %{stmts: [%Statement.Return{values: []}]}} = chunk
    end

    test "parses return with single value" do
      assert {:ok, chunk} = Parser.parse("return 42")

      assert %{
               block: %{stmts: [%Statement.Return{values: [%Expr.Number{value: 42}]}]}
             } = chunk
    end

    test "parses return with multiple values" do
      assert {:ok, chunk} = Parser.parse("return 1, 2, 3")

      assert %{
               block: %{
                 stmts: [
                   %Statement.Return{
                     values: [
                       %Expr.Number{value: 1},
                       %Expr.Number{value: 2},
                       %Expr.Number{value: 3}
                     ]
                   }
                 ]
               }
             } = chunk
    end
  end

  describe "complex programs" do
    test "parses factorial function" do
      assert {:ok, chunk} =
               Parser.parse("""
               function factorial(n)
                 if n <= 1 then
                   return 1
                 else
                   return n * factorial(n - 1)
                 end
               end
               """)

      assert %{block: %{stmts: [%Statement.FuncDecl{name: ["factorial"]}]}} = chunk
    end

    test "parses multiple statements" do
      assert {:ok, chunk} =
               Parser.parse("""
               local x = 10
               local y = 20
               local sum = x + y
               print(sum)
               """)

      assert %{
               block: %{
                 stmts: [
                   %Statement.Local{names: ["x"]},
                   %Statement.Local{names: ["y"]},
                   %Statement.Local{names: ["sum"]},
                   %Statement.CallStmt{}
                 ]
               }
             } = chunk
    end

    test "parses nested control structures" do
      assert {:ok, _chunk} =
               Parser.parse("""
               for i = 1, 10 do
                 if i % 2 == 0 then
                   print("even")
                 else
                   print("odd")
                 end
               end
               """)
    end
  end
end

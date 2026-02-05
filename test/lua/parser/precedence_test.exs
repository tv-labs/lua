defmodule Lua.Parser.PrecedenceTest do
  use ExUnit.Case, async: true
  alias Lua.Parser
  alias Lua.AST.Expr

  describe "operator precedence" do
    test "or has lowest precedence" do
      assert {:ok, %{block: %{stmts: [stmt]}}} = Parser.parse("return a and b or c and d")

      # Should parse as: (a and b) or (c and d)
      assert %{
               values: [
                 %Expr.BinOp{
                   op: :or,
                   left: %Expr.BinOp{op: :and},
                   right: %Expr.BinOp{op: :and}
                 }
               ]
             } = stmt
    end

    test "and has higher precedence than or" do
      assert {:ok, %{block: %{stmts: [stmt]}}} = Parser.parse("return a or b and c")

      # Should parse as: a or (b and c)
      assert %{
               values: [
                 %Expr.BinOp{
                   op: :or,
                   left: %Expr.Var{name: "a"},
                   right: %Expr.BinOp{op: :and}
                 }
               ]
             } = stmt
    end

    test "comparison has higher precedence than logical" do
      assert {:ok, %{block: %{stmts: [stmt]}}} = Parser.parse("return a < b and c > d")

      # Should parse as: (a < b) and (c > d)
      assert %{
               values: [
                 %Expr.BinOp{
                   op: :and,
                   left: %Expr.BinOp{op: :lt},
                   right: %Expr.BinOp{op: :gt}
                 }
               ]
             } = stmt
    end

    test "concatenation has higher precedence than comparison" do
      assert {:ok, %{block: %{stmts: [stmt]}}} = Parser.parse(~s(return "a" .. "b" < "c" .. "d"))

      # Should parse as: ("a" .. "b") < ("c" .. "d")
      assert %{
               values: [
                 %Expr.BinOp{
                   op: :lt,
                   left: %Expr.BinOp{op: :concat},
                   right: %Expr.BinOp{op: :concat}
                 }
               ]
             } = stmt
    end

    test "addition has higher precedence than concatenation" do
      assert {:ok, %{block: %{stmts: [stmt]}}} = Parser.parse("return a + b .. c + d")

      # Should parse as: (a + b) .. (c + d)
      assert %{
               values: [
                 %Expr.BinOp{
                   op: :concat,
                   left: %Expr.BinOp{op: :add},
                   right: %Expr.BinOp{op: :add}
                 }
               ]
             } = stmt
    end

    test "multiplication has higher precedence than addition" do
      assert {:ok, %{block: %{stmts: [stmt]}}} = Parser.parse("return a + b * c")

      # Should parse as: a + (b * c)
      assert %{
               values: [
                 %Expr.BinOp{
                   op: :add,
                   left: %Expr.Var{name: "a"},
                   right: %Expr.BinOp{op: :mul}
                 }
               ]
             } = stmt
    end

    test "unary has higher precedence than multiplication" do
      assert {:ok, %{block: %{stmts: [stmt]}}} = Parser.parse("return -a * b")

      # Should parse as: (-a) * b
      assert %{
               values: [
                 %Expr.BinOp{
                   op: :mul,
                   left: %Expr.UnOp{op: :neg},
                   right: %Expr.Var{name: "b"}
                 }
               ]
             } = stmt
    end

    test "power has higher precedence than unary (special case)" do
      # In Lua, -2^3 = -(2^3) = -8, not (-2)^3
      assert {:ok, %{block: %{stmts: [stmt]}}} = Parser.parse("return -2 ^ 3")

      # Should parse as: -(2 ^ 3)
      assert %{
               values: [
                 %Expr.UnOp{
                   op: :neg,
                   operand: %Expr.BinOp{op: :pow}
                 }
               ]
             } = stmt
    end

    test "not has higher precedence than and" do
      assert {:ok, %{block: %{stmts: [stmt]}}} = Parser.parse("return not a and b")

      # Should parse as: (not a) and b
      assert %{
               values: [
                 %Expr.BinOp{
                   op: :and,
                   left: %Expr.UnOp{op: :not},
                   right: %Expr.Var{name: "b"}
                 }
               ]
             } = stmt
    end

    test "length operator has same precedence as unary minus" do
      assert {:ok, %{block: %{stmts: [stmt]}}} = Parser.parse("return #t + 1")

      # Should parse as: (#t) + 1
      assert %{
               values: [
                 %Expr.BinOp{
                   op: :add,
                   left: %Expr.UnOp{op: :len},
                   right: %Expr.Number{value: 1}
                 }
               ]
             } = stmt
    end
  end

  describe "associativity" do
    test "addition is left associative" do
      assert {:ok, %{block: %{stmts: [stmt]}}} = Parser.parse("return 1 + 2 + 3")

      # Should parse as: (1 + 2) + 3
      assert %{
               values: [
                 %Expr.BinOp{
                   op: :add,
                   left: %Expr.BinOp{
                     op: :add,
                     left: %Expr.Number{value: 1},
                     right: %Expr.Number{value: 2}
                   },
                   right: %Expr.Number{value: 3}
                 }
               ]
             } = stmt
    end

    test "subtraction is left associative" do
      assert {:ok, %{block: %{stmts: [stmt]}}} = Parser.parse("return 10 - 5 - 2")

      # Should parse as: (10 - 5) - 2 = 3
      assert %{
               values: [
                 %Expr.BinOp{
                   op: :sub,
                   left: %Expr.BinOp{op: :sub},
                   right: %Expr.Number{value: 2}
                 }
               ]
             } = stmt
    end

    test "multiplication is left associative" do
      assert {:ok, %{block: %{stmts: [stmt]}}} = Parser.parse("return 2 * 3 * 4")

      # Should parse as: (2 * 3) * 4
      assert %{
               values: [
                 %Expr.BinOp{
                   op: :mul,
                   left: %Expr.BinOp{op: :mul},
                   right: %Expr.Number{value: 4}
                 }
               ]
             } = stmt
    end

    test "division is left associative" do
      assert {:ok, %{block: %{stmts: [stmt]}}} = Parser.parse("return 24 / 4 / 2")

      # Should parse as: (24 / 4) / 2 = 3
      assert %{
               values: [
                 %Expr.BinOp{
                   op: :div,
                   left: %Expr.BinOp{op: :div},
                   right: %Expr.Number{value: 2}
                 }
               ]
             } = stmt
    end

    test "power is right associative" do
      assert {:ok, %{block: %{stmts: [stmt]}}} = Parser.parse("return 2 ^ 3 ^ 2")

      # Should parse as: 2 ^ (3 ^ 2) = 2 ^ 9 = 512
      assert %{
               values: [
                 %Expr.BinOp{
                   op: :pow,
                   left: %Expr.Number{value: 2},
                   right: %Expr.BinOp{
                     op: :pow,
                     left: %Expr.Number{value: 3},
                     right: %Expr.Number{value: 2}
                   }
                 }
               ]
             } = stmt
    end

    test "concatenation is right associative" do
      assert {:ok, %{block: %{stmts: [stmt]}}} = Parser.parse(~s(return "a" .. "b" .. "c"))

      # Should parse as: "a" .. ("b" .. "c")
      assert %{
               values: [
                 %Expr.BinOp{
                   op: :concat,
                   left: %Expr.String{value: "a"},
                   right: %Expr.BinOp{
                     op: :concat,
                     left: %Expr.String{value: "b"},
                     right: %Expr.String{value: "c"}
                   }
                 }
               ]
             } = stmt
    end

    test "and is left associative" do
      assert {:ok, %{block: %{stmts: [stmt]}}} = Parser.parse("return a and b and c")

      # Should parse as: (a and b) and c
      assert %{
               values: [
                 %Expr.BinOp{
                   op: :and,
                   left: %Expr.BinOp{op: :and},
                   right: %Expr.Var{name: "c"}
                 }
               ]
             } = stmt
    end

    test "or is left associative" do
      assert {:ok, %{block: %{stmts: [stmt]}}} = Parser.parse("return a or b or c")

      # Should parse as: (a or b) or c
      assert %{
               values: [
                 %Expr.BinOp{
                   op: :or,
                   left: %Expr.BinOp{op: :or},
                   right: %Expr.Var{name: "c"}
                 }
               ]
             } = stmt
    end

    test "comparison is left associative" do
      assert {:ok, %{block: %{stmts: [stmt]}}} = Parser.parse("return 1 < 2 < 3")

      # Should parse as: (1 < 2) < 3
      # Note: This is legal in Lua but semantically weird (compares boolean with number)
      assert %{
               values: [
                 %Expr.BinOp{
                   op: :lt,
                   left: %Expr.BinOp{op: :lt},
                   right: %Expr.Number{value: 3}
                 }
               ]
             } = stmt
    end
  end

  describe "complex precedence cases" do
    test "all operators with correct precedence" do
      # a or b and c < d .. e + f * g ^ h
      # Should parse as: a or (b and (c < (d .. (e + (f * (g ^ h))))))
      assert {:ok, %{block: %{stmts: [stmt]}}} = Parser.parse("return a or b and c < d .. e + f * g ^ h")

      assert %{
               values: [
                 %Expr.BinOp{
                   op: :or,
                   left: %Expr.Var{name: "a"},
                   right: %Expr.BinOp{
                     op: :and,
                     left: %Expr.Var{name: "b"},
                     right: %Expr.BinOp{
                       op: :lt,
                       left: %Expr.Var{name: "c"},
                       right: %Expr.BinOp{
                         op: :concat,
                         left: %Expr.Var{name: "d"},
                         right: %Expr.BinOp{
                           op: :add,
                           left: %Expr.Var{name: "e"},
                           right: %Expr.BinOp{
                             op: :mul,
                             left: %Expr.Var{name: "f"},
                             right: %Expr.BinOp{
                               op: :pow,
                               left: %Expr.Var{name: "g"},
                               right: %Expr.Var{name: "h"}
                             }
                           }
                         }
                       }
                     }
                   }
                 }
               ]
             } = stmt
    end

    test "unary operators with various binary operators" do
      assert {:ok, %{block: %{stmts: [stmt]}}} = Parser.parse("return not a or -b and #c")

      # Should parse as: (not a) or ((-b) and (#c))
      assert %{
               values: [
                 %Expr.BinOp{
                   op: :or,
                   left: %Expr.UnOp{op: :not},
                   right: %Expr.BinOp{
                     op: :and,
                     left: %Expr.UnOp{op: :neg},
                     right: %Expr.UnOp{op: :len}
                   }
                 }
               ]
             } = stmt
    end

    test "mixed arithmetic with different precedences" do
      assert {:ok, %{block: %{stmts: [stmt]}}} = Parser.parse("return 1 + 2 * 3 - 4 / 5 % 6")

      # Should parse as: (1 + (2 * 3)) - ((4 / 5) % 6)
      # With left associativity: ((1 + (2 * 3)) - ((4 / 5) % 6))
      # *, /, % have same precedence, so (4 / 5) % 6 parses left-to-right
      # +, - have same precedence, so the top level is: (...) - (...)
      assert %{values: [%Expr.BinOp{op: :sub}]} = stmt
    end
  end

  describe "parentheses override precedence" do
    test "parentheses around addition before multiplication" do
      assert {:ok, %{block: %{stmts: [stmt]}}} = Parser.parse("return (1 + 2) * 3")

      # Should parse as: (1 + 2) * 3
      assert %{
               values: [
                 %Expr.BinOp{
                   op: :mul,
                   left: %Expr.BinOp{op: :add},
                   right: %Expr.Number{value: 3}
                 }
               ]
             } = stmt
    end

    test "parentheses around or before and" do
      assert {:ok, %{block: %{stmts: [stmt]}}} = Parser.parse("return (a or b) and c")

      # Should parse as: (a or b) and c
      assert %{
               values: [
                 %Expr.BinOp{
                   op: :and,
                   left: %Expr.BinOp{op: :or},
                   right: %Expr.Var{name: "c"}
                 }
               ]
             } = stmt
    end

    test "nested parentheses" do
      assert {:ok, %{block: %{stmts: [stmt]}}} = Parser.parse("return ((1 + 2) * 3) + 4")

      # Should parse as: ((1 + 2) * 3) + 4
      assert %{
               values: [
                 %Expr.BinOp{
                   op: :add,
                   left: %Expr.BinOp{
                     op: :mul,
                     left: %Expr.BinOp{op: :add},
                     right: %Expr.Number{value: 3}
                   },
                   right: %Expr.Number{value: 4}
                 }
               ]
             } = stmt
    end
  end
end

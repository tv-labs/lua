defmodule Lua.Parser.ExprTest do
  use ExUnit.Case, async: true

  alias Lua.AST.Expr
  alias Lua.AST.Statement
  alias Lua.Parser

  # Helper to extract the returned expression from "return expr"
  defp parse_return_expr(code) do
    case Parser.parse(code) do
      {:ok, %{block: %{stmts: [%Statement.Return{values: [expr]}]}}} ->
        {:ok, expr}

      {:ok, %{block: %{stmts: [%Statement.Return{values: exprs}]}}} ->
        {:ok, exprs}

      other ->
        other
    end
  end

  describe "basic parsing" do
    test "parses simple expressions" do
      assert {:ok, %Expr.Number{value: 42}} = parse_return_expr("return 42")
      assert {:ok, %Expr.Bool{value: true}} = parse_return_expr("return true")
      assert {:ok, %Expr.String{value: "hello"}} = parse_return_expr(~s(return "hello"))
      assert {:ok, %Expr.Nil{}} = parse_return_expr("return nil")
      assert {:ok, %Expr.Var{name: "x"}} = parse_return_expr("return x")
    end

    test "parses binary operations" do
      assert {:ok, %Expr.BinOp{op: :add}} = parse_return_expr("return 1 + 2")
      assert {:ok, %Expr.BinOp{op: :mul}} = parse_return_expr("return 2 * 3")
      assert {:ok, %Expr.BinOp{op: :concat}} = parse_return_expr(~s(return "a" .. "b"))
    end

    test "parses unary operations" do
      assert {:ok, %Expr.UnOp{op: :not}} = parse_return_expr("return not true")
      assert {:ok, %Expr.UnOp{op: :neg}} = parse_return_expr("return -5")
      assert {:ok, %Expr.UnOp{op: :len}} = parse_return_expr("return #t")
    end

    test "parses table constructors" do
      assert {:ok, %Expr.Table{fields: []}} = parse_return_expr("return {}")
      assert {:ok, %Expr.Table{fields: [_, _, _]}} = parse_return_expr("return {1, 2, 3}")
      assert {:ok, %Expr.Table{}} = parse_return_expr("return {a = 1, b = 2}")
    end

    test "parses function expressions" do
      assert {:ok, %Expr.Function{params: []}} =
               parse_return_expr("return function() end")

      assert {:ok, %Expr.Function{params: ["a", "b"]}} =
               parse_return_expr("return function(a, b) end")

      assert {:ok, %Expr.Function{params: ["a", :vararg]}} =
               parse_return_expr("return function(a, ...) end")
    end

    test "parses function calls" do
      assert {:ok, %Expr.Call{func: %Expr.Var{name: "f"}, args: []}} =
               parse_return_expr("return f()")

      assert {:ok, %Expr.Call{args: [_, _, _]}} = parse_return_expr("return f(1, 2, 3)")
    end

    test "parses property access and indexing" do
      assert {:ok, %Expr.Property{table: %Expr.Var{name: "t"}, field: "field"}} =
               parse_return_expr("return t.field")

      assert {:ok, %Expr.Index{table: %Expr.Var{name: "t"}}} =
               parse_return_expr("return t[1]")
    end

    test "parses method calls" do
      assert {:ok, %Expr.MethodCall{object: %Expr.Var{name: "obj"}, method: "method"}} =
               parse_return_expr("return obj:method()")
    end

    test "parses complex nested expressions" do
      assert {:ok, _} = parse_return_expr("return 1 + 2 * 3")
      assert {:ok, _} = parse_return_expr("return (1 + 2) * 3")
      assert {:ok, _} = parse_return_expr("return f(g(h(x)))")
      assert {:ok, _} = parse_return_expr("return t.a.b.c")
    end
  end

  describe "function call syntactic sugar" do
    test "parses function call with string literal" do
      # f "str" is syntactic sugar for f("str")
      assert {:ok, %Expr.Call{func: %Expr.Var{name: "f"}, args: [%Expr.String{value: "hello"}]}} =
               parse_return_expr(~s(return f "hello"))

      # Works with require pattern
      assert {:ok, %Expr.Call{func: %Expr.Var{name: "require"}, args: [%Expr.String{value: "debug"}]}} =
               parse_return_expr(~s(return require "debug"))
    end

    test "parses function call with long string literal" do
      # f [[str]] is syntactic sugar for f([[str]])
      assert {:ok, %Expr.Call{func: %Expr.Var{name: "load"}, args: [%Expr.String{value: "return 1 + 2"}]}} =
               parse_return_expr("return load[[return 1 + 2]]")
    end

    test "parses function call with table constructor" do
      # f{...} is syntactic sugar for f({...})
      assert {:ok, %Expr.Call{func: %Expr.Var{name: "f"}, args: [%Expr.Table{fields: []}]}} =
               parse_return_expr("return f{}")

      assert {:ok, %Expr.Call{func: %Expr.Var{name: "print"}, args: [%Expr.Table{fields: [_, _, _]}]}} =
               parse_return_expr("return print{1, 2, 3}")

      assert {:ok, %Expr.Call{func: %Expr.Var{name: "config"}, args: [%Expr.Table{}]}} =
               parse_return_expr("return config{a = 1, b = 2}")
    end

    test "parses chained function calls with syntactic sugar" do
      # Can chain multiple calls
      assert {:ok, %Expr.Call{}} = parse_return_expr(~s(return f "a" "b"))

      # Can mix syntactic sugar with regular calls
      assert {:ok, %Expr.Call{}} = parse_return_expr(~s[return f "a"(x)])
    end

    test "parses method calls with syntactic sugar" do
      # obj:method "str" is valid
      assert {:ok, %Expr.MethodCall{object: %Expr.Var{name: "obj"}, method: "m"}} =
               parse_return_expr(~s(return obj:m "hello"))

      # obj:method{} is valid
      assert {:ok, %Expr.MethodCall{object: %Expr.Var{name: "obj"}, method: "m"}} =
               parse_return_expr("return obj:m{1, 2}")
    end
  end

  describe "comments in expressions" do
    test "parses comments before expressions" do
      code = """
      return -- comment
      42
      """

      assert {:ok, %Expr.Number{value: 42}} = parse_return_expr(code)
    end

    test "parses comments in binary expressions" do
      code = """
      return 1 + -- comment
      2
      """

      assert {:ok, %Expr.BinOp{op: :add}} = parse_return_expr(code)
    end

    test "parses comments after operators" do
      code = """
      return f(1,2,'a')
      ~=          -- force SETLINE before nil
      nil
      """

      assert {:ok, %Expr.BinOp{op: :ne}} = parse_return_expr(code)
    end

    test "parses multiple comments in complex expressions" do
      code = """
      return (1 + -- comment 1
      2) * -- comment 2
      3
      """

      assert {:ok, %Expr.BinOp{op: :mul}} = parse_return_expr(code)
    end
  end
end

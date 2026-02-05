defmodule Lua.Parser.ExprTest do
  use ExUnit.Case, async: true
  alias Lua.Parser
  alias Lua.AST.{Expr, Stmt}

  # Helper to extract the returned expression from "return expr"
  defp parse_return_expr(code) do
    case Parser.parse(code) do
      {:ok, %{block: %{stmts: [%Stmt.Return{values: [expr]}]}}} ->
        {:ok, expr}

      {:ok, %{block: %{stmts: [%Stmt.Return{values: exprs}]}}} ->
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
end

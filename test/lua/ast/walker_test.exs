defmodule Lua.AST.WalkerTest do
  use ExUnit.Case, async: true

  import Lua.AST.Builder
  alias Lua.AST.{Walker, Expr, Stmt}

  describe "walk/2" do
    test "visits all nodes in pre-order" do
      # Build: local x = 2 + 3
      ast = chunk([
        local(["x"], [binop(:add, number(2), number(3))])
      ])

      visited = []
      ref = :erlang.make_ref()

      Walker.walk(ast, fn node ->
        send(self(), {ref, node})
      end)

      # Collect all visited nodes
      visited = collect_messages(ref, [])

      # Should visit in pre-order: Chunk, Block, Local, BinOp, Number(2), Number(3)
      assert length(visited) == 6
      assert hd(visited).__struct__ == Lua.AST.Chunk
    end

    test "visits all nodes in post-order" do
      # Build: local x = 2 + 3
      ast = chunk([
        local(["x"], [binop(:add, number(2), number(3))])
      ])

      visited = []
      ref = :erlang.make_ref()

      Walker.walk(ast, fn node ->
        send(self(), {ref, node})
      end, order: :post)

      visited = collect_messages(ref, [])

      # Should visit in post-order: children before parents
      # Last visited should be Chunk
      assert length(visited) == 6
      assert List.last(visited).__struct__ == Lua.AST.Chunk
    end

    test "walks through if statement with all branches" do
      # if x > 0 then return 1 elseif x < 0 then return -1 else return 0 end
      ast = chunk([
        if_stmt(
          binop(:gt, var("x"), number(0)),
          [return_stmt([number(1)])],
          elseif: [{binop(:lt, var("x"), number(0)), [return_stmt([unop(:neg, number(1))])]}],
          else: [return_stmt([number(0)])]
        )
      ])

      count = count_nodes(ast)
      # Chunk + Block + If + 3 conditions + 3 blocks + 3 return stmts + 3 values = many nodes
      assert count > 10
    end

    test "walks through function expressions" do
      # local f = function(a, b) return a + b end
      ast = chunk([
        local(["f"], [function_expr(["a", "b"], [
          return_stmt([binop(:add, var("a"), var("b"))])
        ])])
      ])

      # Count variable references
      var_count = Walker.reduce(ast, 0, fn
        %Expr.Var{}, acc -> acc + 1
        _, acc -> acc
      end)

      assert var_count == 2  # a and b
    end
  end

  describe "map/2" do
    test "transforms number literals" do
      # local x = 2 + 3
      ast = chunk([
        local(["x"], [binop(:add, number(2), number(3))])
      ])

      # Double all numbers
      transformed = Walker.map(ast, fn
        %Expr.Number{value: n} = node -> %{node | value: n * 2}
        node -> node
      end)

      # Extract the numbers
      numbers = Walker.reduce(transformed, [], fn
        %Expr.Number{value: n}, acc -> [n | acc]
        _, acc -> acc
      end)

      assert Enum.sort(numbers) == [4, 6]  # 2*2=4, 3*2=6
    end

    test "transforms variable names" do
      # x = y + z
      ast = chunk([
        assign([var("x")], [binop(:add, var("y"), var("z"))])
      ])

      # Add prefix to all variables
      transformed = Walker.map(ast, fn
        %Expr.Var{name: name} = node -> %{node | name: "local_" <> name}
        node -> node
      end)

      # Collect variable names
      names = Walker.reduce(transformed, [], fn
        %Expr.Var{name: name}, acc -> [name | acc]
        _, acc -> acc
      end)

      assert Enum.sort(names) == ["local_x", "local_y", "local_z"]
    end

    test "preserves structure while transforming" do
      # if true then print(1) end
      ast = chunk([
        if_stmt(bool(true), [
          call_stmt(call(var("print"), [number(1)]))
        ])
      ])

      # Transform should preserve structure
      transformed = Walker.map(ast, fn
        %Expr.Number{value: n} = node -> %{node | value: n + 1}
        node -> node
      end)

      # Extract the if statement
      [%Stmt.If{condition: %Expr.Bool{value: true}}] = transformed.block.stmts

      # Number should be transformed
      numbers = Walker.reduce(transformed, [], fn
        %Expr.Number{value: n}, acc -> [n | acc]
        _, acc -> acc
      end)

      assert numbers == [2]  # 1 + 1 = 2
    end
  end

  describe "reduce/3" do
    test "counts all nodes" do
      # local x = 1; local y = 2; return x + y
      ast = chunk([
        local(["x"], [number(1)]),
        local(["y"], [number(2)]),
        return_stmt([binop(:add, var("x"), var("y"))])
      ])

      count = Walker.reduce(ast, 0, fn _, acc -> acc + 1 end)

      # Should count all nodes
      assert count > 5
    end

    test "collects specific node types" do
      # local x = 1; y = 2; print(x, y)
      ast = chunk([
        local(["x"], [number(1)]),
        assign([var("y")], [number(2)]),
        call_stmt(call(var("print"), [var("x"), var("y")]))
      ])

      # Collect all variable names
      vars = Walker.reduce(ast, [], fn
        %Expr.Var{name: name}, acc -> [name | acc]
        _, acc -> acc
      end)

      assert Enum.sort(vars) == ["print", "x", "y", "y"]

      # Collect all numbers
      numbers = Walker.reduce(ast, [], fn
        %Expr.Number{value: n}, acc -> [n | acc]
        _, acc -> acc
      end)

      assert Enum.sort(numbers) == [1, 2]
    end

    test "builds maps from nodes" do
      # local x = 10; local y = 20
      ast = chunk([
        local(["x"], [number(10)]),
        local(["y"], [number(20)])
      ])

      # Build map of local declarations: name -> value
      locals = Walker.reduce(ast, %{}, fn
        %Stmt.Local{names: [name], values: [%Expr.Number{value: n}]}, acc ->
          Map.put(acc, name, n)
        _, acc ->
          acc
      end)

      assert locals == %{"x" => 10, "y" => 20}
    end

    test "accumulates deeply nested values" do
      # function f() return function() return 42 end end
      ast = chunk([
        func_decl("f", [], [
          return_stmt([function_expr([], [
            return_stmt([number(42)])
          ])])
        ])
      ])

      # Count function expressions
      func_count = Walker.reduce(ast, 0, fn
        %Expr.Function{}, acc -> acc + 1
        _, acc -> acc
      end)

      assert func_count == 1
    end
  end

  describe "complex AST traversal" do
    test "handles nested loops and conditions" do
      # for i = 1, 10 do
      #   if i % 2 == 0 then
      #     print(i)
      #   end
      # end
      ast = chunk([
        for_num("i", number(1), number(10), [
          if_stmt(
            binop(:eq, binop(:mod, var("i"), number(2)), number(0)),
            [call_stmt(call(var("print"), [var("i")]))]
          )
        ])
      ])

      # Count all operators
      ops = Walker.reduce(ast, [], fn
        %Expr.BinOp{op: op}, acc -> [op | acc]
        _, acc -> acc
      end)

      assert :eq in ops
      assert :mod in ops
    end

    test "handles table constructors" do
      # local t = {x = 1, y = 2, [3] = "three"}
      ast = chunk([
        local(["t"], [
          table([
            {:record, string("x"), number(1)},
            {:record, string("y"), number(2)},
            {:record, number(3), string("three")}
          ])
        ])
      ])

      # Count table fields
      field_count = Walker.reduce(ast, 0, fn
        %Expr.Table{fields: fields}, acc -> acc + length(fields)
        _, acc -> acc
      end)

      assert field_count == 3
    end
  end

  # Helper to count nodes
  defp count_nodes(ast) do
    Walker.reduce(ast, 0, fn _, acc -> acc + 1 end)
  end

  # Helper to collect messages
  defp collect_messages(ref, acc) do
    receive do
      {^ref, node} -> collect_messages(ref, [node | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end

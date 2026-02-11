defmodule Lua.AST.WalkerTest do
  use ExUnit.Case, async: true

  import Lua.AST.Builder

  alias Lua.AST.Chunk
  alias Lua.AST.Expr
  alias Lua.AST.Statement
  alias Lua.AST.Walker

  describe "walk/2" do
    test "visits all nodes in pre-order" do
      # Build: local x = 2 + 3
      ast =
        chunk([
          local(["x"], [binop(:add, number(2), number(3))])
        ])

      ref = :erlang.make_ref()

      Walker.walk(ast, fn node ->
        send(self(), {ref, node})
      end)

      # Collect all visited nodes
      visited = collect_messages(ref, [])

      # Should visit in pre-order: Chunk, Block, Local, BinOp, Number(2), Number(3)
      assert length(visited) == 6
      assert hd(visited).__struct__ == Chunk
    end

    test "visits all nodes in post-order" do
      # Build: local x = 2 + 3
      ast =
        chunk([
          local(["x"], [binop(:add, number(2), number(3))])
        ])

      ref = :erlang.make_ref()

      Walker.walk(
        ast,
        fn node ->
          send(self(), {ref, node})
        end,
        order: :post
      )

      visited = collect_messages(ref, [])

      # Should visit in post-order: children before parents
      # Last visited should be Chunk
      assert length(visited) == 6
      assert List.last(visited).__struct__ == Chunk
    end

    test "walks through if statement with all branches" do
      # if x > 0 then return 1 elseif x < 0 then return -1 else return 0 end
      ast =
        chunk([
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
      ast =
        chunk([
          local(["f"], [
            function_expr(["a", "b"], [
              return_stmt([binop(:add, var("a"), var("b"))])
            ])
          ])
        ])

      # Count variable references
      var_count =
        Walker.reduce(ast, 0, fn
          %Expr.Var{}, acc -> acc + 1
          _, acc -> acc
        end)

      # a and b
      assert var_count == 2
    end
  end

  describe "map/2" do
    test "transforms number literals" do
      # local x = 2 + 3
      ast =
        chunk([
          local(["x"], [binop(:add, number(2), number(3))])
        ])

      # Double all numbers
      transformed =
        Walker.map(ast, fn
          %Expr.Number{value: n} = node -> %{node | value: n * 2}
          node -> node
        end)

      # Extract the numbers
      numbers =
        Walker.reduce(transformed, [], fn
          %Expr.Number{value: n}, acc -> [n | acc]
          _, acc -> acc
        end)

      # 2*2=4, 3*2=6
      assert Enum.sort(numbers) == [4, 6]
    end

    test "transforms variable names" do
      # x = y + z
      ast =
        chunk([
          assign([var("x")], [binop(:add, var("y"), var("z"))])
        ])

      # Add prefix to all variables
      transformed =
        Walker.map(ast, fn
          %Expr.Var{name: name} = node -> %{node | name: "local_" <> name}
          node -> node
        end)

      # Collect variable names
      names =
        Walker.reduce(transformed, [], fn
          %Expr.Var{name: name}, acc -> [name | acc]
          _, acc -> acc
        end)

      assert Enum.sort(names) == ["local_x", "local_y", "local_z"]
    end

    test "preserves structure while transforming" do
      # if true then print(1) end
      ast =
        chunk([
          if_stmt(bool(true), [
            call_stmt(call(var("print"), [number(1)]))
          ])
        ])

      # Transform should preserve structure
      transformed =
        Walker.map(ast, fn
          %Expr.Number{value: n} = node -> %{node | value: n + 1}
          node -> node
        end)

      # Extract the if statement
      [%Statement.If{condition: %Expr.Bool{value: true}}] = transformed.block.stmts

      # Number should be transformed
      numbers =
        Walker.reduce(transformed, [], fn
          %Expr.Number{value: n}, acc -> [n | acc]
          _, acc -> acc
        end)

      # 1 + 1 = 2
      assert numbers == [2]
    end
  end

  describe "reduce/3" do
    test "counts all nodes" do
      # local x = 1; local y = 2; return x + y
      ast =
        chunk([
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
      ast =
        chunk([
          local(["x"], [number(1)]),
          assign([var("y")], [number(2)]),
          call_stmt(call(var("print"), [var("x"), var("y")]))
        ])

      # Collect all variable names
      vars =
        Walker.reduce(ast, [], fn
          %Expr.Var{name: name}, acc -> [name | acc]
          _, acc -> acc
        end)

      assert Enum.sort(vars) == ["print", "x", "y", "y"]

      # Collect all numbers
      numbers =
        Walker.reduce(ast, [], fn
          %Expr.Number{value: n}, acc -> [n | acc]
          _, acc -> acc
        end)

      assert Enum.sort(numbers) == [1, 2]
    end

    test "builds maps from nodes" do
      # local x = 10; local y = 20
      ast =
        chunk([
          local(["x"], [number(10)]),
          local(["y"], [number(20)])
        ])

      # Build map of local declarations: name -> value
      locals =
        Walker.reduce(ast, %{}, fn
          %Statement.Local{names: [name], values: [%Expr.Number{value: n}]}, acc ->
            Map.put(acc, name, n)

          _, acc ->
            acc
        end)

      assert locals == %{"x" => 10, "y" => 20}
    end

    test "accumulates deeply nested values" do
      # function f() return function() return 42 end end
      ast =
        chunk([
          func_decl("f", [], [
            return_stmt([
              function_expr([], [
                return_stmt([number(42)])
              ])
            ])
          ])
        ])

      # Count function expressions
      func_count =
        Walker.reduce(ast, 0, fn
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
      ast =
        chunk([
          for_num("i", number(1), number(10), [
            if_stmt(
              binop(:eq, binop(:mod, var("i"), number(2)), number(0)),
              [call_stmt(call(var("print"), [var("i")]))]
            )
          ])
        ])

      # Count all operators
      ops =
        Walker.reduce(ast, [], fn
          %Expr.BinOp{op: op}, acc -> [op | acc]
          _, acc -> acc
        end)

      assert :eq in ops
      assert :mod in ops
    end

    test "handles table constructors" do
      # local t = {x = 1, y = 2, [3] = "three"}
      ast =
        chunk([
          local(["t"], [
            table([
              {:record, string("x"), number(1)},
              {:record, string("y"), number(2)},
              {:record, number(3), string("three")}
            ])
          ])
        ])

      # Count table fields
      field_count =
        Walker.reduce(ast, 0, fn
          %Expr.Table{fields: fields}, acc -> acc + length(fields)
          _, acc -> acc
        end)

      assert field_count == 3
    end
  end

  describe "expression nodes" do
    test "walks MethodCall nodes" do
      # obj:method(arg1, arg2)
      ast =
        chunk([
          call_stmt(method_call(var("obj"), "method", [var("arg1"), var("arg2")]))
        ])

      # Count all variables
      var_count =
        Walker.reduce(ast, 0, fn
          %Expr.Var{}, acc -> acc + 1
          _, acc -> acc
        end)

      # obj, arg1, arg2
      assert var_count == 3
    end

    test "maps MethodCall nodes" do
      # file:read("*a")
      ast =
        chunk([
          call_stmt(method_call(var("file"), "read", [string("*a")]))
        ])

      # Transform method name
      transformed =
        Walker.map(ast, fn
          %Expr.MethodCall{method: m} = node -> %{node | method: "new_" <> m}
          node -> node
        end)

      # Extract method call
      method_calls =
        Walker.reduce(transformed, [], fn
          %Expr.MethodCall{method: m}, acc -> [m | acc]
          _, acc -> acc
        end)

      assert method_calls == ["new_read"]
    end

    test "walks Index nodes" do
      # t[key]
      ast = chunk([assign([index(var("t"), var("key"))], [number(42)])])

      # Count variables
      vars =
        Walker.reduce(ast, [], fn
          %Expr.Var{name: name}, acc -> [name | acc]
          _, acc -> acc
        end)

      assert Enum.sort(vars) == ["key", "t"]
    end

    test "maps Index nodes" do
      # arr[1] = arr[2]
      ast =
        chunk([
          assign(
            [index(var("arr"), number(1))],
            [index(var("arr"), number(2))]
          )
        ])

      # Double all indices
      transformed =
        Walker.map(ast, fn
          %Expr.Index{key: %Expr.Number{value: n} = key} = node ->
            %{node | key: %{key | value: n * 2}}

          node ->
            node
        end)

      # Collect indices
      indices =
        Walker.reduce(transformed, [], fn
          %Expr.Index{key: %Expr.Number{value: n}}, acc -> [n | acc]
          _, acc -> acc
        end)

      assert Enum.sort(indices) == [2, 4]
    end

    test "walks Property nodes" do
      # io.write
      ast = chunk([call_stmt(call(property(var("io"), "write"), [string("test")]))])

      # Count variables
      var_count =
        Walker.reduce(ast, 0, fn
          %Expr.Var{}, acc -> acc + 1
          _, acc -> acc
        end)

      # io
      assert var_count == 1
    end

    test "maps Property nodes" do
      # math.pi
      ast = chunk([assign([var("x")], [property(var("math"), "pi")])])

      # Transform property field
      transformed =
        Walker.map(ast, fn
          %Expr.Property{field: f} = node -> %{node | field: String.upcase(f)}
          node -> node
        end)

      # Extract property field
      fields =
        Walker.reduce(transformed, [], fn
          %Expr.Property{field: f}, acc -> [f | acc]
          _, acc -> acc
        end)

      assert fields == ["PI"]
    end

    test "walks String nodes" do
      # local s = "hello"
      ast = chunk([local(["s"], [string("hello")])])

      # Collect strings
      strings =
        Walker.reduce(ast, [], fn
          %Expr.String{value: s}, acc -> [s | acc]
          _, acc -> acc
        end)

      assert strings == ["hello"]
    end

    test "maps String nodes" do
      # print("hello", "world")
      ast = chunk([call_stmt(call(var("print"), [string("hello"), string("world")]))])

      # Uppercase all strings
      transformed =
        Walker.map(ast, fn
          %Expr.String{value: s} = node -> %{node | value: String.upcase(s)}
          node -> node
        end)

      strings =
        Walker.reduce(transformed, [], fn
          %Expr.String{value: s}, acc -> [s | acc]
          _, acc -> acc
        end)

      assert Enum.sort(strings) == ["HELLO", "WORLD"]
    end

    test "walks Nil nodes" do
      # local x = nil
      ast = chunk([local(["x"], [nil_lit()])])

      # Count nil literals
      nil_count =
        Walker.reduce(ast, 0, fn
          %Expr.Nil{}, acc -> acc + 1
          _, acc -> acc
        end)

      assert nil_count == 1
    end

    test "walks Vararg nodes" do
      # function(...) return ... end
      ast = chunk([func_decl("f", [], [return_stmt([vararg()])], vararg: true)])

      # Count vararg expressions
      vararg_count =
        Walker.reduce(ast, 0, fn
          %Expr.Vararg{}, acc -> acc + 1
          _, acc -> acc
        end)

      assert vararg_count == 1
    end

    test "maps Vararg nodes in function" do
      # local f = function(...) return ... end
      ast = chunk([local(["f"], [function_expr([], [return_stmt([vararg()])], vararg: true)])])

      # Count nodes before and after map
      count_before = count_nodes(ast)

      transformed =
        Walker.map(ast, fn
          node -> node
        end)

      count_after = count_nodes(transformed)

      # Structure should be preserved
      assert count_before == count_after
    end
  end

  describe "statement nodes" do
    test "walks Local without values" do
      # local x, y
      ast = chunk([local(["x", "y"], [])])

      # Count local statements
      local_count =
        Walker.reduce(ast, 0, fn
          %Statement.Local{}, acc -> acc + 1
          _, acc -> acc
        end)

      assert local_count == 1

      # Should have no child expressions
      expr_count =
        Walker.reduce(ast, 0, fn
          %Expr.Number{}, acc -> acc + 1
          _, acc -> acc
        end)

      assert expr_count == 0
    end

    test "maps Local without values" do
      # local x
      ast = chunk([local(["x"], [])])

      # Transform should preserve empty values list
      transformed =
        Walker.map(ast, fn
          %Statement.Local{values: []} = node -> node
          node -> node
        end)

      # Extract local statement
      locals =
        Walker.reduce(transformed, [], fn
          %Statement.Local{names: names, values: values}, acc -> [{names, values} | acc]
          _, acc -> acc
        end)

      assert locals == [{["x"], []}]
    end

    test "walks LocalFunc nodes" do
      # local function add(a, b) return a + b end
      ast =
        chunk([local_func("add", ["a", "b"], [return_stmt([binop(:add, var("a"), var("b"))])])])

      # Count variables
      var_count =
        Walker.reduce(ast, 0, fn
          %Expr.Var{}, acc -> acc + 1
          _, acc -> acc
        end)

      # a, b (in return statement)
      assert var_count == 2
    end

    test "maps LocalFunc nodes" do
      # local function f() return 1 end
      ast = chunk([local_func("f", [], [return_stmt([number(1)])])])

      # Double numbers
      transformed =
        Walker.map(ast, fn
          %Expr.Number{value: n} = node -> %{node | value: n * 2}
          node -> node
        end)

      numbers =
        Walker.reduce(transformed, [], fn
          %Expr.Number{value: n}, acc -> [n | acc]
          _, acc -> acc
        end)

      assert numbers == [2]
    end

    test "walks While nodes" do
      # while x > 0 do x = x - 1 end
      ast =
        chunk([
          while_stmt(
            binop(:gt, var("x"), number(0)),
            [assign([var("x")], [binop(:sub, var("x"), number(1))])]
          )
        ])

      # Count variables
      var_count =
        Walker.reduce(ast, 0, fn
          %Expr.Var{name: "x"}, acc -> acc + 1
          _, acc -> acc
        end)

      # x appears 3 times: condition, target, value
      assert var_count == 3
    end

    test "maps While nodes" do
      # while true do print(1) end
      ast = chunk([while_stmt(bool(true), [call_stmt(call(var("print"), [number(1)]))])])

      # Transform numbers
      transformed =
        Walker.map(ast, fn
          %Expr.Number{value: n} = node -> %{node | value: n + 10}
          node -> node
        end)

      numbers =
        Walker.reduce(transformed, [], fn
          %Expr.Number{value: n}, acc -> [n | acc]
          _, acc -> acc
        end)

      assert numbers == [11]
    end

    test "walks Repeat nodes" do
      # repeat x = x - 1 until x <= 0
      ast =
        chunk([
          repeat_stmt(
            [assign([var("x")], [binop(:sub, var("x"), number(1))])],
            binop(:le, var("x"), number(0))
          )
        ])

      # Count variables
      var_count =
        Walker.reduce(ast, 0, fn
          %Expr.Var{name: "x"}, acc -> acc + 1
          _, acc -> acc
        end)

      # x appears 3 times: target, value, condition
      assert var_count == 3
    end

    test "maps Repeat nodes" do
      # repeat print(5) until true
      ast = chunk([repeat_stmt([call_stmt(call(var("print"), [number(5)]))], bool(true))])

      # Transform numbers
      transformed =
        Walker.map(ast, fn
          %Expr.Number{value: n} = node -> %{node | value: n * 2}
          node -> node
        end)

      numbers =
        Walker.reduce(transformed, [], fn
          %Expr.Number{value: n}, acc -> [n | acc]
          _, acc -> acc
        end)

      assert numbers == [10]
    end

    test "walks ForNum with nil step" do
      # for i = 1, 10 do print(i) end
      ast =
        chunk([for_num("i", number(1), number(10), [call_stmt(call(var("print"), [var("i")]))])])

      # Verify step is nil
      step_is_nil =
        Walker.reduce(ast, false, fn
          %Statement.ForNum{step: nil}, _acc -> true
          _, acc -> acc
        end)

      assert step_is_nil
    end

    test "walks ForNum with explicit step" do
      # for i = 1, 10, 2 do print(i) end
      ast =
        chunk([
          for_num("i", number(1), number(10), [call_stmt(call(var("print"), [var("i")]))], step: number(2))
        ])

      # Count numbers (start, limit, step)
      numbers =
        Walker.reduce(ast, [], fn
          %Expr.Number{value: n}, acc -> [n | acc]
          _, acc -> acc
        end)

      # 1, 10, 2 from the loop header (i is a var in the body)
      assert Enum.sort(numbers) == [1, 2, 10]
    end

    test "maps ForNum with nil step" do
      # for i = 1, 10 do end
      ast = chunk([for_num("i", number(1), number(10), [])])

      # Transform numbers
      transformed =
        Walker.map(ast, fn
          %Expr.Number{value: n} = node -> %{node | value: n + 5}
          node -> node
        end)

      numbers =
        Walker.reduce(transformed, [], fn
          %Expr.Number{value: n}, acc -> [n | acc]
          _, acc -> acc
        end)

      assert Enum.sort(numbers) == [6, 15]
    end

    test "maps ForNum with explicit step" do
      # for i = 2, 20, 3 do end
      ast = chunk([for_num("i", number(2), number(20), [], step: number(3))])

      # Transform numbers
      transformed =
        Walker.map(ast, fn
          %Expr.Number{value: n} = node -> %{node | value: n * 10}
          node -> node
        end)

      numbers =
        Walker.reduce(transformed, [], fn
          %Expr.Number{value: n}, acc -> [n | acc]
          _, acc -> acc
        end)

      assert Enum.sort(numbers) == [20, 30, 200]
    end

    test "walks ForIn nodes" do
      # for k, v in pairs(t) do print(k, v) end
      ast =
        chunk([
          for_in(
            ["k", "v"],
            [call(var("pairs"), [var("t")])],
            [call_stmt(call(var("print"), [var("k"), var("v")]))]
          )
        ])

      # Count variables
      vars =
        Walker.reduce(ast, [], fn
          %Expr.Var{name: name}, acc -> [name | acc]
          _, acc -> acc
        end)

      # pairs, t, print, k, v
      assert Enum.sort(vars) == ["k", "pairs", "print", "t", "v"]
    end

    test "maps ForIn nodes" do
      # for x in iter() do print(x) end
      ast =
        chunk([
          for_in(["x"], [call(var("iter"), [])], [call_stmt(call(var("print"), [var("x")]))])
        ])

      # Transform variable names
      transformed =
        Walker.map(ast, fn
          %Expr.Var{name: name} = node -> %{node | name: "new_" <> name}
          node -> node
        end)

      vars =
        Walker.reduce(transformed, [], fn
          %Expr.Var{name: name}, acc -> [name | acc]
          _, acc -> acc
        end)

      assert Enum.sort(vars) == ["new_iter", "new_print", "new_x"]
    end

    test "walks Do nodes" do
      # do local x = 1; print(x) end
      ast =
        chunk([
          do_block([
            local(["x"], [number(1)]),
            call_stmt(call(var("print"), [var("x")]))
          ])
        ])

      # Count do statements
      do_count =
        Walker.reduce(ast, 0, fn
          %Statement.Do{}, acc -> acc + 1
          _, acc -> acc
        end)

      assert do_count == 1
    end

    test "maps Do nodes" do
      # do print(5) end
      ast = chunk([do_block([call_stmt(call(var("print"), [number(5)]))])])

      # Transform numbers
      transformed =
        Walker.map(ast, fn
          %Expr.Number{value: n} = node -> %{node | value: n * 3}
          node -> node
        end)

      numbers =
        Walker.reduce(transformed, [], fn
          %Expr.Number{value: n}, acc -> [n | acc]
          _, acc -> acc
        end)

      assert numbers == [15]
    end

    test "walks Break nodes" do
      # while true do break end
      ast = chunk([while_stmt(bool(true), [break_stmt()])])

      # Count break statements
      break_count =
        Walker.reduce(ast, 0, fn
          %Statement.Break{}, acc -> acc + 1
          _, acc -> acc
        end)

      assert break_count == 1
    end

    test "maps Break nodes (leaf node)" do
      # while true do break end
      ast = chunk([while_stmt(bool(true), [break_stmt()])])

      # Map should preserve break
      transformed =
        Walker.map(ast, fn
          node -> node
        end)

      break_count =
        Walker.reduce(transformed, 0, fn
          %Statement.Break{}, acc -> acc + 1
          _, acc -> acc
        end)

      assert break_count == 1
    end

    test "walks Goto nodes" do
      # goto skip
      ast = chunk([goto_stmt("skip")])

      # Count goto statements
      goto_labels =
        Walker.reduce(ast, [], fn
          %Statement.Goto{label: label}, acc -> [label | acc]
          _, acc -> acc
        end)

      assert goto_labels == ["skip"]
    end

    test "maps Goto nodes (leaf node)" do
      # goto target
      ast = chunk([goto_stmt("target")])

      # Map should preserve goto
      transformed =
        Walker.map(ast, fn
          node -> node
        end)

      labels =
        Walker.reduce(transformed, [], fn
          %Statement.Goto{label: label}, acc -> [label | acc]
          _, acc -> acc
        end)

      assert labels == ["target"]
    end

    test "walks Label nodes" do
      # ::start::
      ast = chunk([label("start")])

      # Count labels
      labels =
        Walker.reduce(ast, [], fn
          %Statement.Label{name: name}, acc -> [name | acc]
          _, acc -> acc
        end)

      assert labels == ["start"]
    end

    test "maps Label nodes (leaf node)" do
      # ::loop::
      ast = chunk([label("loop")])

      # Map should preserve label
      transformed =
        Walker.map(ast, fn
          node -> node
        end)

      labels =
        Walker.reduce(transformed, [], fn
          %Statement.Label{name: name}, acc -> [name | acc]
          _, acc -> acc
        end)

      assert labels == ["loop"]
    end

    test "walks FuncDecl nodes" do
      # function add(a, b) return a + b end
      ast =
        chunk([func_decl("add", ["a", "b"], [return_stmt([binop(:add, var("a"), var("b"))])])])

      # Count variables
      var_count =
        Walker.reduce(ast, 0, fn
          %Expr.Var{}, acc -> acc + 1
          _, acc -> acc
        end)

      # a, b (in return statement)
      assert var_count == 2
    end

    test "maps FuncDecl nodes" do
      # function f() return 1 end
      ast = chunk([func_decl("f", [], [return_stmt([number(1)])])])

      # Double numbers
      transformed =
        Walker.map(ast, fn
          %Expr.Number{value: n} = node -> %{node | value: n * 2}
          node -> node
        end)

      numbers =
        Walker.reduce(transformed, [], fn
          %Expr.Number{value: n}, acc -> [n | acc]
          _, acc -> acc
        end)

      assert numbers == [2]
    end
  end

  describe "edge cases" do
    test "If with no elseifs or else" do
      # if x then print(x) end
      ast = chunk([if_stmt(var("x"), [call_stmt(call(var("print"), [var("x")]))])])

      # Verify structure
      if_stmts =
        Walker.reduce(ast, [], fn
          %Statement.If{elseifs: elseifs, else_block: else_block}, acc ->
            [{elseifs, else_block} | acc]

          _, acc ->
            acc
        end)

      assert if_stmts == [{[], nil}]
    end

    test "If with elseif clauses mapping" do
      # if x > 0 then return 1 elseif x < 0 then return -1 end
      ast =
        chunk([
          if_stmt(
            binop(:gt, var("x"), number(0)),
            [return_stmt([number(1)])],
            elseif: [{binop(:lt, var("x"), number(0)), [return_stmt([number(-1)])]}]
          )
        ])

      # Map should traverse elseif conditions and blocks
      transformed =
        Walker.map(ast, fn
          %Expr.Number{value: n} = node -> %{node | value: n * 10}
          node -> node
        end)

      numbers =
        Walker.reduce(transformed, [], fn
          %Expr.Number{value: n}, acc -> [n | acc]
          _, acc -> acc
        end)

      # Should have transformed: 0, 1, 0, -1 -> 0, 10, 0, -10
      assert Enum.sort(numbers) == [-10, 0, 0, 10]
    end

    test "UnOp expressions mapping" do
      # local x = -5
      ast = chunk([local(["x"], [unop(:neg, number(5))])])

      # Map should traverse unary operations
      transformed =
        Walker.map(ast, fn
          %Expr.Number{value: n} = node -> %{node | value: n * 2}
          node -> node
        end)

      numbers =
        Walker.reduce(transformed, [], fn
          %Expr.Number{value: n}, acc -> [n | acc]
          _, acc -> acc
        end)

      assert numbers == [10]
    end

    test "Local without values mapping" do
      # local x
      ast = chunk([local(["x"], nil)])

      # Map should handle Local without values
      transformed =
        Walker.map(ast, fn
          node -> node
        end)

      locals =
        Walker.reduce(transformed, [], fn
          %Statement.Local{names: names, values: values}, acc -> [{names, values} | acc]
          _, acc -> acc
        end)

      assert locals == [{["x"], nil}]
    end

    test "Table with list fields" do
      # {1, 2, 3}
      ast =
        chunk([
          local(["t"], [
            table([
              {:list, number(1)},
              {:list, number(2)},
              {:list, number(3)}
            ])
          ])
        ])

      # Count numbers
      numbers =
        Walker.reduce(ast, [], fn
          %Expr.Number{value: n}, acc -> [n | acc]
          _, acc -> acc
        end)

      assert Enum.sort(numbers) == [1, 2, 3]
    end

    test "Table with mixed list and record fields" do
      # {10, 20, x = 30}
      ast =
        chunk([
          local(["t"], [
            table([
              {:list, number(10)},
              {:list, number(20)},
              {:record, string("x"), number(30)}
            ])
          ])
        ])

      # Map should handle both field types
      transformed =
        Walker.map(ast, fn
          %Expr.Number{value: n} = node -> %{node | value: n + 1}
          node -> node
        end)

      numbers =
        Walker.reduce(transformed, [], fn
          %Expr.Number{value: n}, acc -> [n | acc]
          _, acc -> acc
        end)

      assert Enum.sort(numbers) == [11, 21, 31]
    end

    test "Empty table" do
      # local t = {}
      ast = chunk([local(["t"], [table([])])])

      # Count table nodes
      table_count =
        Walker.reduce(ast, 0, fn
          %Expr.Table{}, acc -> acc + 1
          _, acc -> acc
        end)

      assert table_count == 1

      # Should have no field children
      field_count =
        Walker.reduce(ast, 0, fn
          %Expr.Table{fields: fields}, acc -> acc + length(fields)
          _, acc -> acc
        end)

      assert field_count == 0
    end

    test "Nested method calls" do
      # obj:method1():method2()
      ast =
        chunk([
          call_stmt(
            method_call(
              method_call(var("obj"), "method1", []),
              "method2",
              []
            )
          )
        ])

      # Count method calls
      method_count =
        Walker.reduce(ast, 0, fn
          %Expr.MethodCall{}, acc -> acc + 1
          _, acc -> acc
        end)

      assert method_count == 2
    end

    test "Complex nested indexing" do
      # t[a][b][c]
      ast =
        chunk([
          assign(
            [index(index(index(var("t"), var("a")), var("b")), var("c"))],
            [number(1)]
          )
        ])

      # Count index operations
      index_count =
        Walker.reduce(ast, 0, fn
          %Expr.Index{}, acc -> acc + 1
          _, acc -> acc
        end)

      assert index_count == 3
    end

    test "Multiple return values" do
      # return a, b, c
      ast = chunk([return_stmt([var("a"), var("b"), var("c")])])

      # Count variables
      var_count =
        Walker.reduce(ast, 0, fn
          %Expr.Var{}, acc -> acc + 1
          _, acc -> acc
        end)

      assert var_count == 3
    end

    test "CallStmt with MethodCall" do
      # obj:method()
      ast = chunk([call_stmt(method_call(var("obj"), "method", []))])

      # Should walk through CallStmt to MethodCall
      call_stmt_count =
        Walker.reduce(ast, 0, fn
          %Statement.CallStmt{}, acc -> acc + 1
          _, acc -> acc
        end)

      method_call_count =
        Walker.reduce(ast, 0, fn
          %Expr.MethodCall{}, acc -> acc + 1
          _, acc -> acc
        end)

      assert call_stmt_count == 1
      assert method_call_count == 1
    end

    test "Deeply nested expressions" do
      # ((a + b) * (c + d)) / ((e - f) * (g - h))
      ast =
        chunk([
          local(["x"], [
            binop(
              :div,
              binop(:mul, binop(:add, var("a"), var("b")), binop(:add, var("c"), var("d"))),
              binop(:mul, binop(:sub, var("e"), var("f")), binop(:sub, var("g"), var("h")))
            )
          ])
        ])

      # Count binary operations
      binop_count =
        Walker.reduce(ast, 0, fn
          %Expr.BinOp{}, acc -> acc + 1
          _, acc -> acc
        end)

      # 7 binary operations total
      assert binop_count == 7

      # Count variables
      vars =
        Walker.reduce(ast, [], fn
          %Expr.Var{name: name}, acc -> [name | acc]
          _, acc -> acc
        end)

      assert Enum.sort(vars) == ["a", "b", "c", "d", "e", "f", "g", "h"]
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

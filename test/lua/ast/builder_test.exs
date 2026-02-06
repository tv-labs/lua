defmodule Lua.AST.BuilderTest do
  use ExUnit.Case, async: true

  import Lua.AST.Builder
  alias Lua.AST.{Chunk, Block, Expr, Statement}

  describe "chunk and block" do
    test "creates a chunk" do
      ast = chunk([local(["x"], [number(42)])])
      assert %Chunk{block: %Block{stmts: [%Statement.Local{}]}} = ast
    end

    test "creates a block" do
      blk = block([local(["x"], [number(42)])])
      assert %Block{stmts: [%Statement.Local{}]} = blk
    end
  end

  describe "literals" do
    test "creates nil literal" do
      assert %Expr.Nil{} = nil_lit()
    end

    test "creates boolean literals" do
      assert %Expr.Bool{value: true} = bool(true)
      assert %Expr.Bool{value: false} = bool(false)
    end

    test "creates number literal" do
      assert %Expr.Number{value: 42} = number(42)
      assert %Expr.Number{value: 3.14} = number(3.14)
    end

    test "creates string literal" do
      assert %Expr.String{value: "hello"} = string("hello")
    end

    test "creates vararg" do
      assert %Expr.Vararg{} = vararg()
    end
  end

  describe "variables and access" do
    test "creates variable reference" do
      assert %Expr.Var{name: "x"} = var("x")
    end

    test "creates property access" do
      prop = property(var("io"), "write")
      assert %Expr.Property{table: %Expr.Var{name: "io"}, field: "write"} = prop
    end

    test "creates index access" do
      idx = index(var("t"), number(1))
      assert %Expr.Index{table: %Expr.Var{name: "t"}, key: %Expr.Number{value: 1}} = idx
    end

    test "creates chained property access" do
      prop = property(property(var("a"), "b"), "c")

      assert %Expr.Property{
               table: %Expr.Property{
                 table: %Expr.Var{name: "a"},
                 field: "b"
               },
               field: "c"
             } = prop
    end
  end

  describe "operators" do
    test "creates binary operation" do
      op = binop(:add, number(2), number(3))

      assert %Expr.BinOp{op: :add, left: %Expr.Number{value: 2}, right: %Expr.Number{value: 3}} =
               op
    end

    test "creates all binary operators" do
      ops = [
        :add,
        :sub,
        :mul,
        :div,
        :floor_div,
        :mod,
        :pow,
        :concat,
        :eq,
        :ne,
        :lt,
        :gt,
        :le,
        :ge,
        :and,
        :or
      ]

      for op <- ops do
        assert %Expr.BinOp{op: ^op} = binop(op, number(1), number(2))
      end
    end

    test "creates unary operation" do
      op = unop(:neg, var("x"))
      assert %Expr.UnOp{op: :neg, operand: %Expr.Var{name: "x"}} = op
    end

    test "creates all unary operators" do
      assert %Expr.UnOp{op: :not} = unop(:not, var("x"))
      assert %Expr.UnOp{op: :neg} = unop(:neg, var("x"))
      assert %Expr.UnOp{op: :len} = unop(:len, var("x"))
    end

    test "creates nested operations" do
      # (2 + 3) * 4
      op = binop(:mul, binop(:add, number(2), number(3)), number(4))

      assert %Expr.BinOp{
               op: :mul,
               left: %Expr.BinOp{op: :add},
               right: %Expr.Number{value: 4}
             } = op
    end
  end

  describe "table constructors" do
    test "creates empty table" do
      tbl = table([])
      assert %Expr.Table{fields: []} = tbl
    end

    test "creates array-style table" do
      tbl =
        table([
          {:list, number(1)},
          {:list, number(2)},
          {:list, number(3)}
        ])

      assert %Expr.Table{fields: [{:list, _}, {:list, _}, {:list, _}]} = tbl
    end

    test "creates record-style table" do
      tbl =
        table([
          {:record, string("x"), number(10)},
          {:record, string("y"), number(20)}
        ])

      assert %Expr.Table{fields: [{:record, _, _}, {:record, _, _}]} = tbl
    end

    test "creates mixed table" do
      tbl =
        table([
          {:list, number(1)},
          {:record, string("x"), number(10)}
        ])

      assert %Expr.Table{fields: [{:list, _}, {:record, _, _}]} = tbl
    end
  end

  describe "function calls" do
    test "creates function call" do
      c = call(var("print"), [string("hello")])

      assert %Expr.Call{
               func: %Expr.Var{name: "print"},
               args: [%Expr.String{value: "hello"}]
             } = c
    end

    test "creates function call with multiple arguments" do
      c = call(var("print"), [number(1), number(2), number(3)])
      assert %Expr.Call{args: [_, _, _]} = c
    end

    test "creates method call" do
      mc = method_call(var("file"), "read", [string("*a")])

      assert %Expr.MethodCall{
               object: %Expr.Var{name: "file"},
               method: "read",
               args: [%Expr.String{value: "*a"}]
             } = mc
    end
  end

  describe "function expressions" do
    test "creates simple function" do
      fn_expr = function_expr(["x"], [return_stmt([var("x")])])

      assert %Expr.Function{
               params: ["x"],
               body: %Block{stmts: [%Statement.Return{}]}
             } = fn_expr
    end

    test "creates function with multiple parameters" do
      fn_expr = function_expr(["a", "b"], [return_stmt([binop(:add, var("a"), var("b"))])])
      assert %Expr.Function{params: ["a", "b"]} = fn_expr
    end

    test "creates function with vararg" do
      fn_expr = function_expr([], [return_stmt([vararg()])], vararg: true)
      assert %Expr.Function{params: [:vararg]} = fn_expr
    end
  end

  describe "statements" do
    test "creates assignment" do
      stmt = assign([var("x")], [number(42)])

      assert %Statement.Assign{
               targets: [%Expr.Var{name: "x"}],
               values: [%Expr.Number{value: 42}]
             } = stmt
    end

    test "creates multiple assignment" do
      stmt = assign([var("x"), var("y")], [number(1), number(2)])
      assert %Statement.Assign{targets: [_, _], values: [_, _]} = stmt
    end

    test "creates local declaration" do
      stmt = local(["x"], [number(42)])
      assert %Statement.Local{names: ["x"], values: [%Expr.Number{value: 42}]} = stmt
    end

    test "creates local declaration without value" do
      stmt = local(["x"], [])
      assert %Statement.Local{names: ["x"], values: []} = stmt
    end

    test "creates local function" do
      stmt = local_func("add", ["a", "b"], [return_stmt([binop(:add, var("a"), var("b"))])])

      assert %Statement.LocalFunc{
               name: "add",
               params: ["a", "b"],
               body: %Block{}
             } = stmt
    end

    test "creates function declaration with string name" do
      stmt = func_decl("add", ["a", "b"], [return_stmt([binop(:add, var("a"), var("b"))])])
      assert %Statement.FuncDecl{name: ["add"], params: ["a", "b"]} = stmt
    end

    test "creates function declaration with path name" do
      stmt =
        func_decl(["math", "add"], ["a", "b"], [return_stmt([binop(:add, var("a"), var("b"))])])

      assert %Statement.FuncDecl{name: ["math", "add"]} = stmt
    end

    test "creates call statement" do
      stmt = call_stmt(call(var("print"), [string("hello")]))
      assert %Statement.CallStmt{call: %Expr.Call{}} = stmt
    end

    test "creates return statement" do
      stmt = return_stmt([])
      assert %Statement.Return{values: []} = stmt

      stmt = return_stmt([number(42)])
      assert %Statement.Return{values: [%Expr.Number{value: 42}]} = stmt
    end

    test "creates break statement" do
      stmt = break_stmt()
      assert %Statement.Break{} = stmt
    end

    test "creates goto statement" do
      stmt = goto_stmt("label")
      assert %Statement.Goto{label: "label"} = stmt
    end

    test "creates label" do
      stmt = label("label")
      assert %Statement.Label{name: "label"} = stmt
    end
  end

  describe "control flow" do
    test "creates if statement" do
      stmt = if_stmt(var("x"), [return_stmt([number(1)])])

      assert %Statement.If{
               condition: %Expr.Var{name: "x"},
               then_block: %Block{stmts: [%Statement.Return{}]},
               elseifs: [],
               else_block: nil
             } = stmt
    end

    test "creates if-else statement" do
      stmt =
        if_stmt(
          var("x"),
          [return_stmt([number(1)])],
          else: [return_stmt([number(0)])]
        )

      assert %Statement.If{else_block: %Block{}} = stmt
    end

    test "creates if-elseif-else statement" do
      stmt =
        if_stmt(
          binop(:gt, var("x"), number(0)),
          [return_stmt([number(1)])],
          elseif: [{binop(:lt, var("x"), number(0)), [return_stmt([unop(:neg, number(1))])]}],
          else: [return_stmt([number(0)])]
        )

      assert %Statement.If{
               elseifs: [{_, %Block{}}],
               else_block: %Block{}
             } = stmt
    end

    test "creates while loop" do
      stmt =
        while_stmt(binop(:gt, var("x"), number(0)), [
          assign([var("x")], [binop(:sub, var("x"), number(1))])
        ])

      assert %Statement.While{
               condition: %Expr.BinOp{op: :gt},
               body: %Block{}
             } = stmt
    end

    test "creates repeat-until loop" do
      stmt =
        repeat_stmt(
          [assign([var("x")], [binop(:sub, var("x"), number(1))])],
          binop(:le, var("x"), number(0))
        )

      assert %Statement.Repeat{
               body: %Block{},
               condition: %Expr.BinOp{op: :le}
             } = stmt
    end

    test "creates numeric for loop" do
      stmt =
        for_num("i", number(1), number(10), [
          call_stmt(call(var("print"), [var("i")]))
        ])

      assert %Statement.ForNum{
               var: "i",
               start: %Expr.Number{value: 1},
               limit: %Expr.Number{value: 10},
               step: nil,
               body: %Block{}
             } = stmt
    end

    test "creates numeric for loop with step" do
      stmt =
        for_num(
          "i",
          number(1),
          number(10),
          [
            call_stmt(call(var("print"), [var("i")]))
          ],
          step: number(2)
        )

      assert %Statement.ForNum{step: %Expr.Number{value: 2}} = stmt
    end

    test "creates generic for loop" do
      stmt =
        for_in(
          ["k", "v"],
          [call(var("pairs"), [var("t")])],
          [call_stmt(call(var("print"), [var("k"), var("v")]))]
        )

      assert %Statement.ForIn{
               vars: ["k", "v"],
               iterators: [%Expr.Call{}],
               body: %Block{}
             } = stmt
    end

    test "creates do block" do
      stmt =
        do_block([
          local(["x"], [number(10)]),
          call_stmt(call(var("print"), [var("x")]))
        ])

      assert %Statement.Do{body: %Block{stmts: [_, _]}} = stmt
    end
  end

  describe "complex structures" do
    test "builds nested function with closure" do
      # function outer(x) return function(y) return x + y end end
      ast =
        chunk([
          func_decl("outer", ["x"], [
            return_stmt([
              function_expr(["y"], [
                return_stmt([binop(:add, var("x"), var("y"))])
              ])
            ])
          ])
        ])

      assert %Chunk{
               block: %Block{
                 stmts: [
                   %Statement.FuncDecl{
                     name: ["outer"],
                     body: %Block{
                       stmts: [
                         %Statement.Return{
                           values: [%Expr.Function{}]
                         }
                       ]
                     }
                   }
                 ]
               }
             } = ast
    end

    test "builds complex if-elseif-else chain" do
      ast =
        chunk([
          if_stmt(
            binop(:gt, var("x"), number(0)),
            [return_stmt([string("positive")])],
            elseif: [
              {binop(:lt, var("x"), number(0)), [return_stmt([string("negative")])]},
              {binop(:eq, var("x"), number(0)), [return_stmt([string("zero")])]}
            ],
            else: [return_stmt([string("unknown")])]
          )
        ])

      assert %Chunk{
               block: %Block{
                 stmts: [
                   %Statement.If{
                     elseifs: [{_, _}, {_, _}],
                     else_block: %Block{}
                   }
                 ]
               }
             } = ast
    end

    test "builds nested loops" do
      # for i = 1, 10 do
      #   for j = 1, 10 do
      #     print(i * j)
      #   end
      # end
      ast =
        chunk([
          for_num("i", number(1), number(10), [
            for_num("j", number(1), number(10), [
              call_stmt(call(var("print"), [binop(:mul, var("i"), var("j"))]))
            ])
          ])
        ])

      assert %Chunk{
               block: %Block{
                 stmts: [
                   %Statement.ForNum{
                     body: %Block{
                       stmts: [%Statement.ForNum{}]
                     }
                   }
                 ]
               }
             } = ast
    end

    test "builds table with complex expressions" do
      # {
      #   x = 1 + 2,
      #   y = func(),
      #   [key] = value,
      #   nested = {a = 1, b = 2}
      # }
      tbl =
        table([
          {:record, string("x"), binop(:add, number(1), number(2))},
          {:record, string("y"), call(var("func"), [])},
          {:record, var("key"), var("value")},
          {:record, string("nested"),
           table([
             {:record, string("a"), number(1)},
             {:record, string("b"), number(2)}
           ])}
        ])

      assert %Expr.Table{
               fields: [
                 {:record, %Expr.String{value: "x"}, %Expr.BinOp{}},
                 {:record, %Expr.String{value: "y"}, %Expr.Call{}},
                 {:record, %Expr.Var{}, %Expr.Var{}},
                 {:record, %Expr.String{value: "nested"}, %Expr.Table{}}
               ]
             } = tbl
    end
  end

  describe "integration with parser" do
    test "builder output can be printed and reparsed" do
      # Build an AST using builder
      ast =
        chunk([
          local(["x"], [number(10)]),
          local(["y"], [number(20)]),
          assign([var("z")], [binop(:add, var("x"), var("y"))]),
          call_stmt(call(var("print"), [var("z")]))
        ])

      # Print it
      code = Lua.AST.PrettyPrinter.print(ast)

      # Parse it back
      {:ok, reparsed} = Lua.Parser.parse(code)

      # Should have same structure (ignoring meta)
      assert length(ast.block.stmts) == length(reparsed.block.stmts)
    end
  end
end

defmodule Lua.AST.Builder do
  @moduledoc """
  Helpers for programmatically constructing AST nodes.

  Provides a convenient API for building AST without manually
  creating all the struct fields. Useful for:
  - Code generation
  - AST transformations
  - Testing
  - Metaprogramming with quote/unquote

  ## Examples

      import Lua.AST.Builder

      # Build a simple expression: 2 + 2
      binop(:add, number(2), number(2))

      # Build a local assignment: local x = 42
      local(["x"], [number(42)])

      # Build a function: function add(a, b) return a + b end
      func_decl("add", ["a", "b"], [
        return_stmt([binop(:add, var("a"), var("b"))])
      ])
  """

  alias Lua.AST.{Chunk, Block, Meta, Expr, Statement}

  # Chunk and Block

  @doc """
  Creates a Chunk node.

  ## Examples

      chunk([local(["x"], [number(42)])])
  """
  @spec chunk([Statement.t()], Meta.t() | nil) :: Chunk.t()
  def chunk(stmts, meta \\ nil) do
    %Chunk{
      block: block(stmts, meta),
      meta: meta
    }
  end

  @doc """
  Creates a Block node.

  ## Examples

      block([
        local(["x"], [number(10)]),
        assign([var("x")], [number(20)])
      ])
  """
  @spec block([Statement.t()], Meta.t() | nil) :: Block.t()
  def block(stmts, meta \\ nil) do
    %Block{
      stmts: stmts,
      meta: meta
    }
  end

  # Literal expressions

  @doc "Creates a nil literal"
  @spec nil_lit(Meta.t() | nil) :: Expr.Nil.t()
  def nil_lit(meta \\ nil), do: %Expr.Nil{meta: meta}

  @doc "Creates a boolean literal"
  @spec bool(boolean(), Meta.t() | nil) :: Expr.Bool.t()
  def bool(value, meta \\ nil), do: %Expr.Bool{value: value, meta: meta}

  @doc "Creates a number literal"
  @spec number(number(), Meta.t() | nil) :: Expr.Number.t()
  def number(value, meta \\ nil), do: %Expr.Number{value: value, meta: meta}

  @doc "Creates a string literal"
  @spec string(String.t(), Meta.t() | nil) :: Expr.String.t()
  def string(value, meta \\ nil), do: %Expr.String{value: value, meta: meta}

  @doc "Creates a vararg expression (...)"
  @spec vararg(Meta.t() | nil) :: Expr.Vararg.t()
  def vararg(meta \\ nil), do: %Expr.Vararg{meta: meta}

  # Variable and access

  @doc "Creates a variable reference"
  @spec var(String.t(), Meta.t() | nil) :: Expr.Var.t()
  def var(name, meta \\ nil), do: %Expr.Var{name: name, meta: meta}

  @doc """
  Creates a property access (obj.prop)

  ## Examples

      property(var("io"), "write")  # io.write
  """
  @spec property(Expr.t(), String.t(), Meta.t() | nil) :: Expr.Property.t()
  def property(table, field, meta \\ nil) do
    %Expr.Property{
      table: table,
      field: field,
      meta: meta
    }
  end

  @doc """
  Creates an index access (obj[index])

  ## Examples

      index(var("t"), number(1))  # t[1]
  """
  @spec index(Expr.t(), Expr.t(), Meta.t() | nil) :: Expr.Index.t()
  def index(table, key, meta \\ nil) do
    %Expr.Index{
      table: table,
      key: key,
      meta: meta
    }
  end

  # Operators

  @doc """
  Creates a binary operation.

  ## Operators

  - `:add`, `:sub`, `:mul`, `:div`, `:floor_div`, `:mod`, `:pow`
  - `:concat`
  - `:eq`, `:ne`, `:lt`, `:gt`, `:le`, `:ge`
  - `:and`, `:or`

  ## Examples

      binop(:add, number(2), number(3))  # 2 + 3
      binop(:lt, var("x"), number(10))    # x < 10
  """
  @spec binop(atom(), Expr.t(), Expr.t(), Meta.t() | nil) :: Expr.BinOp.t()
  def binop(op, left, right, meta \\ nil) do
    %Expr.BinOp{
      op: op,
      left: left,
      right: right,
      meta: meta
    }
  end

  @doc """
  Creates a unary operation.

  ## Operators

  - `:not` - logical not
  - `:neg` - negation (-)
  - `:len` - length operator (#)

  ## Examples

      unop(:neg, var("x"))   # -x
      unop(:not, var("flag")) # not flag
      unop(:len, var("list")) # #list
  """
  @spec unop(atom(), Expr.t(), Meta.t() | nil) :: Expr.UnOp.t()
  def unop(op, operand, meta \\ nil) do
    %Expr.UnOp{
      op: op,
      operand: operand,
      meta: meta
    }
  end

  # Table constructor

  @doc """
  Creates a table constructor.

  ## Field types

  - `{:list, expr}` - array-style field (value only)
  - `{:record, key_expr, value_expr}` - key-value field

  ## Examples

      # Empty table: {}
      table([])

      # Array: {1, 2, 3}
      table([
        {:list, number(1)},
        {:list, number(2)},
        {:list, number(3)}
      ])

      # Record: {x = 10, y = 20}
      table([
        {:record, string("x"), number(10)},
        {:record, string("y"), number(20)}
      ])
  """
  @spec table([{:list, Expr.t()} | {:record, Expr.t(), Expr.t()}], Meta.t() | nil) ::
          Expr.Table.t()
  def table(fields, meta \\ nil) do
    %Expr.Table{
      fields: fields,
      meta: meta
    }
  end

  # Function call

  @doc """
  Creates a function call.

  ## Examples

      call(var("print"), [string("hello")])  # print("hello")
      call(property(var("io"), "write"), [string("test")])  # io.write("test")
  """
  @spec call(Expr.t(), [Expr.t()], Meta.t() | nil) :: Expr.Call.t()
  def call(func, args, meta \\ nil) do
    %Expr.Call{
      func: func,
      args: args,
      meta: meta
    }
  end

  @doc """
  Creates a method call (obj:method(args))

  ## Examples

      method_call(var("file"), "read", [string("*a")])  # file:read("*a")
  """
  @spec method_call(Expr.t(), String.t(), [Expr.t()], Meta.t() | nil) :: Expr.MethodCall.t()
  def method_call(object, method, args, meta \\ nil) do
    %Expr.MethodCall{
      object: object,
      method: method,
      args: args,
      meta: meta
    }
  end

  # Function expression

  @doc """
  Creates a function expression.

  ## Examples

      # function(x, y) return x + y end
      function_expr(["x", "y"], [
        return_stmt([binop(:add, var("x"), var("y"))])
      ])

      # function(...) return ... end
      function_expr([], [return_stmt([vararg()])], vararg: true)
  """
  @spec function_expr([String.t()], [Statement.t()], keyword()) :: Expr.Function.t()
  def function_expr(params, body_stmts, opts \\ []) do
    params_with_vararg =
      if Keyword.get(opts, :vararg, false) do
        params ++ [:vararg]
      else
        params
      end

    %Expr.Function{
      params: params_with_vararg,
      body: block(body_stmts),
      meta: Keyword.get(opts, :meta)
    }
  end

  # Statements

  @doc """
  Creates an assignment statement.

  ## Examples

      # x = 10
      assign([var("x")], [number(10)])

      # x, y = 1, 2
      assign([var("x"), var("y")], [number(1), number(2)])
  """
  @spec assign([Expr.t()], [Expr.t()], Meta.t() | nil) :: Statement.Assign.t()
  def assign(targets, values, meta \\ nil) do
    %Statement.Assign{
      targets: targets,
      values: values,
      meta: meta
    }
  end

  @doc """
  Creates a local variable declaration.

  ## Examples

      # local x
      local(["x"], [])

      # local x = 10
      local(["x"], [number(10)])

      # local x, y = 1, 2
      local(["x", "y"], [number(1), number(2)])
  """
  @spec local([String.t()], [Expr.t()], Meta.t() | nil) :: Statement.Local.t()
  def local(names, values \\ [], meta \\ nil) do
    %Statement.Local{
      names: names,
      values: values,
      meta: meta
    }
  end

  @doc """
  Creates a local function declaration.

  ## Examples

      # local function add(a, b) return a + b end
      local_func("add", ["a", "b"], [
        return_stmt([binop(:add, var("a"), var("b"))])
      ])
  """
  @spec local_func(String.t(), [String.t()], [Statement.t()], keyword()) ::
          Statement.LocalFunc.t()
  def local_func(name, params, body_stmts, opts \\ []) do
    params_with_vararg =
      if Keyword.get(opts, :vararg, false) do
        params ++ [:vararg]
      else
        params
      end

    %Statement.LocalFunc{
      name: name,
      params: params_with_vararg,
      body: block(body_stmts),
      meta: Keyword.get(opts, :meta)
    }
  end

  @doc """
  Creates a function declaration.

  ## Examples

      # function add(a, b) return a + b end
      func_decl("add", ["a", "b"], [
        return_stmt([binop(:add, var("a"), var("b"))])
      ])

      # function math.add(a, b) return a + b end
      func_decl(["math", "add"], ["a", "b"], [...])
  """
  @spec func_decl(String.t() | [String.t()], [String.t()], [Statement.t()], keyword()) ::
          Statement.FuncDecl.t()
  def func_decl(name, params, body_stmts, opts \\ []) do
    name_parts = if is_binary(name), do: [name], else: name

    params_with_vararg =
      if Keyword.get(opts, :vararg, false) do
        params ++ [:vararg]
      else
        params
      end

    is_method = Keyword.get(opts, :is_method, false)

    %Statement.FuncDecl{
      name: name_parts,
      params: params_with_vararg,
      body: block(body_stmts),
      is_method: is_method,
      meta: Keyword.get(opts, :meta)
    }
  end

  @doc """
  Creates a function call statement.

  ## Examples

      call_stmt(call(var("print"), [string("hello")]))
  """
  @spec call_stmt(Expr.Call.t() | Expr.MethodCall.t(), Meta.t() | nil) :: Statement.CallStmt.t()
  def call_stmt(call_expr, meta \\ nil) do
    %Statement.CallStmt{
      call: call_expr,
      meta: meta
    }
  end

  @doc """
  Creates an if statement.

  ## Examples

      # if x > 0 then print(x) end
      if_stmt(
        binop(:gt, var("x"), number(0)),
        [call_stmt(call(var("print"), [var("x")]))]
      )

      # if x > 0 then ... elseif x < 0 then ... else ... end
      if_stmt(
        binop(:gt, var("x"), number(0)),
        [call_stmt(...)],
        elseif: [{binop(:lt, var("x"), number(0)), [call_stmt(...)]}],
        else: [call_stmt(...)]
      )
  """
  @spec if_stmt(Expr.t(), [Statement.t()], keyword()) :: Statement.If.t()
  def if_stmt(condition, then_stmts, opts \\ []) do
    %Statement.If{
      condition: condition,
      then_block: block(then_stmts),
      elseifs: Keyword.get(opts, :elseif, []) |> Enum.map(fn {c, s} -> {c, block(s)} end),
      else_block: if(else_stmts = Keyword.get(opts, :else), do: block(else_stmts)),
      meta: Keyword.get(opts, :meta)
    }
  end

  @doc """
  Creates a while loop.

  ## Examples

      # while x > 0 do x = x - 1 end
      while_stmt(
        binop(:gt, var("x"), number(0)),
        [assign([var("x")], [binop(:sub, var("x"), number(1))])]
      )
  """
  @spec while_stmt(Expr.t(), [Statement.t()], Meta.t() | nil) :: Statement.While.t()
  def while_stmt(condition, body_stmts, meta \\ nil) do
    %Statement.While{
      condition: condition,
      body: block(body_stmts),
      meta: meta
    }
  end

  @doc """
  Creates a repeat-until loop.

  ## Examples

      # repeat x = x - 1 until x <= 0
      repeat_stmt(
        [assign([var("x")], [binop(:sub, var("x"), number(1))])],
        binop(:le, var("x"), number(0))
      )
  """
  @spec repeat_stmt([Statement.t()], Expr.t(), Meta.t() | nil) :: Statement.Repeat.t()
  def repeat_stmt(body_stmts, condition, meta \\ nil) do
    %Statement.Repeat{
      body: block(body_stmts),
      condition: condition,
      meta: meta
    }
  end

  @doc """
  Creates a numeric for loop.

  ## Examples

      # for i = 1, 10 do print(i) end
      for_num("i", number(1), number(10), [
        call_stmt(call(var("print"), [var("i")]))
      ])

      # for i = 1, 10, 2 do print(i) end
      for_num("i", number(1), number(10), [...], step: number(2))
  """
  @spec for_num(String.t(), Expr.t(), Expr.t(), [Statement.t()], keyword()) ::
          Statement.ForNum.t()
  def for_num(var_name, start, limit, body_stmts, opts \\ []) do
    %Statement.ForNum{
      var: var_name,
      start: start,
      limit: limit,
      step: Keyword.get(opts, :step),
      body: block(body_stmts),
      meta: Keyword.get(opts, :meta)
    }
  end

  @doc """
  Creates a generic for loop (for-in).

  ## Examples

      # for k, v in pairs(t) do print(k, v) end
      for_in(
        ["k", "v"],
        [call(var("pairs"), [var("t")])],
        [call_stmt(call(var("print"), [var("k"), var("v")]))]
      )
  """
  @spec for_in([String.t()], [Expr.t()], [Statement.t()], Meta.t() | nil) :: Statement.ForIn.t()
  def for_in(vars, iterators, body_stmts, meta \\ nil) do
    %Statement.ForIn{
      vars: vars,
      iterators: iterators,
      body: block(body_stmts),
      meta: meta
    }
  end

  @doc """
  Creates a do block.

  ## Examples

      # do local x = 10; print(x) end
      do_block([
        local(["x"], [number(10)]),
        call_stmt(call(var("print"), [var("x")]))
      ])
  """
  @spec do_block([Statement.t()], Meta.t() | nil) :: Statement.Do.t()
  def do_block(body_stmts, meta \\ nil) do
    %Statement.Do{
      body: block(body_stmts),
      meta: meta
    }
  end

  @doc """
  Creates a return statement.

  ## Examples

      # return
      return_stmt([])

      # return 42
      return_stmt([number(42)])

      # return x, y
      return_stmt([var("x"), var("y")])
  """
  @spec return_stmt([Expr.t()], Meta.t() | nil) :: Statement.Return.t()
  def return_stmt(values, meta \\ nil) do
    %Statement.Return{
      values: values,
      meta: meta
    }
  end

  @doc "Creates a break statement"
  @spec break_stmt(Meta.t() | nil) :: Statement.Break.t()
  def break_stmt(meta \\ nil), do: %Statement.Break{meta: meta}

  @doc "Creates a goto statement"
  @spec goto_stmt(String.t(), Meta.t() | nil) :: Statement.Goto.t()
  def goto_stmt(label, meta \\ nil), do: %Statement.Goto{label: label, meta: meta}

  @doc "Creates a label"
  @spec label(String.t(), Meta.t() | nil) :: Statement.Label.t()
  def label(name, meta \\ nil), do: %Statement.Label{name: name, meta: meta}
end

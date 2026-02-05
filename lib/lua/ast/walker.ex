defmodule Lua.AST.Walker do
  @moduledoc """
  AST traversal utilities using the visitor pattern.

  Provides functions for walking, mapping, and reducing over AST nodes.

  ## Examples

      # Simple traversal (side effects)
      Walker.walk(ast, fn node ->
        IO.inspect(node)
      end)

      # Transform AST (double all numbers)
      Walker.map(ast, fn
        %Expr.Number{value: n} = node -> %{node | value: n * 2}
        node -> node
      end)

      # Accumulate values (collect all variable names)
      Walker.reduce(ast, [], fn
        %Expr.Var{name: name}, acc -> [name | acc]
        _node, acc -> acc
      end)

      # Post-order traversal
      Walker.walk(ast, fn node -> ... end, order: :post)
  """

  alias Lua.AST.{Chunk, Block, Expr, Stmt}

  @type ast_node ::
          Chunk.t()
          | Block.t()
          | Expr.t()
          | Stmt.t()

  @type visitor :: (ast_node -> any())
  @type mapper :: (ast_node -> ast_node)
  @type reducer :: (ast_node, acc :: any() -> any())

  @type order :: :pre | :post

  @doc """
  Walks the AST, calling the visitor function for each node.

  The visitor is called in pre-order by default (parent before children).
  Use `order: :post` for post-order traversal (children before parent).

  ## Options

  - `:order` - `:pre` (default) or `:post`

  ## Examples

      Walker.walk(ast, fn
        %Expr.Number{value: n} -> IO.puts("Found number: \#{n}")
        _node -> :ok
      end)
  """
  @spec walk(ast_node, visitor, keyword()) :: :ok
  def walk(node, visitor, opts \\ []) do
    order = Keyword.get(opts, :order, :pre)
    do_walk(node, visitor, order)
    :ok
  end

  @doc """
  Maps over the AST, transforming nodes with the mapper function.

  The mapper is called in post-order (children before parent) to ensure
  transformations propagate upward correctly.

  ## Examples

      # Double all numbers
      Walker.map(ast, fn
        %Expr.Number{value: n} = node -> %{node | value: n * 2}
        node -> node
      end)
  """
  @spec map(ast_node, mapper) :: ast_node
  def map(node, mapper) do
    do_map(node, mapper)
  end

  @doc """
  Reduces the AST to a single value by calling the reducer function for each node.

  The reducer is called in pre-order by default.

  ## Examples

      # Collect all variable names
      Walker.reduce(ast, [], fn
        %Expr.Var{name: name}, acc -> [name | acc]
        _node, acc -> acc
      end)

      # Count all nodes
      Walker.reduce(ast, 0, fn _node, acc -> acc + 1 end)
  """
  @spec reduce(ast_node, acc, reducer) :: acc when acc: any()
  def reduce(node, initial, reducer) do
    do_reduce(node, initial, reducer)
  end

  # Private implementation

  # Walk in pre-order or post-order
  defp do_walk(node, visitor, :pre) do
    visitor.(node)
    walk_children(node, visitor, :pre)
  end

  defp do_walk(node, visitor, :post) do
    walk_children(node, visitor, :post)
    visitor.(node)
  end

  defp walk_children(node, visitor, order) do
    children(node)
    |> Enum.each(fn child -> do_walk(child, visitor, order) end)
  end

  # Map (post-order to transform bottom-up)
  defp do_map(node, mapper) do
    mapped_children =
      case node do
        # Chunk
        %Chunk{block: block} = chunk ->
          %{chunk | block: do_map(block, mapper)}

        # Block
        %Block{stmts: stmts} = block ->
          %{block | stmts: Enum.map(stmts, &do_map(&1, mapper))}

        # Expressions
        %Expr.BinOp{left: left, right: right} = expr ->
          %{expr | left: do_map(left, mapper), right: do_map(right, mapper)}

        %Expr.UnOp{operand: operand} = expr ->
          %{expr | operand: do_map(operand, mapper)}

        %Expr.Table{fields: fields} = expr ->
          mapped_fields =
            Enum.map(fields, fn
              {:list, value} -> {:list, do_map(value, mapper)}
              {:record, key, value} -> {:record, do_map(key, mapper), do_map(value, mapper)}
            end)

          %{expr | fields: mapped_fields}

        %Expr.Call{func: func, args: args} = expr ->
          %{expr | func: do_map(func, mapper), args: Enum.map(args, &do_map(&1, mapper))}

        %Expr.MethodCall{object: obj, args: args} = expr ->
          %{expr | object: do_map(obj, mapper), args: Enum.map(args, &do_map(&1, mapper))}

        %Expr.Index{table: table, key: key} = expr ->
          %{expr | table: do_map(table, mapper), key: do_map(key, mapper)}

        %Expr.Property{table: table} = expr ->
          %{expr | table: do_map(table, mapper)}

        %Expr.Function{body: body} = expr ->
          %{expr | body: do_map(body, mapper)}

        # Statements
        %Stmt.Assign{targets: targets, values: values} = stmt ->
          %{
            stmt
            | targets: Enum.map(targets, &do_map(&1, mapper)),
              values: Enum.map(values, &do_map(&1, mapper))
          }

        %Stmt.Local{values: values} = stmt when is_list(values) ->
          %{stmt | values: Enum.map(values, &do_map(&1, mapper))}

        %Stmt.Local{} = stmt ->
          stmt

        %Stmt.LocalFunc{body: body} = stmt ->
          %{stmt | body: do_map(body, mapper)}

        %Stmt.FuncDecl{body: body} = stmt ->
          %{stmt | body: do_map(body, mapper)}

        %Stmt.CallStmt{call: call} = stmt ->
          %{stmt | call: do_map(call, mapper)}

        %Stmt.If{
          condition: cond,
          then_block: then_block,
          elseifs: elseifs,
          else_block: else_block
        } = stmt ->
          mapped_elseifs =
            Enum.map(elseifs, fn {c, b} -> {do_map(c, mapper), do_map(b, mapper)} end)

          mapped_else = if else_block, do: do_map(else_block, mapper), else: nil

          %{
            stmt
            | condition: do_map(cond, mapper),
              then_block: do_map(then_block, mapper),
              elseifs: mapped_elseifs,
              else_block: mapped_else
          }

        %Stmt.While{condition: cond, body: body} = stmt ->
          %{stmt | condition: do_map(cond, mapper), body: do_map(body, mapper)}

        %Stmt.Repeat{body: body, condition: cond} = stmt ->
          %{stmt | body: do_map(body, mapper), condition: do_map(cond, mapper)}

        %Stmt.ForNum{var: _var, start: start, limit: limit, step: step, body: body} = stmt ->
          mapped_step = if step, do: do_map(step, mapper), else: nil

          %{
            stmt
            | start: do_map(start, mapper),
              limit: do_map(limit, mapper),
              step: mapped_step,
              body: do_map(body, mapper)
          }

        %Stmt.ForIn{vars: _vars, iterators: iterators, body: body} = stmt ->
          %{
            stmt
            | iterators: Enum.map(iterators, &do_map(&1, mapper)),
              body: do_map(body, mapper)
          }

        %Stmt.Do{body: body} = stmt ->
          %{stmt | body: do_map(body, mapper)}

        %Stmt.Return{values: values} = stmt ->
          %{stmt | values: Enum.map(values, &do_map(&1, mapper))}

        # Leaf nodes (no children)
        _ ->
          node
      end

    mapper.(mapped_children)
  end

  # Reduce (pre-order accumulation)
  defp do_reduce(node, acc, reducer) do
    acc = reducer.(node, acc)

    children(node)
    |> Enum.reduce(acc, fn child, acc -> do_reduce(child, acc, reducer) end)
  end

  # Extract children for traversal
  defp children(node) do
    case node do
      # Chunk
      %Chunk{block: block} ->
        [block]

      # Block
      %Block{stmts: stmts} ->
        stmts

      # Expressions with children
      %Expr.BinOp{left: left, right: right} ->
        [left, right]

      %Expr.UnOp{operand: operand} ->
        [operand]

      %Expr.Table{fields: fields} ->
        extract_table_fields(fields)

      %Expr.Call{func: func, args: args} ->
        [func | args]

      %Expr.MethodCall{object: obj, args: args} ->
        [obj | args]

      %Expr.Index{table: table, key: key} ->
        [table, key]

      %Expr.Property{table: table} ->
        [table]

      %Expr.Function{body: body} ->
        [body]

      # Statements with children
      %Stmt.Assign{targets: targets, values: values} ->
        targets ++ values

      %Stmt.Local{values: values} when is_list(values) ->
        values

      %Stmt.LocalFunc{body: body} ->
        [body]

      %Stmt.FuncDecl{body: body} ->
        [body]

      %Stmt.CallStmt{call: call} ->
        [call]

      %Stmt.If{condition: cond, then_block: then_block, elseifs: elseifs, else_block: else_block} ->
        elseif_nodes = Enum.flat_map(elseifs, fn {c, b} -> [c, b] end)
        [cond, then_block | elseif_nodes] ++ if(else_block, do: [else_block], else: [])

      %Stmt.While{condition: cond, body: body} ->
        [cond, body]

      %Stmt.Repeat{body: body, condition: cond} ->
        [body, cond]

      %Stmt.ForNum{start: start, limit: limit, step: step, body: body} ->
        [start, limit] ++ if(step, do: [step], else: []) ++ [body]

      %Stmt.ForIn{iterators: iterators, body: body} ->
        iterators ++ [body]

      %Stmt.Do{body: body} ->
        [body]

      %Stmt.Return{values: values} ->
        values

      # Leaf nodes (no children)
      _ ->
        []
    end
  end

  defp extract_table_fields(fields) do
    Enum.flat_map(fields, fn
      {:list, value} -> [value]
      {:record, key, value} -> [key, value]
    end)
  end
end

defmodule Lua.AST.Ids do
  @moduledoc """
  Stamps AST nodes with chunk-unique identifiers.

  Compiler passes keep per-node tables — which registers a `local` claimed,
  which upvalue a `Var` resolved to, the close-upvalue watermark of a block.
  Keying those tables by the node term makes every read and write hash the
  node's whole subtree, so the deepest nodes (function bodies, blocks) — the
  ones that make the most useful keys — are also the most expensive ones.

  `assign/1` walks a parsed chunk once and writes a distinct integer into
  each node's `meta.id`, letting those tables key on a single word instead.
  Ids are unique across the whole chunk, including the bodies of nested
  functions.
  """

  alias Lua.AST.Block
  alias Lua.AST.Chunk
  alias Lua.AST.Expr
  alias Lua.AST.Meta
  alias Lua.AST.Statement

  @doc """
  Returns `chunk` with every reachable node stamped with a unique `meta.id`.

  Nodes the parser built without metadata gain a `Lua.AST.Meta` carrying only
  the id; nodes that already have one keep their positions and comments.
  """
  @spec assign(Chunk.t()) :: Chunk.t()
  def assign(%Chunk{} = chunk) do
    {chunk, _next_id} = number(chunk, 0)
    chunk
  end

  # Children are numbered before their parent, so a node's id is always
  # greater than every id inside it. Nothing relies on that ordering; it just
  # falls out of numbering on the way back up.

  defp number(%Chunk{block: block} = node, next) do
    {block, next} = number(block, next)
    {%{node | block: block, meta: with_id(node.meta, next)}, next + 1}
  end

  defp number(%Block{stmts: stmts} = node, next) do
    {stmts, next} = number_list(stmts, next, [])
    {%{node | stmts: stmts, meta: with_id(node.meta, next)}, next + 1}
  end

  # Expressions

  defp number(%Expr.Nil{} = node, next), do: {%{node | meta: with_id(node.meta, next)}, next + 1}
  defp number(%Expr.Bool{} = node, next), do: {%{node | meta: with_id(node.meta, next)}, next + 1}
  defp number(%Expr.Number{} = node, next), do: {%{node | meta: with_id(node.meta, next)}, next + 1}
  defp number(%Expr.String{} = node, next), do: {%{node | meta: with_id(node.meta, next)}, next + 1}
  defp number(%Expr.Var{} = node, next), do: {%{node | meta: with_id(node.meta, next)}, next + 1}
  defp number(%Expr.Vararg{} = node, next), do: {%{node | meta: with_id(node.meta, next)}, next + 1}

  defp number(%Expr.BinOp{left: left, right: right} = node, next) do
    {left, next} = number(left, next)
    {right, next} = number(right, next)
    {%{node | left: left, right: right, meta: with_id(node.meta, next)}, next + 1}
  end

  defp number(%Expr.UnOp{operand: operand} = node, next) do
    {operand, next} = number(operand, next)
    {%{node | operand: operand, meta: with_id(node.meta, next)}, next + 1}
  end

  defp number(%Expr.Table{fields: fields} = node, next) do
    {fields, next} = number_table_fields(fields, next, [])
    {%{node | fields: fields, meta: with_id(node.meta, next)}, next + 1}
  end

  defp number(%Expr.Call{func: func, args: args} = node, next) do
    {func, next} = number(func, next)
    {args, next} = number_list(args, next, [])
    {%{node | func: func, args: args, meta: with_id(node.meta, next)}, next + 1}
  end

  defp number(%Expr.MethodCall{object: object, args: args} = node, next) do
    {object, next} = number(object, next)
    {args, next} = number_list(args, next, [])
    {%{node | object: object, args: args, meta: with_id(node.meta, next)}, next + 1}
  end

  defp number(%Expr.Index{table: table, key: key} = node, next) do
    {table, next} = number(table, next)
    {key, next} = number(key, next)
    {%{node | table: table, key: key, meta: with_id(node.meta, next)}, next + 1}
  end

  defp number(%Expr.Property{table: table} = node, next) do
    {table, next} = number(table, next)
    {%{node | table: table, meta: with_id(node.meta, next)}, next + 1}
  end

  defp number(%Expr.Function{body: body} = node, next) do
    {body, next} = number(body, next)
    {%{node | body: body, meta: with_id(node.meta, next)}, next + 1}
  end

  defp number(%Expr.Paren{inner: inner} = node, next) do
    {inner, next} = number(inner, next)
    {%{node | inner: inner, meta: with_id(node.meta, next)}, next + 1}
  end

  # Statements

  defp number(%Statement.Break{} = node, next), do: {%{node | meta: with_id(node.meta, next)}, next + 1}
  defp number(%Statement.Goto{} = node, next), do: {%{node | meta: with_id(node.meta, next)}, next + 1}
  defp number(%Statement.Label{} = node, next), do: {%{node | meta: with_id(node.meta, next)}, next + 1}

  defp number(%Statement.Assign{targets: targets, values: values} = node, next) do
    {targets, next} = number_list(targets, next, [])
    {values, next} = number_list(values, next, [])
    {%{node | targets: targets, values: values, meta: with_id(node.meta, next)}, next + 1}
  end

  defp number(%Statement.Local{values: values} = node, next) do
    {values, next} = number_list(values, next, [])
    {%{node | values: values, meta: with_id(node.meta, next)}, next + 1}
  end

  defp number(%Statement.LocalFunc{body: body} = node, next) do
    {body, next} = number(body, next)
    {%{node | body: body, meta: with_id(node.meta, next)}, next + 1}
  end

  defp number(%Statement.FuncDecl{body: body} = node, next) do
    {body, next} = number(body, next)
    {%{node | body: body, meta: with_id(node.meta, next)}, next + 1}
  end

  defp number(%Statement.CallStmt{call: call} = node, next) do
    {call, next} = number(call, next)
    {%{node | call: call, meta: with_id(node.meta, next)}, next + 1}
  end

  defp number(%Statement.If{} = node, next) do
    %Statement.If{condition: condition, then_block: then_block, elseifs: elseifs, else_block: else_block} = node

    {condition, next} = number(condition, next)
    {then_block, next} = number(then_block, next)
    {elseifs, next} = number_elseifs(elseifs, next, [])
    {else_block, next} = number_optional(else_block, next)

    {%{
       node
       | condition: condition,
         then_block: then_block,
         elseifs: elseifs,
         else_block: else_block,
         meta: with_id(node.meta, next)
     }, next + 1}
  end

  defp number(%Statement.While{condition: condition, body: body} = node, next) do
    {condition, next} = number(condition, next)
    {body, next} = number(body, next)
    {%{node | condition: condition, body: body, meta: with_id(node.meta, next)}, next + 1}
  end

  defp number(%Statement.Repeat{body: body, condition: condition} = node, next) do
    {body, next} = number(body, next)
    {condition, next} = number(condition, next)
    {%{node | body: body, condition: condition, meta: with_id(node.meta, next)}, next + 1}
  end

  defp number(%Statement.ForNum{} = node, next) do
    %Statement.ForNum{start: start, limit: limit, step: step, body: body} = node

    {start, next} = number(start, next)
    {limit, next} = number(limit, next)
    {step, next} = number_optional(step, next)
    {body, next} = number(body, next)

    {%{node | start: start, limit: limit, step: step, body: body, meta: with_id(node.meta, next)}, next + 1}
  end

  defp number(%Statement.ForIn{iterators: iterators, body: body} = node, next) do
    {iterators, next} = number_list(iterators, next, [])
    {body, next} = number(body, next)
    {%{node | iterators: iterators, body: body, meta: with_id(node.meta, next)}, next + 1}
  end

  defp number(%Statement.Do{body: body} = node, next) do
    {body, next} = number(body, next)
    {%{node | body: body, meta: with_id(node.meta, next)}, next + 1}
  end

  defp number(%Statement.Return{values: values} = node, next) do
    {values, next} = number_list(values, next, [])
    {%{node | values: values, meta: with_id(node.meta, next)}, next + 1}
  end

  # Any node shape not listed above keeps its metadata untouched. It then has
  # no id, and the compiler falls back to keying by the node term — slower,
  # but still correct.
  defp number(node, next), do: {node, next}

  defp number_optional(nil, next), do: {nil, next}
  defp number_optional(node, next), do: number(node, next)

  defp number_list([], next, acc), do: {Enum.reverse(acc), next}

  defp number_list([node | rest], next, acc) do
    {node, next} = number(node, next)
    number_list(rest, next, [node | acc])
  end

  defp number_table_fields([], next, acc), do: {Enum.reverse(acc), next}

  defp number_table_fields([{:list, value} | rest], next, acc) do
    {value, next} = number(value, next)
    number_table_fields(rest, next, [{:list, value} | acc])
  end

  defp number_table_fields([{:record, key, value} | rest], next, acc) do
    {key, next} = number(key, next)
    {value, next} = number(value, next)
    number_table_fields(rest, next, [{:record, key, value} | acc])
  end

  defp number_elseifs([], next, acc), do: {Enum.reverse(acc), next}

  defp number_elseifs([{condition, block} | rest], next, acc) do
    {condition, next} = number(condition, next)
    {block, next} = number(block, next)
    number_elseifs(rest, next, [{condition, block} | acc])
  end

  defp with_id(nil, id), do: %Meta{id: id}
  defp with_id(meta, id), do: %{meta | id: id}
end

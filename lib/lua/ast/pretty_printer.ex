defmodule Lua.AST.PrettyPrinter do
  @moduledoc """
  Converts AST back to Lua source code.

  Produces readable, properly indented Lua code from AST structures.
  Useful for:
  - Round-trip testing (parse → print → parse)
  - Debugging AST transformations
  - Code generation

  ## Examples

      ast = Parser.parse("local x = 2 + 2")
      code = PrettyPrinter.print(ast)
      # => "local x = 2 + 2\\n"

      # With custom indentation
      PrettyPrinter.print(ast, indent: 4)
  """

  alias Lua.AST.{Chunk, Block, Expr, Stmt}

  @type ast_node ::
          Chunk.t()
          | Block.t()
          | Expr.t()
          | Stmt.t()

  @type opts :: [
          indent: pos_integer()
        ]

  @doc """
  Converts an AST node to Lua source code.

  ## Options

  - `:indent` - Number of spaces per indentation level (default: 2)

  ## Examples

      PrettyPrinter.print(ast)
      PrettyPrinter.print(ast, indent: 4)
  """
  @spec print(ast_node, opts) :: String.t()
  def print(node, opts \\ []) do
    indent_size = Keyword.get(opts, :indent, 2)
    do_print(node, 0, indent_size)
  end

  # Chunk
  defp do_print(%Chunk{block: block}, level, indent_size) do
    do_print(block, level, indent_size)
  end

  # Block
  defp do_print(%Block{stmts: stmts}, level, indent_size) do
    stmts
    |> Enum.map(&do_print(&1, level, indent_size))
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  # Expressions

  defp do_print(%Expr.Nil{}, _level, _indent_size), do: "nil"
  defp do_print(%Expr.Bool{value: true}, _level, _indent_size), do: "true"
  defp do_print(%Expr.Bool{value: false}, _level, _indent_size), do: "false"

  defp do_print(%Expr.Number{value: n}, _level, _indent_size) do
    # Format numbers nicely
    if is_float(n) and Float.floor(n) == n do
      # Integer-valued float
      "#{trunc(n)}.0"
    else
      "#{n}"
    end
  end

  defp do_print(%Expr.String{value: s}, _level, _indent_size) do
    # Escape special characters
    escaped =
      s
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\n", "\\n")
      |> String.replace("\t", "\\t")

    "\"#{escaped}\""
  end

  defp do_print(%Expr.Vararg{}, _level, _indent_size), do: "..."

  defp do_print(%Expr.Var{name: name}, _level, _indent_size), do: name

  defp do_print(%Expr.BinOp{op: op, left: left, right: right}, level, indent_size) do
    left_str = print_expr_with_parens(left, op, :left, level, indent_size)
    right_str = print_expr_with_parens(right, op, :right, level, indent_size)
    op_str = format_binop(op)

    "#{left_str} #{op_str} #{right_str}"
  end

  defp do_print(%Expr.UnOp{op: op, operand: operand}, level, indent_size) do
    operand_str = print_expr_with_parens(operand, op, :operand, level, indent_size)
    op_str = format_unop(op)

    "#{op_str}#{operand_str}"
  end

  defp do_print(%Expr.Table{fields: fields}, level, indent_size) do
    if fields == [] do
      "{}"
    else
      field_strs =
        Enum.map(fields, fn
          {:list, value} ->
            do_print(value, level + 1, indent_size)

          {:record, key, value} ->
            key_str = format_table_key(key, level + 1, indent_size)
            value_str = do_print(value, level + 1, indent_size)
            "#{key_str} = #{value_str}"
        end)

      "{#{Enum.join(field_strs, ", ")}}"
    end
  end

  defp do_print(%Expr.Call{func: func, args: args}, level, indent_size) do
    func_str = do_print(func, level, indent_size)
    args_str = Enum.map(args, &do_print(&1, level, indent_size)) |> Enum.join(", ")

    "#{func_str}(#{args_str})"
  end

  defp do_print(%Expr.MethodCall{object: obj, method: method, args: args}, level, indent_size) do
    obj_str = do_print(obj, level, indent_size)
    args_str = Enum.map(args, &do_print(&1, level, indent_size)) |> Enum.join(", ")

    "#{obj_str}:#{method}(#{args_str})"
  end

  defp do_print(%Expr.Index{table: table, key: key}, level, indent_size) do
    table_str = do_print(table, level, indent_size)
    key_str = do_print(key, level, indent_size)

    "#{table_str}[#{key_str}]"
  end

  defp do_print(%Expr.Property{table: table, field: field}, level, indent_size) do
    table_str = do_print(table, level, indent_size)
    "#{table_str}.#{field}"
  end

  defp do_print(%Expr.Function{params: params, body: body}, level, indent_size) do
    params_str =
      params
      |> Enum.map(fn
        :vararg -> "..."
        name -> name
      end)
      |> Enum.join(", ")

    body_str = print_block_body(body, level + 1, indent_size)

    "function(#{params_str})\n#{body_str}#{indent(level, indent_size)}end"
  end

  # Statements

  defp do_print(%Stmt.Assign{targets: targets, values: values}, level, indent_size) do
    targets_str = Enum.map(targets, &do_print(&1, level, indent_size)) |> Enum.join(", ")
    values_str = Enum.map(values, &do_print(&1, level, indent_size)) |> Enum.join(", ")

    "#{indent(level, indent_size)}#{targets_str} = #{values_str}"
  end

  defp do_print(%Stmt.Local{names: names, values: values}, level, indent_size) do
    names_str = Enum.join(names, ", ")

    if values && values != [] do
      values_str = Enum.map(values, &do_print(&1, level, indent_size)) |> Enum.join(", ")
      "#{indent(level, indent_size)}local #{names_str} = #{values_str}"
    else
      "#{indent(level, indent_size)}local #{names_str}"
    end
  end

  defp do_print(%Stmt.LocalFunc{name: name, params: params, body: body}, level, indent_size) do
    params_str =
      params
      |> Enum.map(fn
        :vararg -> "..."
        name -> name
      end)
      |> Enum.join(", ")

    body_str = print_block_body(body, level + 1, indent_size)

    "#{indent(level, indent_size)}local function #{name}(#{params_str})\n#{body_str}#{indent(level, indent_size)}end"
  end

  defp do_print(%Stmt.FuncDecl{name: name, params: params, body: body}, level, indent_size) do
    params_str =
      params
      |> Enum.map(fn
        :vararg -> "..."
        param_name -> param_name
      end)
      |> Enum.join(", ")

    body_str = print_block_body(body, level + 1, indent_size)

    "#{indent(level, indent_size)}function #{format_func_name(name)}(#{params_str})\n#{body_str}#{indent(level, indent_size)}end"
  end

  defp do_print(%Stmt.CallStmt{call: call}, level, indent_size) do
    "#{indent(level, indent_size)}#{do_print(call, level, indent_size)}"
  end

  defp do_print(
         %Stmt.If{
           condition: cond,
           then_block: then_block,
           elseifs: elseifs,
           else_block: else_block
         },
         level,
         indent_size
       ) do
    cond_str = do_print(cond, level, indent_size)
    then_str = print_block_body(then_block, level + 1, indent_size)

    elseif_strs =
      Enum.map(elseifs, fn {c, b} ->
        c_str = do_print(c, level, indent_size)
        b_str = print_block_body(b, level + 1, indent_size)
        "#{indent(level, indent_size)}elseif #{c_str} then\n#{b_str}"
      end)

    else_str =
      if else_block do
        b_str = print_block_body(else_block, level + 1, indent_size)
        "#{indent(level, indent_size)}else\n#{b_str}"
      else
        nil
      end

    parts = ["#{indent(level, indent_size)}if #{cond_str} then\n#{then_str}"] ++ elseif_strs

    parts =
      if else_str do
        parts ++ [else_str]
      else
        parts
      end

    Enum.join(parts, "") <> "#{indent(level, indent_size)}end"
  end

  defp do_print(%Stmt.While{condition: cond, body: body}, level, indent_size) do
    cond_str = do_print(cond, level, indent_size)
    body_str = print_block_body(body, level + 1, indent_size)

    "#{indent(level, indent_size)}while #{cond_str} do\n#{body_str}#{indent(level, indent_size)}end"
  end

  defp do_print(%Stmt.Repeat{body: body, condition: cond}, level, indent_size) do
    body_str = print_block_body(body, level + 1, indent_size)
    cond_str = do_print(cond, level, indent_size)

    "#{indent(level, indent_size)}repeat\n#{body_str}#{indent(level, indent_size)}until #{cond_str}"
  end

  defp do_print(
         %Stmt.ForNum{var: var, start: start, limit: limit, step: step, body: body},
         level,
         indent_size
       ) do
    start_str = do_print(start, level, indent_size)
    limit_str = do_print(limit, level, indent_size)
    body_str = print_block_body(body, level + 1, indent_size)

    step_str =
      if step do
        ", #{do_print(step, level, indent_size)}"
      else
        ""
      end

    "#{indent(level, indent_size)}for #{var} = #{start_str}, #{limit_str}#{step_str} do\n#{body_str}#{indent(level, indent_size)}end"
  end

  defp do_print(%Stmt.ForIn{vars: vars, iterators: iterators, body: body}, level, indent_size) do
    vars_str = Enum.join(vars, ", ")
    iterators_str = Enum.map(iterators, &do_print(&1, level, indent_size)) |> Enum.join(", ")
    body_str = print_block_body(body, level + 1, indent_size)

    "#{indent(level, indent_size)}for #{vars_str} in #{iterators_str} do\n#{body_str}#{indent(level, indent_size)}end"
  end

  defp do_print(%Stmt.Do{body: body}, level, indent_size) do
    body_str = print_block_body(body, level + 1, indent_size)

    "#{indent(level, indent_size)}do\n#{body_str}#{indent(level, indent_size)}end"
  end

  defp do_print(%Stmt.Return{values: values}, level, indent_size) do
    if values == [] do
      "#{indent(level, indent_size)}return"
    else
      values_str = Enum.map(values, &do_print(&1, level, indent_size)) |> Enum.join(", ")
      "#{indent(level, indent_size)}return #{values_str}"
    end
  end

  defp do_print(%Stmt.Break{}, level, indent_size) do
    "#{indent(level, indent_size)}break"
  end

  defp do_print(%Stmt.Goto{label: label}, level, indent_size) do
    "#{indent(level, indent_size)}goto #{label}"
  end

  defp do_print(%Stmt.Label{name: name}, level, indent_size) do
    "#{indent(level, indent_size)}::#{name}::"
  end

  # Helpers

  defp indent(level, indent_size) do
    String.duplicate(" ", level * indent_size)
  end

  defp print_block_body(%Block{stmts: stmts}, level, indent_size) do
    stmts
    |> Enum.map(&do_print(&1, level, indent_size))
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  # Add parentheses when needed for operator precedence
  defp print_expr_with_parens(expr, parent_op, position, level, indent_size) do
    expr_str = do_print(expr, level, indent_size)

    if needs_parens?(expr, parent_op, position) do
      "(#{expr_str})"
    else
      expr_str
    end
  end

  # Determine if parentheses are needed based on precedence
  defp needs_parens?(expr, parent_op, position) do
    case expr do
      %Expr.BinOp{op: child_op} ->
        parent_prec = binop_precedence(parent_op)
        child_prec = binop_precedence(child_op)

        cond do
          # Lower precedence always needs parens
          child_prec < parent_prec -> true
          # Same precedence needs parens if associativity doesn't match
          child_prec == parent_prec -> needs_parens_same_prec?(parent_op, position)
          # Higher precedence never needs parens
          true -> false
        end

      %Expr.UnOp{} ->
        # Unary ops have high precedence, rarely need parens
        case parent_op do
          # -2^3 should be -(2^3)
          :pow -> true
          _ -> false
        end

      _ ->
        false
    end
  end

  defp needs_parens_same_prec?(op, position) do
    # Right-associative operators need parens on the left
    # Left-associative operators need parens on the right
    case {is_right_assoc?(op), position} do
      {true, :left} -> true
      {false, :right} -> true
      _ -> false
    end
  end

  defp is_right_assoc?(op) do
    op in [:concat, :pow]
  end

  defp binop_precedence(op) do
    case op do
      :or -> 1
      :and -> 2
      :lt -> 3
      :gt -> 3
      :le -> 3
      :ge -> 3
      :ne -> 3
      :eq -> 3
      :concat -> 4
      :add -> 5
      :sub -> 5
      :mul -> 6
      :div -> 6
      :floor_div -> 6
      :mod -> 6
      :pow -> 8
      _ -> 0
    end
  end

  defp format_binop(op) do
    case op do
      :add -> "+"
      :sub -> "-"
      :mul -> "*"
      :div -> "/"
      :floor_div -> "//"
      :mod -> "%"
      :pow -> "^"
      :concat -> ".."
      :eq -> "=="
      :ne -> "~="
      :lt -> "<"
      :gt -> ">"
      :le -> "<="
      :ge -> ">="
      :and -> "and"
      :or -> "or"
      _ -> "<?>"
    end
  end

  defp format_unop(op) do
    case op do
      :not -> "not "
      :neg -> "-"
      :len -> "#"
      _ -> "<?>"
    end
  end

  defp format_table_key(key, level, indent_size) do
    case key do
      %Expr.String{value: s} ->
        # If it's a valid identifier, use shorthand
        if valid_identifier?(s) do
          s
        else
          "[#{do_print(key, level, indent_size)}]"
        end

      _ ->
        "[#{do_print(key, level, indent_size)}]"
    end
  end

  defp valid_identifier?(s) do
    # Check if string is a valid Lua identifier
    Regex.match?(~r/^[a-zA-Z_][a-zA-Z0-9_]*$/, s) and not lua_keyword?(s)
  end

  defp lua_keyword?(s) do
    s in ~w(and break do else elseif end false for function goto if in local nil not or repeat return then true until while)
  end

  defp format_func_name(parts) when is_list(parts) do
    Enum.join(parts, ".")
  end

  defp format_func_name(name) when is_binary(name) do
    name
  end
end

defmodule Lua.Parser do
  @moduledoc """
  Hand-written recursive descent parser for Lua 5.3.

  Uses Pratt parsing for operator precedence in expressions.
  """

  alias Lua.AST.Block
  alias Lua.AST.Chunk
  alias Lua.AST.Expr
  alias Lua.AST.Meta
  alias Lua.AST.Statement
  alias Lua.Lexer
  alias Lua.Parser.Comments
  alias Lua.Parser.Error
  alias Lua.Parser.Pratt

  @type token :: Lexer.token()
  @type parse_result(t) :: {:ok, t, [token()]} | {:error, term()}

  @doc """
  Parses Lua source code into an AST.

  Returns `{:ok, chunk}` on success or `{:error, formatted_error}` on failure.
  The error is a beautifully formatted string with context and suggestions.

  ## Examples

      iex> Lua.Parser.parse("local x = 42")
      {:ok, %Lua.AST.Chunk{...}}

      iex> {:error, error_msg} = Lua.Parser.parse("if x then")
      iex> String.contains?(error_msg, "Parse Error")
      true
  """
  @spec parse(String.t()) :: {:ok, Chunk.t()} | {:error, String.t()}
  def parse(code) when is_binary(code) do
    case Lexer.tokenize(code) do
      {:ok, tokens} ->
        case parse_chunk(tokens) do
          {:ok, chunk} ->
            {:ok, chunk}

          {:error, reason} ->
            error = convert_error(reason, code)
            formatted = Error.format(error, code)
            {:error, formatted}
        end

      {:error, reason} ->
        error = convert_lexer_error(reason, code)
        formatted = Error.format(error, code)
        {:error, formatted}
    end
  end

  @doc """
  Parses Lua source code and returns raw error information.

  Use this when you want to handle errors programmatically instead of
  displaying them to users.
  """
  @spec parse_raw(String.t()) :: {:ok, Chunk.t()} | {:error, term()}
  def parse_raw(code) when is_binary(code) do
    case Lexer.tokenize(code) do
      {:ok, tokens} ->
        parse_chunk(tokens)

      {:error, reason} ->
        {:error, {:lexer_error, reason}}
    end
  end

  @doc """
  Parses a chunk (top-level block) from a token list.
  """
  @spec parse_chunk([token()]) :: {:ok, Chunk.t()} | {:error, term()}
  def parse_chunk(tokens) do
    case parse_block(tokens) do
      {:ok, block, rest} ->
        case rest do
          [{:eof, _}] ->
            {:ok, Chunk.new(block)}

          [{type, _, pos} | _] ->
            {:error, {:unexpected_token, type, pos, "Expected end of input"}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Block parsing (sequence of statements)
  defp parse_block(tokens) do
    parse_block_acc(tokens, [])
  end

  defp parse_block_acc(tokens, stmts) do
    case peek(tokens) do
      # Block terminators
      {:keyword, terminator, _} when terminator in [:end, :else, :elseif, :until] ->
        {:ok, Block.new(Enum.reverse(stmts)), tokens}

      {:eof, _} ->
        {:ok, Block.new(Enum.reverse(stmts)), tokens}

      # Skip empty statements (semicolons)
      {:delimiter, :semicolon, _} ->
        {_, rest} = consume(tokens)
        parse_block_acc(rest, stmts)

      # Skip orphaned comments at end of block (before terminator)
      {:comment, _, _, _} ->
        # Check if comments are orphaned (followed only by terminator/EOF/semicolon)
        tokens_after_comments = skip_orphaned_comments(tokens)

        case peek(tokens_after_comments) do
          {:keyword, term, _} when term in [:end, :else, :elseif, :until] ->
            {:ok, Block.new(Enum.reverse(stmts)), tokens_after_comments}

          {:eof, _} ->
            {:ok, Block.new(Enum.reverse(stmts)), tokens_after_comments}

          # Comments followed by semicolons - skip both and continue
          {:delimiter, :semicolon, _} ->
            {_, rest} = consume(tokens_after_comments)
            parse_block_acc(rest, stmts)

          _ ->
            # Not orphaned, parse as normal statement (comments will be collected)
            case parse_stmt(tokens) do
              {:ok, stmt, rest} ->
                parse_block_acc(rest, [stmt | stmts])

              {:error, reason} ->
                {:error, reason}
            end
        end

      _ ->
        case parse_stmt(tokens) do
          {:ok, stmt, rest} ->
            parse_block_acc(rest, [stmt | stmts])

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # Skip comment tokens that are orphaned (not followed by a statement)
  defp skip_orphaned_comments([{:comment, _, _, _} | rest]), do: skip_orphaned_comments(rest)
  defp skip_orphaned_comments(tokens), do: tokens

  # Statement parsing with comment collection
  defp parse_stmt(tokens) do
    # Collect leading comments
    {leading_comments, tokens_after_comments} = Comments.collect_leading_comments(tokens)

    # Parse the actual statement
    case parse_stmt_inner(tokens_after_comments) do
      {:ok, stmt, rest} ->
        # Check for trailing comment on the same line
        stmt_pos = get_statement_position(stmt)
        {trailing_comment, final_rest} = Comments.check_trailing_comment(rest, stmt_pos)

        # Attach comments to the statement
        stmt_with_comments = attach_comments_to_stmt(stmt, leading_comments, trailing_comment)
        {:ok, stmt_with_comments, final_rest}

      error ->
        error
    end
  end

  defp parse_stmt_inner(tokens) do
    case peek(tokens) do
      {:keyword, :return, _} ->
        parse_return(tokens)

      {:keyword, :local, _} ->
        parse_local(tokens)

      {:keyword, :if, _} ->
        parse_if(tokens)

      {:keyword, :while, _} ->
        parse_while(tokens)

      {:keyword, :repeat, _} ->
        parse_repeat(tokens)

      {:keyword, :for, _} ->
        parse_for(tokens)

      {:keyword, :function, _} ->
        parse_function_decl(tokens)

      {:keyword, :do, _} ->
        parse_do(tokens)

      {:keyword, :break, _} ->
        parse_break(tokens)

      {:keyword, :goto, _} ->
        parse_goto(tokens)

      {:delimiter, :double_colon, _} ->
        parse_label(tokens)

      _ ->
        # Try to parse as assignment or function call
        parse_assign_or_call(tokens)
    end
  end

  # Placeholder implementations for statements (Phase 3)
  defp parse_return([{:keyword, :return, pos} | rest]) do
    case peek(rest) do
      # End of block or statement
      {:keyword, terminator, _} when terminator in [:end, :else, :elseif, :until] ->
        {:ok, %Statement.Return{values: [], meta: Meta.new(pos)}, rest}

      {:eof, _} ->
        {:ok, %Statement.Return{values: [], meta: Meta.new(pos)}, rest}

      {:delimiter, :semicolon, _} ->
        {_, rest2} = consume(rest)
        {:ok, %Statement.Return{values: [], meta: Meta.new(pos)}, rest2}

      _ ->
        case parse_expr_list(rest) do
          {:ok, exprs, rest2} ->
            {:ok, %Statement.Return{values: exprs, meta: Meta.new(pos)}, rest2}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp parse_local([{:keyword, :local, pos} | rest]) do
    case peek(rest) do
      {:keyword, :function, _} ->
        # local function name() ... end
        {_, rest2} = consume(rest)

        case expect(rest2, :identifier) do
          {:ok, {_, name, _}, rest3} ->
            with {:ok, _, rest4} <- expect(rest3, :delimiter, :lparen),
                 {:ok, params, rest5} <- parse_param_list(rest4),
                 {:ok, _, rest6} <- expect(rest5, :delimiter, :rparen),
                 {:ok, body, rest7} <- parse_block(rest6),
                 {:ok, _, rest8} <- expect(rest7, :keyword, :end) do
              {:ok, %Statement.LocalFunc{name: name, params: params, body: body, meta: Meta.new(pos)}, rest8}
            end

          {:error, reason} ->
            {:error, reason}
        end

      {:identifier, _, _} ->
        # local name1, name2 = expr1, expr2
        case parse_name_list(rest) do
          {:ok, names, rest2} ->
            case peek(rest2) do
              {:operator, :assign, _} ->
                {_, rest3} = consume(rest2)

                case parse_expr_list(rest3) do
                  {:ok, values, rest4} ->
                    {:ok, %Statement.Local{names: names, values: values, meta: Meta.new(pos)}, rest4}

                  {:error, reason} ->
                    {:error, reason}
                end

              _ ->
                # Local without initialization
                {:ok, %Statement.Local{names: names, values: [], meta: Meta.new(pos)}, rest2}
            end

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        {:error, {:unexpected_token, peek(rest), "Expected identifier or 'function' after 'local'"}}
    end
  end

  defp parse_if([{:keyword, :if, pos} | rest]) do
    with {:ok, condition, rest2} <- parse_expr(rest),
         {:ok, _, rest3} <- expect(rest2, :keyword, :then),
         {:ok, then_block, rest4} <- parse_block(rest3),
         {:ok, elseifs, else_block, rest5} <- parse_elseifs(rest4) do
      case expect(rest5, :keyword, :end) do
        {:ok, _, rest6} ->
          {:ok,
           %Statement.If{
             condition: condition,
             then_block: then_block,
             elseifs: elseifs,
             else_block: else_block,
             meta: Meta.new(pos)
           }, rest6}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp parse_elseifs(tokens) do
    case peek(tokens) do
      {:keyword, :elseif, _} ->
        {_, rest} = consume(tokens)

        with {:ok, condition, rest2} <- parse_expr(rest),
             {:ok, _, rest3} <- expect(rest2, :keyword, :then),
             {:ok, block, rest4} <- parse_block(rest3),
             {:ok, more_elseifs, else_block, rest5} <- parse_elseifs(rest4) do
          {:ok, [{condition, block} | more_elseifs], else_block, rest5}
        end

      {:keyword, :else, _} ->
        {_, rest} = consume(tokens)

        case parse_block(rest) do
          {:ok, else_block, rest2} ->
            {:ok, [], else_block, rest2}

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        {:ok, [], nil, tokens}
    end
  end

  defp parse_while([{:keyword, :while, pos} | rest]) do
    with {:ok, condition, rest2} <- parse_expr(rest),
         {:ok, _, rest3} <- expect(rest2, :keyword, :do),
         {:ok, body, rest4} <- parse_block(rest3),
         {:ok, _, rest5} <- expect(rest4, :keyword, :end) do
      {:ok, %Statement.While{condition: condition, body: body, meta: Meta.new(pos)}, rest5}
    end
  end

  defp parse_repeat([{:keyword, :repeat, pos} | rest]) do
    with {:ok, body, rest2} <- parse_block(rest),
         {:ok, _, rest3} <- expect(rest2, :keyword, :until),
         {:ok, condition, rest4} <- parse_expr(rest3) do
      {:ok, %Statement.Repeat{body: body, condition: condition, meta: Meta.new(pos)}, rest4}
    end
  end

  defp parse_for([{:keyword, :for, pos} | rest]) do
    case expect(rest, :identifier) do
      {:ok, {_, var, _}, rest2} ->
        case peek(rest2) do
          {:operator, :assign, _} ->
            # Numeric for: for var = start, limit, step do ... end
            {_, rest3} = consume(rest2)

            with {:ok, start, rest4} <- parse_expr(rest3),
                 {:ok, _, rest5} <- expect(rest4, :delimiter, :comma),
                 {:ok, limit, rest6} <- parse_expr(rest5),
                 {:ok, step, rest7} <- parse_for_step(rest6),
                 {:ok, _, rest8} <- expect(rest7, :keyword, :do),
                 {:ok, body, rest9} <- parse_block(rest8),
                 {:ok, _, rest10} <- expect(rest9, :keyword, :end) do
              {:ok,
               %Statement.ForNum{
                 var: var,
                 start: start,
                 limit: limit,
                 step: step,
                 body: body,
                 meta: Meta.new(pos)
               }, rest10}
            end

          {:delimiter, :comma, _} ->
            # Generic for: for var1, var2 in exprs do ... end
            parse_generic_for([var], rest2, pos)

          {:keyword, :in, _} ->
            # Generic for with single variable
            parse_generic_for([var], rest2, pos)

          _ ->
            {:error, {:unexpected_token, peek(rest2), "Expected '=' or 'in' after for variable"}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_for_step(tokens) do
    case peek(tokens) do
      {:delimiter, :comma, _} ->
        {_, rest} = consume(tokens)
        parse_expr(rest)

      _ ->
        {:ok, nil, tokens}
    end
  end

  defp parse_generic_for(vars, tokens, start_pos) do
    case peek(tokens) do
      {:delimiter, :comma, _} ->
        {_, rest} = consume(tokens)

        case expect(rest, :identifier) do
          {:ok, {_, var, _}, rest2} ->
            parse_generic_for(vars ++ [var], rest2, start_pos)

          {:error, reason} ->
            {:error, reason}
        end

      {:keyword, :in, _} ->
        {_, rest} = consume(tokens)

        with {:ok, iterators, rest2} <- parse_expr_list(rest),
             {:ok, _, rest3} <- expect(rest2, :keyword, :do),
             {:ok, body, rest4} <- parse_block(rest3),
             {:ok, _, rest5} <- expect(rest4, :keyword, :end) do
          {:ok,
           %Statement.ForIn{
             vars: vars,
             iterators: iterators,
             body: body,
             meta: Meta.new(start_pos)
           }, rest5}
        end

      _ ->
        {:error, {:unexpected_token, peek(tokens), "Expected ',' or 'in' in for loop"}}
    end
  end

  defp parse_function_decl([{:keyword, :function, pos} | rest]) do
    case parse_function_name(rest) do
      {:ok, name_parts, is_method, rest2} ->
        with {:ok, _, rest3} <- expect(rest2, :delimiter, :lparen),
             {:ok, params, rest4} <- parse_param_list(rest3),
             {:ok, _, rest5} <- expect(rest4, :delimiter, :rparen),
             {:ok, body, rest6} <- parse_block(rest5),
             {:ok, _, rest7} <- expect(rest6, :keyword, :end) do
          {:ok,
           %Statement.FuncDecl{
             name: name_parts,
             params: params,
             body: body,
             is_method: is_method,
             meta: Meta.new(pos)
           }, rest7}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_function_name(tokens) do
    case expect(tokens, :identifier) do
      {:ok, {_, name, _}, rest} ->
        parse_function_name_rest([name], rest)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_function_name_rest(names, tokens) do
    case peek(tokens) do
      {:delimiter, :dot, _} ->
        {_, rest} = consume(tokens)

        case expect(rest, :identifier) do
          {:ok, {_, name, _}, rest2} ->
            parse_function_name_rest(names ++ [name], rest2)

          {:error, reason} ->
            {:error, reason}
        end

      {:delimiter, :colon, _} ->
        {_, rest} = consume(tokens)

        case expect(rest, :identifier) do
          {:ok, {_, name, _}, rest2} ->
            {:ok, names ++ [name], true, rest2}

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        {:ok, names, false, tokens}
    end
  end

  defp parse_do([{:keyword, :do, pos} | rest]) do
    with {:ok, body, rest2} <- parse_block(rest),
         {:ok, _, rest3} <- expect(rest2, :keyword, :end) do
      {:ok, %Statement.Do{body: body, meta: Meta.new(pos)}, rest3}
    end
  end

  defp parse_break([{:keyword, :break, pos} | rest]) do
    {:ok, %Statement.Break{meta: Meta.new(pos)}, rest}
  end

  defp parse_goto([{:keyword, :goto, pos} | rest]) do
    case expect(rest, :identifier) do
      {:ok, {_, label, _}, rest2} ->
        {:ok, %Statement.Goto{label: label, meta: Meta.new(pos)}, rest2}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_label([{:delimiter, :double_colon, pos} | rest]) do
    case expect(rest, :identifier) do
      {:ok, {_, name, _}, rest2} ->
        case expect(rest2, :delimiter, :double_colon) do
          {:ok, _, rest3} ->
            {:ok, %Statement.Label{name: name, meta: Meta.new(pos)}, rest3}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_assign_or_call(tokens) do
    # This is the most complex case - we need to parse a potential lvalue or call
    # Start by parsing an expression (which could be a variable, call, property access, etc.)
    case parse_expr(tokens) do
      {:ok, expr, rest} ->
        case peek(rest) do
          {:operator, :assign, _} ->
            # It's an assignment
            parse_assignment([expr], rest)

          {:delimiter, :comma, _} ->
            # Multiple targets, must be assignment
            parse_assignment_targets([expr], rest)

          _ ->
            # It's a call statement (or error if not a call)
            case expr do
              %Expr.Call{} = call ->
                {:ok, %Statement.CallStmt{call: call, meta: nil}, rest}

              %Expr.MethodCall{} = call ->
                {:ok, %Statement.CallStmt{call: call, meta: nil}, rest}

              _ ->
                {:error, {:unexpected_expression, "Expression statement must be a function call"}}
            end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_assignment_targets(targets, [{:delimiter, :comma, _} | rest]) do
    case parse_expr(rest) do
      {:ok, expr, rest2} ->
        case peek(rest2) do
          {:delimiter, :comma, _} ->
            parse_assignment_targets(targets ++ [expr], rest2)

          {:operator, :assign, _} ->
            parse_assignment(targets ++ [expr], rest2)

          _ ->
            {:error, {:unexpected_token, peek(rest2), "Expected '=' or ',' in assignment"}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_assignment(targets, [{:operator, :assign, pos} | rest]) do
    case parse_expr_list(rest) do
      {:ok, values, rest2} ->
        # Create meta from first target's position
        meta =
          if targets != [] and hd(targets).meta do
            %{hd(targets).meta | start: hd(targets).meta.start || pos}
          else
            Meta.new(pos)
          end

        {:ok, %Statement.Assign{targets: targets, values: values, meta: meta}, rest2}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Helper: parse list of names (for local declarations, for loops)
  defp parse_name_list(tokens) do
    case expect(tokens, :identifier) do
      {:ok, {_, name, _}, rest} ->
        parse_name_list_rest([name], rest)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_name_list_rest(names, tokens) do
    case peek(tokens) do
      {:delimiter, :comma, _} ->
        {_, rest} = consume(tokens)

        case expect(rest, :identifier) do
          {:ok, {_, name, _}, rest2} ->
            parse_name_list_rest(names ++ [name], rest2)

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        {:ok, names, tokens}
    end
  end

  # Expression parsing with Pratt algorithm
  @doc """
  Parses an expression with minimum precedence.
  """
  @spec parse_expr([token()], non_neg_integer()) :: parse_result(Expr.t())
  def parse_expr(tokens, min_prec \\ 0) do
    # Parse prefix (primary or unary operator)
    case parse_prefix(tokens) do
      {:ok, left, rest} ->
        parse_infix(left, rest, min_prec)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Parse prefix expressions (primary expressions and unary operators)
  defp parse_prefix(tokens) do
    case peek(tokens) do
      # Skip comments in expressions
      {:comment, _, _, _} ->
        {_, rest} = consume(tokens)
        parse_prefix(rest)

      # Literals
      {:keyword, nil, pos} ->
        {_, rest} = consume(tokens)
        {:ok, %Expr.Nil{meta: Meta.new(pos)}, rest}

      {:keyword, true, pos} ->
        {_, rest} = consume(tokens)
        {:ok, %Expr.Bool{value: true, meta: Meta.new(pos)}, rest}

      {:keyword, false, pos} ->
        {_, rest} = consume(tokens)
        {:ok, %Expr.Bool{value: false, meta: Meta.new(pos)}, rest}

      {:number, value, pos} ->
        {_, rest} = consume(tokens)
        {:ok, %Expr.Number{value: value, meta: Meta.new(pos)}, rest}

      {:string, value, pos} ->
        {_, rest} = consume(tokens)
        {:ok, %Expr.String{value: value, meta: Meta.new(pos)}, rest}

      # Vararg
      {:operator, :vararg, pos} ->
        {_, rest} = consume(tokens)
        {:ok, %Expr.Vararg{meta: Meta.new(pos)}, rest}

      # Identifier (variable)
      {:identifier, name, pos} ->
        {_, rest} = consume(tokens)
        {:ok, %Expr.Var{name: name, meta: Meta.new(pos)}, rest}

      # Parenthesized expression
      {:delimiter, :lparen, _} ->
        parse_paren_expr(tokens)

      # Table constructor
      {:delimiter, :lbrace, _} ->
        parse_table(tokens)

      # Function expression
      {:keyword, :function, _} ->
        parse_function_expr(tokens)

      # Unary operators
      {:keyword, :not, pos} ->
        {_, rest} = consume(tokens)
        parse_unary(:not, pos, rest)

      {:operator, :sub, pos} ->
        {_, rest} = consume(tokens)
        parse_unary(:sub, pos, rest)

      {:operator, :len, pos} ->
        {_, rest} = consume(tokens)
        parse_unary(:len, pos, rest)

      {:operator, :bxor, pos} ->
        {_, rest} = consume(tokens)
        parse_unary(:bxor, pos, rest)

      {:eof, pos} ->
        {:error, {:unexpected_token, :eof, pos, "Expected expression"}}

      {type, _, pos} ->
        {:error, {:unexpected_token, type, pos, "Expected expression"}}

      nil ->
        {:error, {:unexpected_end, "Expected expression"}}
    end
  end

  defp parse_unary(op, pos, tokens) do
    unop = Pratt.token_to_unop(op)
    prec = Pratt.prefix_binding_power(op)

    case parse_expr(tokens, prec) do
      {:ok, operand, rest} ->
        {:ok, %Expr.UnOp{op: unop, operand: operand, meta: Meta.new(pos)}, rest}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Parse infix expressions (binary operators and postfix)
  defp parse_infix(left, tokens, min_prec) do
    case peek(tokens) do
      {:keyword, op, pos} when op in [:and, :or] ->
        if Pratt.is_binary_op?(op) do
          case Pratt.binding_power(op) do
            {left_bp, right_bp} when left_bp >= min_prec ->
              {_, rest} = consume(tokens)
              binop = Pratt.token_to_binop(op)

              case parse_expr(rest, right_bp) do
                {:ok, right, rest2} ->
                  new_left = %Expr.BinOp{
                    op: binop,
                    left: left,
                    right: right,
                    meta: Meta.new(pos)
                  }

                  parse_infix(new_left, rest2, min_prec)

                {:error, reason} ->
                  {:error, reason}
              end

            _ ->
              {:ok, left, tokens}
          end
        else
          {:ok, left, tokens}
        end

      {:operator, op, pos} ->
        if Pratt.is_binary_op?(op) do
          case Pratt.binding_power(op) do
            {left_bp, right_bp} when left_bp >= min_prec ->
              {_, rest} = consume(tokens)
              binop = Pratt.token_to_binop(op)

              case parse_expr(rest, right_bp) do
                {:ok, right, rest2} ->
                  new_left = %Expr.BinOp{
                    op: binop,
                    left: left,
                    right: right,
                    meta: Meta.new(pos)
                  }

                  parse_infix(new_left, rest2, min_prec)

                {:error, reason} ->
                  {:error, reason}
              end

            _ ->
              {:ok, left, tokens}
          end
        else
          {:ok, left, tokens}
        end

      # Postfix: function call
      {:delimiter, :lparen, _} ->
        case parse_call_args(tokens) do
          {:ok, args, rest} ->
            new_left = %Expr.Call{func: left, args: args, meta: nil}
            parse_infix(new_left, rest, min_prec)

          {:error, reason} ->
            {:error, reason}
        end

      # Postfix: function call with string literal (syntactic sugar)
      {:string, value, pos} ->
        string_arg = %Expr.String{value: value, meta: Meta.new(pos)}
        {_, rest} = consume(tokens)
        new_left = %Expr.Call{func: left, args: [string_arg], meta: nil}
        parse_infix(new_left, rest, min_prec)

      # Postfix: function call with table constructor (syntactic sugar)
      {:delimiter, :lbrace, _} ->
        case parse_table(tokens) do
          {:ok, table, rest} ->
            new_left = %Expr.Call{func: left, args: [table], meta: nil}
            parse_infix(new_left, rest, min_prec)

          {:error, reason} ->
            {:error, reason}
        end

      # Postfix: indexing
      {:delimiter, :lbracket, _} ->
        case parse_index(tokens) do
          {:ok, key, rest} ->
            new_left = %Expr.Index{table: left, key: key, meta: nil}
            parse_infix(new_left, rest, min_prec)

          {:error, reason} ->
            {:error, reason}
        end

      # Postfix: property access or method call
      {:delimiter, :dot, _} ->
        {_, rest} = consume(tokens)

        case expect(rest, :identifier) do
          {:ok, {_, field, _}, rest2} ->
            new_left = %Expr.Property{table: left, field: field, meta: nil}
            parse_infix(new_left, rest2, min_prec)

          {:error, reason} ->
            {:error, reason}
        end

      {:delimiter, :colon, _} ->
        {_, rest} = consume(tokens)

        case expect(rest, :identifier) do
          {:ok, {_, method, _}, rest2} ->
            # Method calls support syntactic sugar: obj:method"str" or obj:method{...}
            case rest2 do
              # Regular method call with parentheses
              [{:delimiter, :lparen, _} | _] ->
                case parse_call_args(rest2) do
                  {:ok, args, rest3} ->
                    new_left = %Expr.MethodCall{object: left, method: method, args: args, meta: nil}
                    parse_infix(new_left, rest3, min_prec)

                  {:error, reason} ->
                    {:error, reason}
                end

              # Method call with string literal (syntactic sugar)
              [{:string, value, pos} | rest3] ->
                string_arg = %Expr.String{value: value, meta: Meta.new(pos)}
                new_left = %Expr.MethodCall{object: left, method: method, args: [string_arg], meta: nil}
                parse_infix(new_left, rest3, min_prec)

              # Method call with table constructor (syntactic sugar)
              [{:delimiter, :lbrace, _} | _] ->
                case parse_table(rest2) do
                  {:ok, table, rest3} ->
                    new_left = %Expr.MethodCall{object: left, method: method, args: [table], meta: nil}
                    parse_infix(new_left, rest3, min_prec)

                  {:error, reason} ->
                    {:error, reason}
                end

              _ ->
                {:error, "Expected '(', string, or table after method name"}
            end

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        {:ok, left, tokens}
    end
  end

  # Parse parenthesized expression: (expr)
  defp parse_paren_expr([{:delimiter, :lparen, _} | rest]) do
    case parse_expr(rest) do
      {:ok, expr, rest2} ->
        case expect(rest2, :delimiter, :rparen) do
          {:ok, _, rest3} ->
            {:ok, expr, rest3}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Parse table constructor: { fields }
  defp parse_table([{:delimiter, :lbrace, pos} | rest]) do
    case parse_table_fields(rest, []) do
      {:ok, fields, rest2} ->
        case expect(rest2, :delimiter, :rbrace) do
          {:ok, _, rest3} ->
            {:ok, %Expr.Table{fields: Enum.reverse(fields), meta: Meta.new(pos)}, rest3}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_table_fields(tokens, acc) do
    case peek(tokens) do
      {:delimiter, :rbrace, _} ->
        {:ok, acc, tokens}

      _ ->
        case parse_table_field(tokens) do
          {:ok, field, rest} ->
            case peek(rest) do
              {:delimiter, :comma, _} ->
                {_, rest2} = consume(rest)
                parse_table_fields(rest2, [field | acc])

              {:delimiter, :semicolon, _} ->
                {_, rest2} = consume(rest)
                parse_table_fields(rest2, [field | acc])

              {:delimiter, :rbrace, _} ->
                {:ok, [field | acc], rest}

              _ ->
                {:error, {:unexpected_token, peek(rest), "Expected ',' or '}' in table"}}
            end

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp parse_table_field(tokens) do
    case peek(tokens) do
      # [expr] = expr (computed key)
      {:delimiter, :lbracket, _} ->
        {_, rest} = consume(tokens)

        with {:ok, key, rest2} <- parse_expr(rest),
             {:ok, _, rest3} <- expect(rest2, :delimiter, :rbracket),
             {:ok, _, rest4} <- expect(rest3, :operator, :assign),
             {:ok, value, rest5} <- parse_expr(rest4) do
          {:ok, {:record, key, value}, rest5}
        end

      # name = expr (named field)
      {:identifier, name, pos} ->
        rest = tl(tokens)

        case peek(rest) do
          {:operator, :assign, _} ->
            {_, rest2} = consume(rest)

            case parse_expr(rest2) do
              {:ok, value, rest3} ->
                key = %Expr.String{value: name, meta: Meta.new(pos)}
                {:ok, {:record, key, value}, rest3}

              {:error, reason} ->
                {:error, reason}
            end

          _ ->
            # Just an expression (list entry)
            case parse_expr(tokens) do
              {:ok, expr, rest2} ->
                {:ok, {:list, expr}, rest2}

              {:error, reason} ->
                {:error, reason}
            end
        end

      _ ->
        # Expression (list entry)
        case parse_expr(tokens) do
          {:ok, expr, rest} ->
            {:ok, {:list, expr}, rest}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # Parse function expression: function(params) body end
  defp parse_function_expr([{:keyword, :function, pos} | rest]) do
    with {:ok, _, rest2} <- expect(rest, :delimiter, :lparen),
         {:ok, params, rest3} <- parse_param_list(rest2),
         {:ok, _, rest4} <- expect(rest3, :delimiter, :rparen),
         {:ok, body, rest5} <- parse_block(rest4),
         {:ok, _, rest6} <- expect(rest5, :keyword, :end) do
      {:ok, %Expr.Function{params: params, body: body, meta: Meta.new(pos)}, rest6}
    end
  end

  defp parse_param_list(tokens) do
    parse_param_list_acc(tokens, [])
  end

  defp parse_param_list_acc(tokens, acc) do
    case peek(tokens) do
      {:delimiter, :rparen, _} ->
        {:ok, Enum.reverse(acc), tokens}

      {:operator, :vararg, _} ->
        {_, rest} = consume(tokens)
        {:ok, Enum.reverse([:vararg | acc]), rest}

      {:identifier, name, _} ->
        {_, rest} = consume(tokens)

        case peek(rest) do
          {:delimiter, :comma, _} ->
            {_, rest2} = consume(rest)
            parse_param_list_acc(rest2, [name | acc])

          _ ->
            {:ok, Enum.reverse([name | acc]), rest}
        end

      _ ->
        {:error, {:unexpected_token, peek(tokens), "Expected parameter name or ')'"}}
    end
  end

  # Parse function call arguments: (args)
  defp parse_call_args([{:delimiter, :lparen, _} | rest]) do
    parse_expr_list_until(rest, :rparen)
  end

  # Parse indexing: [key]
  defp parse_index([{:delimiter, :lbracket, _} | rest]) do
    case parse_expr(rest) do
      {:ok, key, rest2} ->
        case expect(rest2, :delimiter, :rbracket) do
          {:ok, _, rest3} ->
            {:ok, key, rest3}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Parse expression list: expr1, expr2, ...
  defp parse_expr_list(tokens) do
    parse_expr_list_acc(tokens, [])
  end

  defp parse_expr_list_acc(tokens, acc) do
    case parse_expr(tokens) do
      {:ok, expr, rest} ->
        case peek(rest) do
          {:delimiter, :comma, _} ->
            {_, rest2} = consume(rest)
            parse_expr_list_acc(rest2, [expr | acc])

          _ ->
            {:ok, Enum.reverse([expr | acc]), rest}
        end

      {:error, reason} ->
        if acc == [] do
          {:error, reason}
        else
          {:ok, Enum.reverse(acc), tokens}
        end
    end
  end

  defp parse_expr_list_until(tokens, terminator) do
    case peek(tokens) do
      {:delimiter, ^terminator, _} ->
        {_, rest} = consume(tokens)
        {:ok, [], rest}

      _ ->
        case parse_expr_list(tokens) do
          {:ok, exprs, rest} ->
            case expect(rest, :delimiter, terminator) do
              {:ok, _, rest2} ->
                {:ok, exprs, rest2}

              {:error, reason} ->
                {:error, reason}
            end

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # Token manipulation helpers

  defp peek([token | _]), do: token
  defp peek([]), do: nil

  defp consume([token | rest]), do: {token, rest}
  defp consume([]), do: {nil, []}

  # Expect a specific token type
  defp expect(tokens, expected_type) do
    case peek(tokens) do
      {^expected_type, _, _} = token ->
        {_, rest} = consume(tokens)
        {:ok, token, rest}

      {type, _, pos} when type != nil ->
        {:error, {:unexpected_token, type, pos, "Expected #{inspect(expected_type)}, got #{inspect(type)}"}}

      {type, pos} when is_map(pos) ->
        # Token without value (like :eof)
        {:error, {:unexpected_token, type, pos, "Expected #{inspect(expected_type)}, got #{inspect(type)}"}}

      nil ->
        {:error, {:unexpected_end, "Expected #{inspect(expected_type)}"}}
    end
  end

  # Expect a specific token type and value
  defp expect(tokens, expected_type, expected_value) do
    case peek(tokens) do
      {^expected_type, ^expected_value, _} = token ->
        {_, rest} = consume(tokens)
        {:ok, token, rest}

      {type, value, pos} when type != nil and value != nil ->
        {:error,
         {:unexpected_token, type, pos,
          "Expected #{inspect(expected_type)}:#{inspect(expected_value)}, got #{inspect(type)}:#{inspect(value)}"}}

      {type, pos} when is_map(pos) ->
        # Token without value (like :eof)
        {:error,
         {:unexpected_token, type, pos,
          "Expected #{inspect(expected_type)}:#{inspect(expected_value)}, got #{inspect(type)}"}}

      nil ->
        {:error, {:unexpected_end, "Expected #{inspect(expected_type)}:#{inspect(expected_value)}"}}
    end
  end

  # Error conversion helpers

  defp convert_error({:unexpected_token, type, pos, message}, _code) do
    Error.new(:unexpected_token, message, pos, suggestion: suggest_for_token_error(type, message))
  end

  defp convert_error({:unexpected_end, message}, _code) do
    Error.new(:unexpected_end, message, nil,
      suggestion: """
      The parser reached the end of the file unexpectedly.
      Check for missing closing delimiters or keywords like 'end', ')', '}', or ']'.
      """
    )
  end

  defp convert_error({:unexpected_expression, message}, _code) do
    Error.new(:invalid_syntax, message, nil)
  end

  defp convert_error(other, _code) do
    Error.new(:invalid_syntax, "Parse error: #{inspect(other)}", nil)
  end

  defp convert_lexer_error({:unexpected_character, char, pos}, _code) do
    Error.new(:invalid_syntax, "Unexpected character: #{<<char>>}", pos,
      suggestion: """
      This character is not valid in Lua syntax.
      Check for typos or invisible characters.
      """
    )
  end

  defp convert_lexer_error({:unclosed_string, pos}, _code) do
    Error.new(:unclosed_delimiter, "Unclosed string literal", pos,
      suggestion: """
      Add a closing quote (" or ') to finish the string.
      Strings cannot span multiple lines unless you use [[...]] syntax.
      """
    )
  end

  defp convert_lexer_error({:unclosed_long_string, pos}, _code) do
    Error.new(:unclosed_delimiter, "Unclosed long string [[...]]", pos,
      suggestion: "Add the closing ]] to finish the long string."
    )
  end

  defp convert_lexer_error({:unclosed_comment, pos}, _code) do
    Error.new(:unclosed_delimiter, "Unclosed multi-line comment --[[...]]", pos,
      suggestion: "Add the closing ]] to finish the comment."
    )
  end

  defp convert_lexer_error(other, _code) do
    Error.new(:lexer_error, "Lexer error: #{inspect(other)}", nil)
  end

  defp suggest_for_token_error(type, message) do
    cond do
      type == :eof ->
        "Reached end of file unexpectedly. Check for missing 'end' keywords or closing delimiters."

      String.contains?(message, "Expected 'end'") ->
        """
        Every block needs an 'end':
        - if/elseif/else ... end
        - while ... do ... end
        - for ... do ... end
        - function ... end
        - do ... end
        """

      String.contains?(message, "Expected 'then'") ->
        "In Lua, 'if' and 'elseif' conditions must be followed by 'then'."

      String.contains?(message, "Expected 'do'") ->
        "In Lua, 'while' and 'for' loops must have 'do' before the body."

      true ->
        nil
    end
  end

  # Helper functions for comment attachment

  # Extract position from statement for trailing comment detection
  defp get_statement_position(%{meta: meta}) when not is_nil(meta) do
    meta.start
  end

  defp get_statement_position(_), do: nil

  # Attach comments to a statement's meta
  defp attach_comments_to_stmt(stmt, leading_comments, trailing_comment) do
    updated_meta = Comments.attach_comments(stmt.meta, leading_comments, trailing_comment)
    %{stmt | meta: updated_meta}
  end
end

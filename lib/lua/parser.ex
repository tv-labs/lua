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
    case parse_to_error(code) do
      {:ok, chunk} -> {:ok, chunk}
      {:error, error} -> {:error, Error.format(error, code)}
    end
  end

  @doc """
  Parses Lua source code and returns structured errors.

  Unlike `parse/1`, which returns a pre-formatted display string, this
  returns the `t:Lua.Parser.Error.t/0` structs directly so consumers can
  render errors in their own UI (editors, LSPs, web frontends) without
  scraping the formatted output. Use `Lua.Parser.Error.to_map/2` to obtain a
  JSON-serializable shape.

  The error list always holds a single error today; the list shape leaves
  room for multi-error recovery without a breaking change.

  ## Examples

      iex> {:ok, %Lua.AST.Chunk{}} = Lua.Parser.parse_structured("local x = 42")

      iex> {:error, [error]} = Lua.Parser.parse_structured("if x then")
      iex> error.type
      :unexpected_token
  """
  @spec parse_structured(String.t()) :: {:ok, Chunk.t()} | {:error, [Error.t()]}
  def parse_structured(code) when is_binary(code) do
    case parse_to_error(code) do
      {:ok, chunk} -> {:ok, chunk}
      {:error, error} -> {:error, [error]}
    end
  end

  # Shared parse path producing a converted `Lua.Parser.Error` struct on
  # failure. `parse/1` formats it; `parse_structured/1` returns it. Keeping
  # both on this helper stops the display and structured paths from drifting.
  @spec parse_to_error(String.t()) :: {:ok, Chunk.t()} | {:error, Error.t()}
  defp parse_to_error(code) do
    case Lexer.tokenize(code) do
      {:ok, tokens} ->
        case parse_chunk(tokens) do
          {:ok, chunk} -> {:ok, chunk}
          {:error, reason} -> {:error, convert_error(reason, code)}
        end

      {:error, reason} ->
        {:error, convert_lexer_error(reason, code)}
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
        unexpected_token_error(rest, "Expected identifier or 'function' after 'local'")
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
            unexpected_token_error(rest2, "Expected '=' or 'in' after for variable")
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
        unexpected_token_error(tokens, "Expected ',' or 'in' in for loop")
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
    starting_pos = token_position(peek(tokens))

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
                {:ok, %Statement.CallStmt{call: call, meta: Meta.new(starting_pos)}, rest}

              %Expr.MethodCall{} = call ->
                {:ok, %Statement.CallStmt{call: call, meta: Meta.new(starting_pos)}, rest}

              other ->
                # Prefer the AST node's meta when populated; some postfix
                # expressions (e.g. Property, Index) currently have
                # `meta: nil`, so fall back to the position of the first
                # token we consumed.
                pos =
                  case other do
                    %{meta: %Meta{start: %{} = p}} -> p
                    %{meta: %{start: %{} = p}} -> p
                    _ -> starting_pos
                  end

                {:error, {:bare_expression, pos, other.__struct__}}
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
            unexpected_token_error(rest2, "Expected '=' or ',' in assignment")
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_assignment(targets, [{:operator, :assign, pos} | rest]) do
    case validate_assign_targets(targets) do
      :ok ->
        case parse_expr_list(rest) do
          {:ok, values, rest2} ->
            # Create meta from first target's position
            meta =
              if hd(targets).meta do
                %{hd(targets).meta | start: hd(targets).meta.start || pos}
              else
                Meta.new(pos)
              end

            {:ok, %Statement.Assign{targets: targets, values: values, meta: meta}, rest2}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, _} = err ->
        err
    end
  end

  # Per Lua 5.3 §3.3.3, the lhs of an assignment must be a `var`:
  # Name | prefixexp '[' exp ']' | prefixexp '.' Name. Anything else
  # (number, string, function call, parenthesised expression) is a
  # syntax error.
  defp validate_assign_targets(targets) do
    Enum.reduce_while(targets, :ok, fn target, :ok ->
      case target do
        %Expr.Var{} -> {:cont, :ok}
        %Expr.Property{} -> {:cont, :ok}
        %Expr.Index{} -> {:cont, :ok}
        other -> {:halt, {:error, {:invalid_assign_target, target_position(other), other.__struct__}}}
      end
    end)
  end

  defp target_position(%{meta: %Meta{start: %{} = pos}}), do: pos
  defp target_position(%{meta: %{start: %{} = pos}}), do: pos
  defp target_position(_), do: nil

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
        {:error, {:unexpected_end, "Expected expression", nil}}
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
  #
  # Per Lua 5.3 §3.4, parenthesised function calls and vararg
  # expressions adjust to exactly one result, so they're wrapped in
  # `Expr.Paren` to mark the boundary. Other inners are semantically
  # transparent and the parens are dropped.
  defp parse_paren_expr([{:delimiter, :lparen, pos} | rest]) do
    case parse_expr(rest) do
      {:ok, expr, rest2} ->
        case expect_closing(rest2, :rparen, :lparen, pos) do
          {:ok, rest3} ->
            {:ok, wrap_paren(expr, pos), rest3}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp wrap_paren(%Expr.Call{} = inner, pos), do: %Expr.Paren{inner: inner, meta: Meta.new(pos)}

  defp wrap_paren(%Expr.MethodCall{} = inner, pos), do: %Expr.Paren{inner: inner, meta: Meta.new(pos)}

  defp wrap_paren(%Expr.Vararg{} = inner, pos), do: %Expr.Paren{inner: inner, meta: Meta.new(pos)}

  defp wrap_paren(inner, _pos), do: inner

  # Parse table constructor: { fields }
  defp parse_table([{:delimiter, :lbrace, pos} | rest]) do
    case parse_table_fields(rest, [], pos) do
      {:ok, fields, rest2} ->
        case expect_closing(rest2, :rbrace, :lbrace, pos) do
          {:ok, rest3} ->
            {:ok, %Expr.Table{fields: Enum.reverse(fields), meta: Meta.new(pos)}, rest3}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_table_fields(tokens, acc, open_pos) do
    # Skip leading comments (and any orphaned trailing comments from a
    # previous field) before deciding whether we've hit the terminator
    # or another field.
    tokens = skip_comments(tokens)

    case peek(tokens) do
      {:delimiter, :rbrace, _} ->
        {:ok, acc, tokens}

      # The constructor ran off the end of input before a closing '}'.
      # Point at the opening brace (like '(' and '[') rather than emitting
      # a bare "expected ',' or '}', got eof" pinned to the end of the file.
      {:eof, _} ->
        {:error, {:unclosed_delimiter, :lbrace, open_pos}}

      _ ->
        case parse_table_field(tokens) do
          {:ok, field, rest} ->
            # Trailing comments can sit between a field and its separator
            # (or the closing brace). Skip them before the punctuation peek.
            rest = skip_comments(rest)

            case peek(rest) do
              {:delimiter, :comma, _} ->
                {_, rest2} = consume(rest)
                parse_table_fields(rest2, [field | acc], open_pos)

              {:delimiter, :semicolon, _} ->
                {_, rest2} = consume(rest)
                parse_table_fields(rest2, [field | acc], open_pos)

              {:delimiter, :rbrace, _} ->
                {:ok, [field | acc], rest}

              # Field parsed cleanly but the stream ended before a separator
              # or '}'. Genuinely unclosed — blame the opening brace.
              {:eof, _} ->
                {:error, {:unclosed_delimiter, :lbrace, open_pos}}

              _ ->
                unexpected_token_error(rest, "Expected ',' or '}' in table")
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
        unexpected_token_error(tokens, "Expected parameter name or ')'")
    end
  end

  # Parse function call arguments: (args)
  defp parse_call_args([{:delimiter, :lparen, open_pos} | rest]) do
    parse_expr_list_until(rest, :rparen, :lparen, open_pos)
  end

  # Parse indexing: [key]
  defp parse_index([{:delimiter, :lbracket, open_pos} | rest]) do
    case parse_expr(rest) do
      {:ok, key, rest2} ->
        case expect_closing(rest2, :rbracket, :lbracket, open_pos) do
          {:ok, rest3} ->
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
        # Comments can appear between an argument and the comma (e.g.
        # `f(1 -- one\n, 2)` or a trailing line-comment in calls.lua).
        # Only swallow them here if doing so exposes a comma — otherwise
        # leave the stream untouched so the statement-level comment
        # collection in `parse_stmt` can still attach a trailing comment
        # to the right node.
        case peek(skip_comments(rest)) do
          {:delimiter, :comma, _} ->
            {_, rest2} = consume(skip_comments(rest))
            parse_expr_list_acc(rest2, [expr | acc])

          _ ->
            {:ok, Enum.reverse([expr | acc]), rest}
        end

      {:error, reason} ->
        # Recover (treat the list as ended) ONLY when the failed sub-parse
        # made no progress — i.e. the next token simply cannot begin an
        # expression, so the caller's terminator check should produce the
        # error. If the sub-parse *committed* (consumed input before
        # failing), that deeper error is the real one and must propagate;
        # swallowing it here surfaces a misleading "expected <terminator>"
        # at the list boundary instead of pointing at the actual mistake.
        cond do
          acc == [] -> {:error, reason}
          committed?(reason, tokens) -> {:error, reason}
          true -> {:ok, Enum.reverse(acc), tokens}
        end
    end
  end

  # A sub-parse "committed" if it consumed input before failing. We detect
  # this by comparing the error's byte offset against the offset of the
  # token the sub-parse started on: an error positioned strictly past the
  # start means tokens were consumed. `:unexpected_end` (EOF) is always
  # committed — running out of input mid-list is a real error, never a
  # clean list terminator. A missing position falls back to "not
  # committed", preserving the previous recovery behaviour.
  defp committed?({:unexpected_end, _message, _pos}, _tokens), do: true

  defp committed?(reason, tokens) do
    with %{byte_offset: error_offset} <- error_position(reason),
         {_, _, %{byte_offset: start_offset}} <- peek(tokens) do
      error_offset > start_offset
    else
      _ -> false
    end
  end

  defp error_position({:unexpected_token, _type, pos, _message}), do: pos
  defp error_position({:bare_expression, pos, _expr_struct}), do: pos
  defp error_position({:invalid_assign_target, pos, _expr_struct}), do: pos
  defp error_position({:unclosed_delimiter, _delimiter, open_pos}), do: open_pos
  defp error_position(_), do: nil

  defp parse_expr_list_until(tokens, terminator, delimiter, open_pos) do
    tokens = skip_comments(tokens)

    case peek(tokens) do
      {:delimiter, ^terminator, _} ->
        {_, rest} = consume(tokens)
        {:ok, [], rest}

      # Opened and ran straight off the end of input (e.g. `f(` at EOF).
      # Blame the opener, matching the args-then-EOF case below, instead
      # of a bare "Expected expression" pinned to the end of the file.
      {:eof, _} ->
        {:error, {:unclosed_delimiter, delimiter, open_pos}}

      _ ->
        case parse_expr_list(tokens) do
          {:ok, exprs, rest} ->
            # Trailing comments can sit between the last expression and
            # the terminator (e.g. `f(1, 2 -- note\n)`).
            rest = skip_comments(rest)

            case expect_closing(rest, terminator, delimiter, open_pos) do
              {:ok, rest2} ->
                {:ok, exprs, rest2}

              {:error, reason} ->
                {:error, reason}
            end

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # Expect a closing delimiter. When the stream is exhausted (EOF), the
  # opener was never closed — report it against the opening position (with a
  # "add a closing X at line N" suggestion) rather than a bare "expected X,
  # got eof" pinned to the end of the file. A non-EOF mismatch keeps the
  # specific "expected X, got <token>" error pointing at the offending token.
  defp expect_closing(tokens, terminator, delimiter, open_pos) do
    case expect(tokens, :delimiter, terminator) do
      {:ok, _, rest} ->
        {:ok, rest}

      {:error, {:unexpected_token, :eof, _close_pos, _msg}} ->
        {:error, {:unclosed_delimiter, delimiter, open_pos}}

      {:error, {:unexpected_end, _msg, _close_pos}} ->
        {:error, {:unclosed_delimiter, delimiter, open_pos}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Token manipulation helpers

  defp peek([token | _]), do: token
  defp peek([]), do: nil

  defp consume([token | rest]), do: {token, rest}
  defp consume([]), do: {nil, []}

  # Extracts the position map from a lexer token. Tokens come in two
  # shapes: 3-tuples `{type, value, pos}` for most tokens and 2-tuples
  # `{type, pos}` for `:eof`. Returns `nil` when no position is
  # available (empty token list).
  defp token_position({_type, _value, pos}) when is_map(pos), do: pos
  defp token_position({_type, pos}) when is_map(pos), do: pos
  defp token_position(_), do: nil

  # Build the canonical `{:unexpected_token, type, pos, message}` error
  # tuple from the token at the head of `tokens`. The renderer
  # (`convert_error/2` + `Lua.Parser.Error.format/2`) pattern-matches on
  # this exact 4-tuple shape; any other shape falls through to the
  # catch-all and is rendered as raw Elixir terms with no position.
  #
  # `peek/1` returns one of three shapes — a real 3-tuple token, a
  # 2-tuple `:eof` token, or `nil` (when the token list is empty
  # post-EOF). Each gets the appropriate canonical error.
  defp unexpected_token_error(tokens, message) do
    case peek(tokens) do
      {type, _value, pos} ->
        {:error, {:unexpected_token, type, pos, message}}

      {:eof, pos} ->
        {:error, {:unexpected_token, :eof, pos, message}}

      nil ->
        {:error, {:unexpected_end, message, nil}}
    end
  end

  # Drop leading comment tokens from a token stream.
  #
  # The lexer emits `{:comment, type, text, pos}` tuples (deliberately, so
  # tooling can attach them to the AST via `Lua.Parser.Comments`). They are
  # collected at statement and expression-prefix boundaries, but inside list
  # constructs (function arguments, table fields, parenthesized lists) a
  # trailing or interleaved comment must be skipped before peeking for a
  # separator (`,`, `;`) or terminator (`)`, `}`, `]`). Without this skip,
  # a comment leaks into `expect/3` and crashes the executor.
  defp skip_comments([{:comment, _, _, _} | rest]), do: skip_comments(rest)
  defp skip_comments(tokens), do: tokens

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
        {:error, {:unexpected_end, "Expected #{inspect(expected_type)}", nil}}
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
        {:error, {:unexpected_end, "Expected #{inspect(expected_type)}:#{inspect(expected_value)}", nil}}
    end
  end

  # Error conversion helpers

  defp convert_error({:unexpected_token, type, pos, message}, _code) do
    Error.new(:unexpected_token, message, pos, suggestion: suggest_for_token_error(type, message))
  end

  defp convert_error({:unclosed_delimiter, delimiter, open_pos}, _code) do
    Error.unclosed_delimiter(delimiter, open_pos)
  end

  defp convert_error({:unexpected_end, message, pos}, _code) do
    Error.new(:unexpected_end, message, pos,
      suggestion: """
      The parser reached the end of the file unexpectedly.
      Check for missing closing delimiters or keywords like 'end', ')', '}', or ']'.
      """
    )
  end

  defp convert_error({:bare_expression, pos, expr_struct}, _code) do
    {message, suggestion} = bare_expression_message(expr_struct)
    Error.new(:invalid_syntax, message, pos, suggestion: suggestion)
  end

  defp convert_error({:invalid_assign_target, pos, _expr_struct}, _code) do
    Error.new(
      :invalid_syntax,
      "syntax error near '='",
      pos,
      suggestion: "Only variables, table fields, and table indexes can appear on the left of '='."
    )
  end

  defp convert_error(other, _code) do
    Error.new(:invalid_syntax, "Parse error: #{inspect(other)}", nil)
  end

  # Picks a message and suggestion specific to the AST shape that
  # appeared as a bare statement. The fallback covers literals,
  # function expressions, and any future expression types we haven't
  # special-cased.
  defp bare_expression_message(Expr.BinOp) do
    {"A bare arithmetic or logical expression isn't a Lua statement.",
     "Did you mean to assign or return the result? For example, 'return <expression>'."}
  end

  defp bare_expression_message(Expr.UnOp) do
    {"A bare unary expression isn't a Lua statement.",
     "Did you mean to assign or return the result? For example, 'return <expression>'."}
  end

  defp bare_expression_message(Expr.Var) do
    {"A bare variable reference isn't a Lua statement.",
     "To call it as a function, add parentheses: 'name(...)'. " <>
       "To assign to it, write 'name = value'."}
  end

  defp bare_expression_message(struct) when struct in [Expr.Index, Expr.Property] do
    {"A bare table-access expression isn't a Lua statement.",
     "Did you mean to assign or read this field? " <>
       "For an assignment: 't.field = value'. To call: 't.field(...)'."}
  end

  defp bare_expression_message(struct)
       when struct in [Expr.Number, Expr.String, Expr.Bool, Expr.Nil, Expr.Vararg, Expr.Table] do
    {"A bare literal isn't a Lua statement.",
     "Lua statements are assignments, function calls, or control flow. " <>
       "To use this value, return it or assign it to a name."}
  end

  defp bare_expression_message(_struct) do
    {"This expression isn't a Lua statement.",
     "Lua statements are assignments, function calls, or control flow. " <>
       "To use this expression, return it or assign it to a name."}
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

      # `{ "key" = value }` is a common mistake — users reach for
      # JSON/map syntax. In Lua, only identifier keys may use the
      # `name = value` shorthand; every other key (including strings)
      # must be bracketed: `{ ["key"] = value }`.
      type == :operator and String.contains?(message, "Expected ',' or '}' in table") ->
        """
        In a Lua table constructor, only identifier keys may use the
        `name = value` shorthand. For string or computed keys, bracket
        them: `{ ["key"] = value }` instead of `{ "key" = value }`.
        """

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

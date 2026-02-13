defmodule Lua.Lexer do
  @moduledoc """
  Hand-written lexer for Lua 5.3 using Elixir binary pattern matching.

  Tokenizes Lua source code into a list of tokens with position tracking.
  """

  @type position :: %{line: pos_integer(), column: pos_integer(), byte_offset: non_neg_integer()}
  @type token ::
          {:keyword, atom(), position()}
          | {:identifier, String.t(), position()}
          | {:number, number(), position()}
          | {:string, String.t(), position()}
          | {:operator, atom(), position()}
          | {:delimiter, atom(), position()}
          | {:comment, :single | :multi, String.t(), position()}
          | {:eof, position()}

  @keywords ~w(
    and break do else elseif end false for function goto if in
    local nil not or repeat return then true until while
  )

  @doc """
  Tokenizes Lua source code into a list of tokens.

  ## Examples

      iex> Lua.Lexer.tokenize("local x = 42")
      {:ok, [
        {:keyword, :local, %{line: 1, column: 1, byte_offset: 0}},
        {:identifier, "x", %{line: 1, column: 7, byte_offset: 6}},
        {:operator, :assign, %{line: 1, column: 9, byte_offset: 8}},
        {:number, 42, %{line: 1, column: 11, byte_offset: 10}},
        {:eof, %{line: 1, column: 13, byte_offset: 12}}
      ]}
  """
  @spec tokenize(String.t()) :: {:ok, [token()]} | {:error, term()}
  def tokenize(code) when is_binary(code) do
    # Handle shebang on first line (Unix convention: #! means interpreter directive)
    code = strip_shebang(code)
    pos = %{line: 1, column: 1, byte_offset: 0}
    do_tokenize(code, [], pos)
  end

  # Strip shebang (#!) if it's the first line
  defp strip_shebang(<<"#!", rest::binary>>) do
    # Skip entire first line (everything up to and including the newline)
    case String.split(rest, ~r/\r\n|\r|\n/, parts: 2) do
      [_shebang_line, remaining] -> remaining
      [_only_shebang] -> ""
    end
  end

  defp strip_shebang(code), do: code

  # End of input
  defp do_tokenize(<<>>, acc, pos) do
    {:ok, Enum.reverse([{:eof, pos} | acc])}
  end

  # Whitespace (space, tab)
  defp do_tokenize(<<c, rest::binary>>, acc, pos) when c in [?\s, ?\t] do
    new_pos = advance_column(pos, 1)
    do_tokenize(rest, acc, new_pos)
  end

  # Newline (LF)
  defp do_tokenize(<<?\n, rest::binary>>, acc, pos) do
    new_pos = %{line: pos.line + 1, column: 1, byte_offset: pos.byte_offset + 1}
    do_tokenize(rest, acc, new_pos)
  end

  # Carriage return (CR, or CRLF)
  defp do_tokenize(<<?\r, ?\n, rest::binary>>, acc, pos) do
    new_pos = %{line: pos.line + 1, column: 1, byte_offset: pos.byte_offset + 2}
    do_tokenize(rest, acc, new_pos)
  end

  defp do_tokenize(<<?\r, rest::binary>>, acc, pos) do
    new_pos = %{line: pos.line + 1, column: 1, byte_offset: pos.byte_offset + 1}
    do_tokenize(rest, acc, new_pos)
  end

  # Comments: single-line (--) or multi-line (--[[ ... ]])
  defp do_tokenize(<<"--[", rest::binary>>, acc, pos) do
    # Check if it's a multi-line comment
    case rest do
      <<"[", _::binary>> ->
        # Multi-line comment --[[ ... ]]
        scan_multiline_comment(rest, acc, advance_column(pos, 3), pos, 0)

      _ ->
        # Single-line comment starting with --[
        scan_single_line_comment(rest, acc, advance_column(pos, 3), pos)
    end
  end

  defp do_tokenize(<<"--", rest::binary>>, acc, pos) do
    scan_single_line_comment(rest, acc, advance_column(pos, 2), pos)
  end

  # Strings: double-quoted
  defp do_tokenize(<<?", rest::binary>>, acc, pos) do
    scan_string(rest, "", acc, advance_column(pos, 1), pos, ?")
  end

  # Strings: single-quoted
  defp do_tokenize(<<?', rest::binary>>, acc, pos) do
    scan_string(rest, "", acc, advance_column(pos, 1), pos, ?')
  end

  # Strings: multi-line [[ ... ]] or [=[ ... ]=]
  defp do_tokenize(<<"[", rest::binary>>, acc, pos) do
    case scan_long_bracket(rest, 0) do
      {:ok, equals, after_bracket} ->
        scan_long_string(after_bracket, "", acc, advance_column(pos, 2 + equals), pos, equals)

      :error ->
        # Not a long string, treat as delimiter
        token = {:delimiter, :lbracket, pos}
        do_tokenize(rest, [token | acc], advance_column(pos, 1))
    end
  end

  # Numbers: hex (0x, 0X)
  defp do_tokenize(<<"0", x, rest::binary>>, acc, pos) when x in [?x, ?X] do
    scan_hex_number(rest, "", acc, advance_column(pos, 2), pos)
  end

  # Numbers: decimal or float
  defp do_tokenize(<<c, rest::binary>>, acc, pos) when c in ?0..?9 do
    scan_number(<<c, rest::binary>>, "", acc, pos, pos)
  end

  # Float starting with dot: .0, .5e3, etc.
  defp do_tokenize(<<".", c, rest::binary>>, acc, pos) when c in ?0..?9 do
    scan_float(rest, "0." <> <<c>>, acc, advance_column(pos, 2), pos)
  end

  # Three-character operators
  defp do_tokenize(<<"...", rest::binary>>, acc, pos) do
    token = {:operator, :vararg, pos}
    do_tokenize(rest, [token | acc], advance_column(pos, 3))
  end

  # Two-character operators
  defp do_tokenize(<<"==", rest::binary>>, acc, pos) do
    token = {:operator, :eq, pos}
    do_tokenize(rest, [token | acc], advance_column(pos, 2))
  end

  defp do_tokenize(<<"~=", rest::binary>>, acc, pos) do
    token = {:operator, :ne, pos}
    do_tokenize(rest, [token | acc], advance_column(pos, 2))
  end

  defp do_tokenize(<<"<=", rest::binary>>, acc, pos) do
    token = {:operator, :le, pos}
    do_tokenize(rest, [token | acc], advance_column(pos, 2))
  end

  defp do_tokenize(<<">=", rest::binary>>, acc, pos) do
    token = {:operator, :ge, pos}
    do_tokenize(rest, [token | acc], advance_column(pos, 2))
  end

  defp do_tokenize(<<"..", rest::binary>>, acc, pos) do
    token = {:operator, :concat, pos}
    do_tokenize(rest, [token | acc], advance_column(pos, 2))
  end

  defp do_tokenize(<<"::", rest::binary>>, acc, pos) do
    token = {:delimiter, :double_colon, pos}
    do_tokenize(rest, [token | acc], advance_column(pos, 2))
  end

  defp do_tokenize(<<"//", rest::binary>>, acc, pos) do
    token = {:operator, :floordiv, pos}
    do_tokenize(rest, [token | acc], advance_column(pos, 2))
  end

  # Bitwise shift operators (must come before single < and >)
  defp do_tokenize(<<"<<", rest::binary>>, acc, pos) do
    token = {:operator, :shl, pos}
    do_tokenize(rest, [token | acc], advance_column(pos, 2))
  end

  defp do_tokenize(<<">>", rest::binary>>, acc, pos) do
    token = {:operator, :shr, pos}
    do_tokenize(rest, [token | acc], advance_column(pos, 2))
  end

  # Single-character operators and delimiters
  defp do_tokenize(<<c, rest::binary>>, acc, pos) when c in [?+, ?-, ?*, ?/, ?%, ?^, ?#, ?&, ?|, ?~] do
    op =
      case c do
        ?+ -> :add
        ?- -> :sub
        ?* -> :mul
        ?/ -> :div
        ?% -> :mod
        ?^ -> :pow
        ?# -> :len
        ?& -> :band
        ?| -> :bor
        ?~ -> :bxor
      end

    token = {:operator, op, pos}
    do_tokenize(rest, [token | acc], advance_column(pos, 1))
  end

  defp do_tokenize(<<c, rest::binary>>, acc, pos) when c in [?<, ?>, ?=] do
    op =
      case c do
        ?< -> :lt
        ?> -> :gt
        ?= -> :assign
      end

    token = {:operator, op, pos}
    do_tokenize(rest, [token | acc], advance_column(pos, 1))
  end

  defp do_tokenize(<<c, rest::binary>>, acc, pos) when c in [?(, ?), ?{, ?}, ?], ?;, ?,, ?., ?:] do
    delim =
      case c do
        ?( -> :lparen
        ?) -> :rparen
        ?{ -> :lbrace
        ?} -> :rbrace
        ?] -> :rbracket
        ?; -> :semicolon
        ?, -> :comma
        ?. -> :dot
        ?: -> :colon
      end

    token = {:delimiter, delim, pos}
    do_tokenize(rest, [token | acc], advance_column(pos, 1))
  end

  # Identifiers and keywords
  defp do_tokenize(<<c, rest::binary>>, acc, pos) when c in ?a..?z or c in ?A..?Z or c == ?_ do
    scan_identifier(<<c, rest::binary>>, "", acc, pos, pos)
  end

  # Unexpected character
  defp do_tokenize(<<c, _rest::binary>>, _acc, pos) do
    {:error, {:unexpected_character, c, pos}}
  end

  # Scan single-line comment (collect text until newline)
  # pos is the current scanning position (after --), token_pos is where the comment started
  defp scan_single_line_comment(rest, acc, pos, token_pos) do
    scan_single_line_comment_content(rest, "", acc, pos, token_pos)
  end

  defp scan_single_line_comment_content(<<?\n, rest::binary>>, text, acc, pos, start_pos) do
    token = {:comment, :single, text, start_pos}
    new_pos = %{line: pos.line + 1, column: 1, byte_offset: pos.byte_offset + 1}
    do_tokenize(rest, [token | acc], new_pos)
  end

  defp scan_single_line_comment_content(<<?\r, ?\n, rest::binary>>, text, acc, pos, start_pos) do
    token = {:comment, :single, text, start_pos}
    new_pos = %{line: pos.line + 1, column: 1, byte_offset: pos.byte_offset + 2}
    do_tokenize(rest, [token | acc], new_pos)
  end

  defp scan_single_line_comment_content(<<?\r, rest::binary>>, text, acc, pos, start_pos) do
    token = {:comment, :single, text, start_pos}
    new_pos = %{line: pos.line + 1, column: 1, byte_offset: pos.byte_offset + 1}
    do_tokenize(rest, [token | acc], new_pos)
  end

  defp scan_single_line_comment_content(<<>>, text, acc, pos, start_pos) do
    token = {:comment, :single, text, start_pos}
    {:ok, Enum.reverse([{:eof, pos}, token | acc])}
  end

  defp scan_single_line_comment_content(<<c, rest::binary>>, text, acc, pos, start_pos) do
    scan_single_line_comment_content(rest, text <> <<c>>, acc, advance_column(pos, 1), start_pos)
  end

  # Scan multi-line comment --[[ ... ]] or --[=[ ... ]=]
  # pos is current scanning position, token_pos is where the comment started
  defp scan_multiline_comment(<<"[", rest::binary>>, acc, pos, token_pos, level) do
    scan_multiline_comment_text(rest, "", acc, advance_column(pos, 1), token_pos, level)
  end

  defp scan_multiline_comment_text(<<"]", rest::binary>>, text, acc, pos, start_pos, level) do
    case try_close_long_bracket(rest, level, 0) do
      {:ok, after_bracket} ->
        token = {:comment, :multi, text, start_pos}
        new_pos = advance_column(pos, 2 + level)
        do_tokenize(after_bracket, [token | acc], new_pos)

      :error ->
        scan_multiline_comment_text(
          rest,
          text <> "]",
          acc,
          advance_column(pos, 1),
          start_pos,
          level
        )
    end
  end

  defp scan_multiline_comment_text(<<?\n, rest::binary>>, text, acc, pos, start_pos, level) do
    new_pos = %{line: pos.line + 1, column: 1, byte_offset: pos.byte_offset + 1}
    scan_multiline_comment_text(rest, text <> "\n", acc, new_pos, start_pos, level)
  end

  defp scan_multiline_comment_text(<<>>, _text, _acc, pos, _start_pos, _level) do
    {:error, {:unclosed_comment, pos}}
  end

  defp scan_multiline_comment_text(<<c, rest::binary>>, text, acc, pos, start_pos, level) do
    scan_multiline_comment_text(
      rest,
      text <> <<c>>,
      acc,
      advance_column(pos, 1),
      start_pos,
      level
    )
  end

  # Scan quoted string
  defp scan_string(<<quote, rest::binary>>, str_acc, acc, pos, start_pos, quote) do
    # Closing quote
    token = {:string, str_acc, start_pos}
    do_tokenize(rest, [token | acc], pos)
  end

  # \z escape: skip all following whitespace
  defp scan_string(<<?\\, ?z, rest::binary>>, str_acc, acc, pos, start_pos, quote) do
    {remaining, new_pos} = skip_whitespace_in_string(rest, advance_column(pos, 2))
    scan_string(remaining, str_acc, acc, new_pos, start_pos, quote)
  end

  defp scan_string(<<?\\, esc, rest::binary>>, str_acc, acc, pos, start_pos, quote) do
    # Escape sequence
    case escape_char(esc) do
      {:ok, char} ->
        scan_string(rest, str_acc <> <<char>>, acc, advance_column(pos, 2), start_pos, quote)

      :error ->
        # Invalid escape, but continue scanning
        scan_string(rest, str_acc <> <<?\\, esc>>, acc, advance_column(pos, 2), start_pos, quote)
    end
  end

  defp scan_string(<<?\n, _rest::binary>>, _str_acc, _acc, pos, _start_pos, _quote) do
    {:error, {:unclosed_string, pos}}
  end

  defp scan_string(<<>>, _str_acc, _acc, pos, _start_pos, _quote) do
    {:error, {:unclosed_string, pos}}
  end

  defp scan_string(<<c, rest::binary>>, str_acc, acc, pos, start_pos, quote) do
    scan_string(rest, str_acc <> <<c>>, acc, advance_column(pos, 1), start_pos, quote)
  end

  # Escape character mapping
  defp escape_char(?a), do: {:ok, ?\a}
  defp escape_char(?b), do: {:ok, ?\b}
  defp escape_char(?f), do: {:ok, ?\f}
  defp escape_char(?n), do: {:ok, ?\n}
  defp escape_char(?r), do: {:ok, ?\r}
  defp escape_char(?t), do: {:ok, ?\t}
  defp escape_char(?v), do: {:ok, ?\v}
  defp escape_char(?\\), do: {:ok, ?\\}
  defp escape_char(?"), do: {:ok, ?"}
  defp escape_char(?'), do: {:ok, ?'}
  defp escape_char(_), do: :error

  # Helper for \z escape: skip all whitespace characters
  defp skip_whitespace_in_string(<<?\s, rest::binary>>, pos) do
    skip_whitespace_in_string(rest, advance_column(pos, 1))
  end

  defp skip_whitespace_in_string(<<?\t, rest::binary>>, pos) do
    skip_whitespace_in_string(rest, advance_column(pos, 1))
  end

  defp skip_whitespace_in_string(<<?\n, rest::binary>>, pos) do
    new_pos = %{line: pos.line + 1, column: 1, byte_offset: pos.byte_offset + 1}
    skip_whitespace_in_string(rest, new_pos)
  end

  defp skip_whitespace_in_string(<<?\r, ?\n, rest::binary>>, pos) do
    new_pos = %{line: pos.line + 1, column: 1, byte_offset: pos.byte_offset + 2}
    skip_whitespace_in_string(rest, new_pos)
  end

  defp skip_whitespace_in_string(<<?\r, rest::binary>>, pos) do
    new_pos = %{line: pos.line + 1, column: 1, byte_offset: pos.byte_offset + 1}
    skip_whitespace_in_string(rest, new_pos)
  end

  defp skip_whitespace_in_string(rest, pos) do
    {rest, pos}
  end

  # Scan long bracket for level: [[ or [=[ or [==[ etc.
  defp scan_long_bracket(rest, equals) do
    case rest do
      <<"=", after_eq::binary>> ->
        scan_long_bracket(after_eq, equals + 1)

      <<"[", after_bracket::binary>> ->
        {:ok, equals, after_bracket}

      _ ->
        :error
    end
  end

  # Try to close long bracket: ]] or ]=] or ]==] etc.
  defp try_close_long_bracket(rest, target_level, current_level) do
    if current_level == target_level do
      case rest do
        <<"]", after_bracket::binary>> ->
          {:ok, after_bracket}

        _ ->
          :error
      end
    else
      case rest do
        <<"=", after_eq::binary>> ->
          try_close_long_bracket(after_eq, target_level, current_level + 1)

        _ ->
          :error
      end
    end
  end

  # Scan long string [[ ... ]] or [=[ ... ]=]
  defp scan_long_string(<<"]", rest::binary>>, str_acc, acc, pos, start_pos, level) do
    case try_close_long_bracket(rest, level, 0) do
      {:ok, after_bracket} ->
        token = {:string, str_acc, start_pos}
        new_pos = advance_column(pos, 2 + level)
        do_tokenize(after_bracket, [token | acc], new_pos)

      :error ->
        scan_long_string(rest, str_acc <> "]", acc, advance_column(pos, 1), start_pos, level)
    end
  end

  defp scan_long_string(<<?\n, rest::binary>>, str_acc, acc, pos, start_pos, level) do
    new_pos = %{line: pos.line + 1, column: 1, byte_offset: pos.byte_offset + 1}
    scan_long_string(rest, str_acc <> "\n", acc, new_pos, start_pos, level)
  end

  defp scan_long_string(<<>>, _str_acc, _acc, pos, _start_pos, _level) do
    {:error, {:unclosed_long_string, pos}}
  end

  defp scan_long_string(<<c, rest::binary>>, str_acc, acc, pos, start_pos, level) do
    scan_long_string(rest, str_acc <> <<c>>, acc, advance_column(pos, 1), start_pos, level)
  end

  # Scan identifier or keyword
  defp scan_identifier(<<c, rest::binary>>, id_acc, acc, pos, start_pos)
       when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?_ do
    scan_identifier(rest, id_acc <> <<c>>, acc, advance_column(pos, 1), start_pos)
  end

  defp scan_identifier(rest, id_acc, acc, pos, start_pos) do
    # Check if it's a keyword
    token =
      if id_acc in @keywords do
        {:keyword, String.to_atom(id_acc), start_pos}
      else
        {:identifier, id_acc, start_pos}
      end

    do_tokenize(rest, [token | acc], pos)
  end

  # Scan decimal number
  defp scan_number(<<c, rest::binary>>, num_acc, acc, pos, start_pos) when c in ?0..?9 do
    scan_number(rest, num_acc <> <<c>>, acc, advance_column(pos, 1), start_pos)
  end

  defp scan_number(<<".", c, rest::binary>>, num_acc, acc, pos, start_pos) when c in ?0..?9 do
    # Decimal point with digit following: 0.5
    scan_float(rest, num_acc <> "." <> <<c>>, acc, advance_column(pos, 2), start_pos)
  end

  defp scan_number(<<"..", _rest::binary>> = rest, num_acc, acc, pos, start_pos) do
    # ".." is concat operator, not a decimal point: 0..5 → 0 .. 5
    finalize_number(num_acc, rest, acc, pos, start_pos)
  end

  defp scan_number(<<".", c, rest::binary>>, num_acc, acc, pos, start_pos) when c in [?e, ?E] do
    # "0.e5" → float with exponent
    scan_float(<<c, rest::binary>>, num_acc <> ".", acc, advance_column(pos, 1), start_pos)
  end

  defp scan_number(<<".", rest::binary>>, num_acc, acc, pos, start_pos) do
    # Trailing dot makes it a float: 0. → 0.0
    scan_float(rest, num_acc <> ".", acc, advance_column(pos, 1), start_pos)
  end

  defp scan_number(<<c, rest::binary>>, num_acc, acc, pos, start_pos) when c in [?e, ?E] do
    # Scientific notation
    scan_exponent(<<c, rest::binary>>, num_acc, acc, pos, start_pos)
  end

  defp scan_number(rest, num_acc, acc, pos, start_pos) do
    finalize_number(num_acc, rest, acc, pos, start_pos)
  end

  # Scan float part (after decimal point)
  defp scan_float(<<c, rest::binary>>, num_acc, acc, pos, start_pos) when c in ?0..?9 do
    scan_float(rest, num_acc <> <<c>>, acc, advance_column(pos, 1), start_pos)
  end

  defp scan_float(<<c, rest::binary>>, num_acc, acc, pos, start_pos) when c in [?e, ?E] do
    scan_exponent(<<c, rest::binary>>, num_acc, acc, pos, start_pos)
  end

  defp scan_float(rest, num_acc, acc, pos, start_pos) do
    finalize_number(num_acc, rest, acc, pos, start_pos)
  end

  # Scan scientific notation exponent
  defp scan_exponent(<<c, sign, rest::binary>>, num_acc, acc, pos, start_pos) when c in [?e, ?E] and sign in [?+, ?-] do
    scan_exponent_digits(rest, num_acc <> <<c, sign>>, acc, advance_column(pos, 2), start_pos)
  end

  defp scan_exponent(<<c, rest::binary>>, num_acc, acc, pos, start_pos) when c in [?e, ?E] do
    scan_exponent_digits(rest, num_acc <> <<c>>, acc, advance_column(pos, 1), start_pos)
  end

  defp scan_exponent_digits(<<c, rest::binary>>, num_acc, acc, pos, start_pos) when c in ?0..?9 do
    scan_exponent_digits(rest, num_acc <> <<c>>, acc, advance_column(pos, 1), start_pos)
  end

  defp scan_exponent_digits(rest, num_acc, acc, pos, start_pos) do
    finalize_number(num_acc, rest, acc, pos, start_pos)
  end

  # Scan hexadecimal number (0x...) — supports integers, hex floats (0xF0.0), and exponents (0xABCp-3)
  defp scan_hex_number(<<c, rest::binary>>, hex_acc, acc, pos, start_pos)
       when c in ?0..?9 or c in ?a..?f or c in ?A..?F do
    scan_hex_number(rest, hex_acc <> <<c>>, acc, advance_column(pos, 1), start_pos)
  end

  # Hex float: dot followed by hex digits
  defp scan_hex_number(<<".", rest::binary>>, hex_acc, acc, pos, start_pos) do
    scan_hex_frac(rest, hex_acc, "", acc, advance_column(pos, 1), start_pos)
  end

  # Hex float: binary exponent (p/P)
  defp scan_hex_number(<<p, rest::binary>>, hex_acc, acc, pos, start_pos) when p in [?p, ?P] do
    scan_hex_exp(rest, hex_acc, "", acc, advance_column(pos, 1), start_pos)
  end

  defp scan_hex_number(rest, hex_acc, acc, pos, start_pos) do
    case Integer.parse(hex_acc, 16) do
      {num, ""} ->
        token = {:number, num, start_pos}
        do_tokenize(rest, [token | acc], pos)

      _ ->
        {:error, {:invalid_hex_number, start_pos}}
    end
  end

  # Scan hex fractional digits after the dot
  defp scan_hex_frac(<<c, rest::binary>>, int_acc, frac_acc, acc, pos, start_pos)
       when c in ?0..?9 or c in ?a..?f or c in ?A..?F do
    scan_hex_frac(rest, int_acc, frac_acc <> <<c>>, acc, advance_column(pos, 1), start_pos)
  end

  # Hex float fractional part followed by exponent
  defp scan_hex_frac(<<p, rest::binary>>, int_acc, frac_acc, acc, pos, start_pos) when p in [?p, ?P] do
    scan_hex_exp(rest, int_acc, frac_acc, acc, advance_column(pos, 1), start_pos)
  end

  # Hex float fractional part without exponent
  defp scan_hex_frac(rest, int_acc, frac_acc, acc, pos, start_pos) do
    num = build_hex_float(int_acc, frac_acc, 0)
    token = {:number, num, start_pos}
    do_tokenize(rest, [token | acc], pos)
  end

  # Scan binary exponent (p/P followed by optional sign and decimal digits)
  defp scan_hex_exp(<<sign, rest::binary>>, int_acc, frac_acc, acc, pos, start_pos) when sign in [?+, ?-] do
    scan_hex_exp_digits(rest, int_acc, frac_acc, <<sign>>, acc, advance_column(pos, 1), start_pos)
  end

  defp scan_hex_exp(rest, int_acc, frac_acc, acc, pos, start_pos) do
    scan_hex_exp_digits(rest, int_acc, frac_acc, "", acc, pos, start_pos)
  end

  defp scan_hex_exp_digits(<<c, rest::binary>>, int_acc, frac_acc, exp_acc, acc, pos, start_pos) when c in ?0..?9 do
    scan_hex_exp_digits(rest, int_acc, frac_acc, exp_acc <> <<c>>, acc, advance_column(pos, 1), start_pos)
  end

  defp scan_hex_exp_digits(rest, int_acc, frac_acc, exp_acc, acc, pos, start_pos) do
    exp = if exp_acc == "" or exp_acc == "+" or exp_acc == "-", do: 0, else: String.to_integer(exp_acc)
    num = build_hex_float(int_acc, frac_acc, exp)
    token = {:number, num, start_pos}
    do_tokenize(rest, [token | acc], pos)
  end

  # Build a hex float value from integer hex digits, fractional hex digits, and binary exponent
  defp build_hex_float(int_hex, frac_hex, exp) do
    int_val = if int_hex == "", do: 0, else: String.to_integer(int_hex, 16)

    frac_val =
      if frac_hex == "" do
        0.0
      else
        frac_int = String.to_integer(frac_hex, 16)
        frac_int / :math.pow(16, String.length(frac_hex))
      end

    (int_val + frac_val) * :math.pow(2, exp)
  end

  # Finalize number token
  defp finalize_number(num_str, rest, acc, pos, start_pos) do
    case parse_number(num_str) do
      {:ok, num} ->
        token = {:number, num, start_pos}
        do_tokenize(rest, [token | acc], pos)

      {:error, reason} ->
        {:error, {reason, start_pos}}
    end
  end

  # Parse number string to integer or float
  defp parse_number(num_str) do
    if String.contains?(num_str, ".") or String.contains?(num_str, "e") or
         String.contains?(num_str, "E") do
      # Normalize for Elixir's Float.parse which requires digits after dot
      normalized = num_str
      # "0." → "0.0"
      normalized = if String.ends_with?(normalized, "."), do: normalized <> "0", else: normalized
      # "2.E-1" → "2.0E-1"
      normalized = String.replace(normalized, ~r/\.([eE])/, ".0\\1")
      case Float.parse(normalized) do
        {num, ""} -> {:ok, num}
        _ -> {:error, :invalid_number}
      end
    else
      {num, ""} = Integer.parse(num_str)
      {:ok, num}
    end
  end

  # Position tracking helpers
  defp advance_column(pos, n) do
    %{pos | column: pos.column + n, byte_offset: pos.byte_offset + n}
  end
end

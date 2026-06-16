defmodule Lua.Lexer do
  @moduledoc """
  Hand-written lexer for Lua 5.3 using Elixir binary pattern matching.

  Tokenizes Lua source code into a list of tokens with position tracking.
  """

  import Bitwise

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

  # Strip the first line if it looks like a shebang/header directive. Lua's
  # reference loader skips any first line beginning with `#`, but the lexer is
  # also called on free-form snippets where `#` is the length operator, so we
  # only strip when the first character is followed by something that clearly
  # isn't a length-operator expression: `!` (the canonical shebang) or a
  # whitespace character (the form `# ...` used by Lua's own main.lua test).
  defp strip_shebang(<<"#!", rest::binary>>), do: strip_first_line(rest)
  defp strip_shebang(<<"#", c, rest::binary>>) when c in [?\s, ?\t], do: strip_first_line(rest)
  defp strip_shebang(code), do: code

  defp strip_first_line(rest) do
    case String.split(rest, ~r/\r\n|\r|\n/, parts: 2) do
      [_first_line, remaining] -> remaining
      [_only_line] -> ""
    end
  end

  # End of input
  defp do_tokenize(<<>>, acc, pos) do
    {:ok, Enum.reverse([{:eof, pos} | acc])}
  end

  # Whitespace (space, horizontal tab, vertical tab, form feed).
  # Per Lua 5.3 reference manual §3.1, whitespace is space, tab, newline,
  # carriage return, vertical tab, and form feed. Newline and CR advance
  # the line counter and are handled below.
  defp do_tokenize(<<c, rest::binary>>, acc, pos) when c in [?\s, ?\t, ?\v, ?\f] do
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

  # Comments: single-line (--) or multi-line (--[[ ... ]] or --[=[ ... ]=] etc.)
  defp do_tokenize(<<"--[", rest::binary>>, acc, pos) do
    # scan_long_bracket eats `=` characters then requires a closing `[`,
    # so it correctly detects --[[ (level 0), --[=[ (level 1), --[==[ (level 2), etc.
    case scan_long_bracket(rest, 0) do
      {:ok, equals, after_bracket} ->
        # Multi-line comment of the given level
        scan_multiline_comment_text(
          after_bracket,
          "",
          acc,
          advance_column(pos, 3 + equals),
          pos,
          equals
        )

      :error ->
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
        start_pos = pos
        open_pos = advance_column(pos, 2 + equals)
        {body_rest, body_pos} = drop_leading_newline(after_bracket, open_pos)
        scan_long_string(body_rest, "", acc, body_pos, start_pos, equals)

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

  # Scan multi-line comment body. The opening bracket level was determined by
  # scan_long_bracket in do_tokenize/3. `pos` is the current scanning position
  # (right after the opener), `start_pos` is where the comment started.
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

  # \xXX hex escape: exactly two hex digits
  defp scan_string(<<?\\, ?x, h1, h2, rest::binary>>, str_acc, acc, pos, start_pos, quote)
       when h1 in ?0..?9 or h1 in ?a..?f or h1 in ?A..?F do
    if hex?(h2) do
      byte = hex_value(h1) * 16 + hex_value(h2)
      scan_string(rest, str_acc <> <<byte>>, acc, advance_column(pos, 4), start_pos, quote)
    else
      {:error, {:invalid_escape, pos}}
    end
  end

  defp scan_string(<<?\\, ?x, _rest::binary>>, _str_acc, _acc, pos, _start_pos, _quote) do
    {:error, {:invalid_escape, pos}}
  end

  # \u{XXX} unicode escape (UTF-8 encoded codepoint)
  defp scan_string(<<?\\, ?u, ?{, rest::binary>>, str_acc, acc, pos, start_pos, quote) do
    case scan_unicode_escape(rest, 0, 0) do
      {:ok, codepoint, digits, after_brace} when codepoint <= 0x7FFFFFFF ->
        utf8 = encode_lua_utf8(codepoint)
        # consumed: \u{ + digits + }
        scan_string(after_brace, str_acc <> utf8, acc, advance_column(pos, 4 + digits), start_pos, quote)

      _ ->
        {:error, {:invalid_escape, pos}}
    end
  end

  # \ddd decimal escape: 1-3 decimal digits, value must fit in a byte
  defp scan_string(<<?\\, d1, rest::binary>>, str_acc, acc, pos, start_pos, quote) when d1 in ?0..?9 do
    {value, digits, remaining} = read_decimal_escape(d1 - ?0, 1, rest)

    if value > 255 do
      {:error, {:invalid_escape, pos}}
    else
      scan_string(remaining, str_acc <> <<value>>, acc, advance_column(pos, 1 + digits), start_pos, quote)
    end
  end

  # \<newline> line continuation: a backslash before a real end-of-line yields a
  # single \n byte and advances one line. All four line endings (\n, \r, \r\n,
  # \n\r) collapse to one newline, matching PUC-Lua's `read_string`.
  defp scan_string(<<?\\, ?\r, ?\n, rest::binary>>, str_acc, acc, pos, start_pos, quote) do
    scan_string(rest, str_acc <> "\n", acc, advance_string_line(pos, 3), start_pos, quote)
  end

  defp scan_string(<<?\\, ?\n, ?\r, rest::binary>>, str_acc, acc, pos, start_pos, quote) do
    scan_string(rest, str_acc <> "\n", acc, advance_string_line(pos, 3), start_pos, quote)
  end

  defp scan_string(<<?\\, nl, rest::binary>>, str_acc, acc, pos, start_pos, quote) when nl in [?\n, ?\r] do
    scan_string(rest, str_acc <> "\n", acc, advance_string_line(pos, 2), start_pos, quote)
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

  # Read up to two more decimal digits for a \ddd escape
  defp read_decimal_escape(value, digits, <<d, rest::binary>>) when d in ?0..?9 and digits < 3 do
    next = value * 10 + (d - ?0)

    if next > 255 do
      {value, digits, <<d, rest::binary>>}
    else
      read_decimal_escape(next, digits + 1, rest)
    end
  end

  defp read_decimal_escape(value, digits, rest), do: {value, digits, rest}

  # Read hex digits inside \u{...}
  defp scan_unicode_escape(<<?}, rest::binary>>, value, digits) when digits > 0 do
    {:ok, value, digits + 1, rest}
  end

  defp scan_unicode_escape(<<c, rest::binary>>, value, digits) when digits < 8 do
    if hex?(c) do
      scan_unicode_escape(rest, value * 16 + hex_value(c), digits + 1)
    else
      :error
    end
  end

  defp scan_unicode_escape(_rest, _value, _digits), do: :error

  defp hex?(c), do: c in ?0..?9 or c in ?a..?f or c in ?A..?F

  defp hex_value(c) when c in ?0..?9, do: c - ?0
  defp hex_value(c) when c in ?a..?f, do: c - ?a + 10
  defp hex_value(c) when c in ?A..?F, do: c - ?A + 10

  # Encode a codepoint as UTF-8. Lua 5.3 accepts codepoints up to 0x7FFFFFFF
  # (6-byte UTF-8), beyond what Erlang's :unicode module emits, so handle the
  # full range manually.
  defp encode_lua_utf8(c) when c < 0x80 do
    <<c>>
  end

  defp encode_lua_utf8(c) when c < 0x800 do
    <<0b110_00000 ||| c >>> 6, 0b10_000000 ||| (c &&& 0b111111)>>
  end

  defp encode_lua_utf8(c) when c < 0x10000 do
    <<0b1110_0000 ||| c >>> 12, 0b10_000000 ||| (c >>> 6 &&& 0b111111), 0b10_000000 ||| (c &&& 0b111111)>>
  end

  defp encode_lua_utf8(c) when c < 0x200000 do
    <<0b11110_000 ||| c >>> 18, 0b10_000000 ||| (c >>> 12 &&& 0b111111), 0b10_000000 ||| (c >>> 6 &&& 0b111111),
      0b10_000000 ||| (c &&& 0b111111)>>
  end

  defp encode_lua_utf8(c) when c < 0x4000000 do
    <<0b111110_00 ||| c >>> 24, 0b10_000000 ||| (c >>> 18 &&& 0b111111), 0b10_000000 ||| (c >>> 12 &&& 0b111111),
      0b10_000000 ||| (c >>> 6 &&& 0b111111), 0b10_000000 ||| (c &&& 0b111111)>>
  end

  defp encode_lua_utf8(c) do
    <<0b1111110_0 ||| c >>> 30, 0b10_000000 ||| (c >>> 24 &&& 0b111111), 0b10_000000 ||| (c >>> 18 &&& 0b111111),
      0b10_000000 ||| (c >>> 12 &&& 0b111111), 0b10_000000 ||| (c >>> 6 &&& 0b111111), 0b10_000000 ||| (c &&& 0b111111)>>
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

  defp skip_whitespace_in_string(<<?\v, rest::binary>>, pos) do
    skip_whitespace_in_string(rest, advance_column(pos, 1))
  end

  defp skip_whitespace_in_string(<<?\f, rest::binary>>, pos) do
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

  # Per Lua 5.3 §3.1, long strings normalize end-of-line sequences (`\r`,
  # `\n`, `\r\n`, `\n\r`) to a single `\n`.
  defp scan_long_string(<<?\r, ?\n, rest::binary>>, str_acc, acc, pos, start_pos, level) do
    new_pos = %{line: pos.line + 1, column: 1, byte_offset: pos.byte_offset + 2}
    scan_long_string(rest, str_acc <> "\n", acc, new_pos, start_pos, level)
  end

  defp scan_long_string(<<?\n, ?\r, rest::binary>>, str_acc, acc, pos, start_pos, level) do
    new_pos = %{line: pos.line + 1, column: 1, byte_offset: pos.byte_offset + 2}
    scan_long_string(rest, str_acc <> "\n", acc, new_pos, start_pos, level)
  end

  defp scan_long_string(<<c, rest::binary>>, str_acc, acc, pos, start_pos, level) when c == ?\n or c == ?\r do
    new_pos = %{line: pos.line + 1, column: 1, byte_offset: pos.byte_offset + 1}
    scan_long_string(rest, str_acc <> "\n", acc, new_pos, start_pos, level)
  end

  defp scan_long_string(<<>>, _str_acc, _acc, pos, _start_pos, _level) do
    {:error, {:unclosed_long_string, pos}}
  end

  defp scan_long_string(<<c, rest::binary>>, str_acc, acc, pos, start_pos, level) do
    scan_long_string(rest, str_acc <> <<c>>, acc, advance_column(pos, 1), start_pos, level)
  end

  # Per Lua 5.3 §3.1: "when the opening long bracket is immediately followed
  # by a newline, the newline is not included in the string." Applies to any
  # line-break sequence (`\n`, `\r`, `\r\n`, `\n\r`).
  defp drop_leading_newline(<<?\r, ?\n, rest::binary>>, pos),
    do: {rest, %{line: pos.line + 1, column: 1, byte_offset: pos.byte_offset + 2}}

  defp drop_leading_newline(<<?\n, ?\r, rest::binary>>, pos),
    do: {rest, %{line: pos.line + 1, column: 1, byte_offset: pos.byte_offset + 2}}

  defp drop_leading_newline(<<c, rest::binary>>, pos) when c == ?\n or c == ?\r,
    do: {rest, %{line: pos.line + 1, column: 1, byte_offset: pos.byte_offset + 1}}

  defp drop_leading_newline(rest, pos), do: {rest, pos}

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
        # Per Lua 5.3 §3.1: hex integer literals overflow-wrap into the
        # signed 64-bit range. e.g. 0xFFFFFFFFFFFFFFFF == -1.
        token = {:number, wrap_int64(num), start_pos}
        do_tokenize(rest, [token | acc], pos)

      _ ->
        {:error, {:invalid_hex_number, start_pos}}
    end
  end

  # Wrap an unsigned hex integer to the signed 64-bit range. Inlined here so
  # the lexer doesn't depend on Lua.VM.Numeric (kept VM-internal).
  @uint64_mask 0xFFFFFFFFFFFFFFFF
  @uint64_modulus 0x10000000000000000
  @sign_bit 0x8000000000000000

  defp wrap_int64(n) when is_integer(n) do
    masked = band(n, @uint64_mask)
    if masked >= @sign_bit, do: masked - @uint64_modulus, else: masked
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
      # Lua 5.3.3 §3.1: a decimal integer literal that overflows the signed
      # 64-bit range converts to a float (a leading sign is a separate token,
      # so `num` here is always the non-negative magnitude). Hex integer
      # literals instead wrap via wrap_int64; this branch is decimal only.
      # @sign_bit is 2^63, i.e. max_int + 1, so `>= @sign_bit` means overflow.
      if num >= @sign_bit, do: {:ok, num * 1.0}, else: {:ok, num}
    end
  end

  # Position tracking helpers
  defp advance_column(pos, n) do
    %{pos | column: pos.column + n, byte_offset: pos.byte_offset + n}
  end

  # Advance one source line, consuming `n` raw bytes (the backslash plus the
  # one- or two-byte line ending of a \<newline> continuation).
  defp advance_string_line(pos, n) do
    %{line: pos.line + 1, column: 1, byte_offset: pos.byte_offset + n}
  end
end

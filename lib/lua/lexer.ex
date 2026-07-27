defmodule Lua.Lexer do
  @moduledoc """
  Hand-written lexer for Lua 5.3 using Elixir binary pattern matching.

  Tokenizes Lua source code into a list of tokens with position tracking.

  Position is threaded as three bare integers instead of a map: the current
  line, the byte offset the current line's columns are measured from, and the
  current byte offset. A position map is materialized only when a token or an
  error is emitted. `line_start` absorbs the continuation bytes of multibyte
  codepoints, so `column` counts codepoints while `byte_offset` counts bytes.

  Token text is sliced out of the source binary with `binary_part/3` and then
  copied with `:binary.copy/1`, so a retained token never keeps the whole
  source binary alive. String escapes and long-string end-of-line
  normalization are the only places where a token's text differs from its
  source bytes; those fall back to collecting chunks of iodata around the
  rewritten spans.
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

  # Signed 64-bit wrap-around constants for integer literals.
  @uint64_mask 0xFFFFFFFFFFFFFFFF
  @uint64_modulus 0x10000000000000000
  @sign_bit 0x8000000000000000

  @compile {:inline, position: 3, utf8_width: 1, chunked_text: 4}

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
    src = strip_shebang(code)
    do_tokenize(src, [], src, 1, 0, 0)
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

  # Build the public position map for the given cursor.
  defp position(line, line_start, offset) do
    %{line: line, column: offset - line_start + 1, byte_offset: offset}
  end

  # Byte width of a codepoint's UTF-8 encoding (only called for cp > 127).
  defp utf8_width(cp) when cp < 0x800, do: 2
  defp utf8_width(cp) when cp < 0x10000, do: 3
  defp utf8_width(_cp), do: 4

  # Assemble token text from the trailing raw span plus any earlier chunks.
  # The single-slice path copies the sub-binary so a token doesn't keep the
  # whole source binary alive; the chunked path copies via iodata already.
  defp chunked_text(src, start, offset, []), do: :binary.copy(binary_part(src, start, offset - start))

  defp chunked_text(src, start, offset, chunks) do
    IO.iodata_to_binary(:lists.reverse([binary_part(src, start, offset - start) | chunks]))
  end

  # End of input
  defp do_tokenize(<<>>, acc, _src, line, line_start, offset) do
    {:ok, Enum.reverse([{:eof, position(line, line_start, offset)} | acc])}
  end

  # Whitespace (space, horizontal tab, vertical tab, form feed).
  # Per Lua 5.3 reference manual §3.1, whitespace is space, tab, newline,
  # carriage return, vertical tab, and form feed. Newline and CR advance
  # the line counter and are handled below.
  defp do_tokenize(<<c, rest::binary>>, acc, src, line, line_start, offset) when c in [?\s, ?\t, ?\v, ?\f] do
    do_tokenize(rest, acc, src, line, line_start, offset + 1)
  end

  # Newline (LF)
  defp do_tokenize(<<?\n, rest::binary>>, acc, src, line, _line_start, offset) do
    do_tokenize(rest, acc, src, line + 1, offset + 1, offset + 1)
  end

  # Carriage return (CR, or CRLF)
  defp do_tokenize(<<?\r, ?\n, rest::binary>>, acc, src, line, _line_start, offset) do
    do_tokenize(rest, acc, src, line + 1, offset + 2, offset + 2)
  end

  defp do_tokenize(<<?\r, rest::binary>>, acc, src, line, _line_start, offset) do
    do_tokenize(rest, acc, src, line + 1, offset + 1, offset + 1)
  end

  # Comments: single-line (--) or multi-line (--[[ ... ]] or --[=[ ... ]=] etc.)
  defp do_tokenize(<<"--[", rest::binary>>, acc, src, line, line_start, offset) do
    # scan_long_bracket eats `=` characters then requires a closing `[`,
    # so it correctly detects --[[ (level 0), --[=[ (level 1), --[==[ (level 2), etc.
    case scan_long_bracket(rest, 0) do
      {:ok, equals, after_bracket} ->
        # Multi-line comment of the given level. The opener is `--[`, the
        # level's `=` signs, and the second `[`.
        body = offset + 4 + equals

        scan_multiline_comment(
          after_bracket,
          acc,
          src,
          line,
          line_start,
          body,
          body,
          position(line, line_start, offset),
          equals
        )

      :error ->
        # Single-line comment starting with --[
        start_pos = position(line, line_start, offset)
        scan_single_line_comment(rest, acc, src, line, line_start, offset + 3, offset + 3, start_pos)
    end
  end

  defp do_tokenize(<<"--", rest::binary>>, acc, src, line, line_start, offset) do
    start_pos = position(line, line_start, offset)
    scan_single_line_comment(rest, acc, src, line, line_start, offset + 2, offset + 2, start_pos)
  end

  # Strings: double-quoted
  defp do_tokenize(<<?", rest::binary>>, acc, src, line, line_start, offset) do
    scan_string(rest, acc, src, line, line_start, offset + 1, offset + 1, [], position(line, line_start, offset), ?")
  end

  # Strings: single-quoted
  defp do_tokenize(<<?', rest::binary>>, acc, src, line, line_start, offset) do
    scan_string(rest, acc, src, line, line_start, offset + 1, offset + 1, [], position(line, line_start, offset), ?')
  end

  # Strings: multi-line [[ ... ]] or [=[ ... ]=]
  defp do_tokenize(<<"[", rest::binary>>, acc, src, line, line_start, offset) do
    case scan_long_bracket(rest, 0) do
      {:ok, equals, after_bracket} ->
        start_pos = position(line, line_start, offset)

        {body, body_line, body_line_start, body_offset} =
          drop_leading_newline(after_bracket, line, line_start, offset + 2 + equals)

        scan_long_string(
          body,
          acc,
          src,
          body_line,
          body_line_start,
          body_offset,
          body_offset,
          [],
          start_pos,
          equals
        )

      :error ->
        # Not a long string, treat as delimiter
        token = {:delimiter, :lbracket, position(line, line_start, offset)}
        do_tokenize(rest, [token | acc], src, line, line_start, offset + 1)
    end
  end

  # Numbers: hex (0x, 0X)
  defp do_tokenize(<<"0", x, rest::binary>>, acc, src, line, line_start, offset) when x in [?x, ?X] do
    scan_hex_int(rest, acc, src, line, line_start, offset + 2, offset + 2, offset)
  end

  # Numbers: decimal or float
  defp do_tokenize(<<c, _rest::binary>> = bin, acc, src, line, line_start, offset) when c in ?0..?9 do
    scan_int_digits(bin, acc, src, line, line_start, offset, offset)
  end

  # Float starting with dot: .0, .5e3, etc.
  defp do_tokenize(<<".", c, _rest::binary>> = bin, acc, src, line, line_start, offset) when c in ?0..?9 do
    scan_int_digits(bin, acc, src, line, line_start, offset, offset)
  end

  # Three-character operators
  defp do_tokenize(<<"...", rest::binary>>, acc, src, line, line_start, offset) do
    token = {:operator, :vararg, position(line, line_start, offset)}
    do_tokenize(rest, [token | acc], src, line, line_start, offset + 3)
  end

  # Two-character operators
  defp do_tokenize(<<"==", rest::binary>>, acc, src, line, line_start, offset) do
    token = {:operator, :eq, position(line, line_start, offset)}
    do_tokenize(rest, [token | acc], src, line, line_start, offset + 2)
  end

  defp do_tokenize(<<"~=", rest::binary>>, acc, src, line, line_start, offset) do
    token = {:operator, :ne, position(line, line_start, offset)}
    do_tokenize(rest, [token | acc], src, line, line_start, offset + 2)
  end

  defp do_tokenize(<<"<=", rest::binary>>, acc, src, line, line_start, offset) do
    token = {:operator, :le, position(line, line_start, offset)}
    do_tokenize(rest, [token | acc], src, line, line_start, offset + 2)
  end

  defp do_tokenize(<<">=", rest::binary>>, acc, src, line, line_start, offset) do
    token = {:operator, :ge, position(line, line_start, offset)}
    do_tokenize(rest, [token | acc], src, line, line_start, offset + 2)
  end

  defp do_tokenize(<<"..", rest::binary>>, acc, src, line, line_start, offset) do
    token = {:operator, :concat, position(line, line_start, offset)}
    do_tokenize(rest, [token | acc], src, line, line_start, offset + 2)
  end

  defp do_tokenize(<<"::", rest::binary>>, acc, src, line, line_start, offset) do
    token = {:delimiter, :double_colon, position(line, line_start, offset)}
    do_tokenize(rest, [token | acc], src, line, line_start, offset + 2)
  end

  defp do_tokenize(<<"//", rest::binary>>, acc, src, line, line_start, offset) do
    token = {:operator, :floordiv, position(line, line_start, offset)}
    do_tokenize(rest, [token | acc], src, line, line_start, offset + 2)
  end

  # Bitwise shift operators (must come before single < and >)
  defp do_tokenize(<<"<<", rest::binary>>, acc, src, line, line_start, offset) do
    token = {:operator, :shl, position(line, line_start, offset)}
    do_tokenize(rest, [token | acc], src, line, line_start, offset + 2)
  end

  defp do_tokenize(<<">>", rest::binary>>, acc, src, line, line_start, offset) do
    token = {:operator, :shr, position(line, line_start, offset)}
    do_tokenize(rest, [token | acc], src, line, line_start, offset + 2)
  end

  # Single-character operators and delimiters
  defp do_tokenize(<<c, rest::binary>>, acc, src, line, line_start, offset)
       when c in [?+, ?-, ?*, ?/, ?%, ?^, ?#, ?&, ?|, ?~] do
    token = {:operator, single_operator(c), position(line, line_start, offset)}
    do_tokenize(rest, [token | acc], src, line, line_start, offset + 1)
  end

  defp do_tokenize(<<c, rest::binary>>, acc, src, line, line_start, offset) when c in [?<, ?>, ?=] do
    token = {:operator, single_operator(c), position(line, line_start, offset)}
    do_tokenize(rest, [token | acc], src, line, line_start, offset + 1)
  end

  defp do_tokenize(<<c, rest::binary>>, acc, src, line, line_start, offset)
       when c in [?(, ?), ?{, ?}, ?], ?;, ?,, ?., ?:] do
    token = {:delimiter, single_delimiter(c), position(line, line_start, offset)}
    do_tokenize(rest, [token | acc], src, line, line_start, offset + 1)
  end

  # Identifiers and keywords
  defp do_tokenize(<<c, rest::binary>>, acc, src, line, line_start, offset) when c in ?a..?z or c in ?A..?Z or c == ?_ do
    {after_id, len} = scan_identifier(rest, 1)
    text = binary_part(src, offset, len)
    start_pos = position(line, line_start, offset)

    token =
      case keyword_atom(text) do
        {:ok, keyword} -> {:keyword, keyword, start_pos}
        # Copy the slice so the identifier doesn't keep the source alive.
        :error -> {:identifier, :binary.copy(text), start_pos}
      end

    do_tokenize(after_id, [token | acc], src, line, line_start, offset + len)
  end

  # Unexpected character — carry the full codepoint so error messages stay
  # valid UTF-8 even for multibyte characters (a byte-level match would keep
  # only the UTF-8 lead byte).
  defp do_tokenize(<<cp::utf8, _rest::binary>>, _acc, _src, line, line_start, offset) do
    {:error, {:unexpected_character, cp, position(line, line_start, offset)}}
  end

  # Genuinely invalid UTF-8 lead byte (no valid codepoint here).
  defp do_tokenize(<<byte, _rest::binary>>, _acc, _src, line, line_start, offset) do
    {:error, {:invalid_byte, byte, position(line, line_start, offset)}}
  end

  defp single_operator(?+), do: :add
  defp single_operator(?-), do: :sub
  defp single_operator(?*), do: :mul
  defp single_operator(?/), do: :div
  defp single_operator(?%), do: :mod
  defp single_operator(?^), do: :pow
  defp single_operator(?#), do: :len
  defp single_operator(?&), do: :band
  defp single_operator(?|), do: :bor
  defp single_operator(?~), do: :bxor
  defp single_operator(?<), do: :lt
  defp single_operator(?>), do: :gt
  defp single_operator(?=), do: :assign

  defp single_delimiter(?(), do: :lparen
  defp single_delimiter(?)), do: :rparen
  defp single_delimiter(?{), do: :lbrace
  defp single_delimiter(?}), do: :rbrace
  defp single_delimiter(?]), do: :rbracket
  defp single_delimiter(?;), do: :semicolon
  defp single_delimiter(?,), do: :comma
  defp single_delimiter(?.), do: :dot
  defp single_delimiter(?:), do: :colon

  # Scan single-line comment: the text runs from `text_start` to the newline
  # (or end of input) and is always a verbatim slice of the source. The start
  # position is built eagerly by the caller — multibyte codepoints in the body
  # shift `line_start`, so it can't be reconstructed after scanning.
  defp scan_single_line_comment(<<?\n, rest::binary>>, acc, src, line, _line_start, offset, text_start, start_pos) do
    token = single_comment(src, text_start, offset, start_pos)
    do_tokenize(rest, [token | acc], src, line + 1, offset + 1, offset + 1)
  end

  defp scan_single_line_comment(<<?\r, ?\n, rest::binary>>, acc, src, line, _line_start, offset, text_start, start_pos) do
    token = single_comment(src, text_start, offset, start_pos)
    do_tokenize(rest, [token | acc], src, line + 1, offset + 2, offset + 2)
  end

  defp scan_single_line_comment(<<?\r, rest::binary>>, acc, src, line, _line_start, offset, text_start, start_pos) do
    token = single_comment(src, text_start, offset, start_pos)
    do_tokenize(rest, [token | acc], src, line + 1, offset + 1, offset + 1)
  end

  defp scan_single_line_comment(<<>>, acc, src, line, line_start, offset, text_start, start_pos) do
    token = single_comment(src, text_start, offset, start_pos)
    {:ok, Enum.reverse([{:eof, position(line, line_start, offset)}, token | acc])}
  end

  defp scan_single_line_comment(<<c, rest::binary>>, acc, src, line, line_start, offset, text_start, start_pos)
       when c < 128 do
    scan_single_line_comment(rest, acc, src, line, line_start, offset + 1, text_start, start_pos)
  end

  defp scan_single_line_comment(<<cp::utf8, rest::binary>>, acc, src, line, line_start, offset, text_start, start_pos)
       when cp > 127 do
    width = utf8_width(cp)

    scan_single_line_comment(
      rest,
      acc,
      src,
      line,
      line_start + width - 1,
      offset + width,
      text_start,
      start_pos
    )
  end

  defp scan_single_line_comment(<<_c, rest::binary>>, acc, src, line, line_start, offset, text_start, start_pos) do
    scan_single_line_comment(rest, acc, src, line, line_start, offset + 1, text_start, start_pos)
  end

  defp single_comment(src, text_start, offset, start_pos) do
    {:comment, :single, :binary.copy(binary_part(src, text_start, offset - text_start)), start_pos}
  end

  # Scan multi-line comment body. The opening bracket level was determined by
  # scan_long_bracket in do_tokenize/6. The body is a verbatim slice of the
  # source: no end-of-line normalization applies to comments.
  defp scan_multiline_comment(<<"]", rest::binary>>, acc, src, line, line_start, offset, text_start, start_pos, level) do
    case try_close_long_bracket(rest, level, 0) do
      {:ok, after_bracket} ->
        text = :binary.copy(binary_part(src, text_start, offset - text_start))
        token = {:comment, :multi, text, start_pos}
        do_tokenize(after_bracket, [token | acc], src, line, line_start, offset + 2 + level)

      :error ->
        scan_multiline_comment(rest, acc, src, line, line_start, offset + 1, text_start, start_pos, level)
    end
  end

  defp scan_multiline_comment(<<?\n, rest::binary>>, acc, src, line, _line_start, offset, text_start, start_pos, level) do
    scan_multiline_comment(rest, acc, src, line + 1, offset + 1, offset + 1, text_start, start_pos, level)
  end

  defp scan_multiline_comment(<<>>, _acc, _src, line, line_start, offset, _text_start, _start_pos, _level) do
    {:error, {:unclosed_comment, position(line, line_start, offset)}}
  end

  defp scan_multiline_comment(<<c, rest::binary>>, acc, src, line, line_start, offset, text_start, start_pos, level)
       when c < 128 do
    scan_multiline_comment(rest, acc, src, line, line_start, offset + 1, text_start, start_pos, level)
  end

  defp scan_multiline_comment(
         <<cp::utf8, rest::binary>>,
         acc,
         src,
         line,
         line_start,
         offset,
         text_start,
         start_pos,
         level
       )
       when cp > 127 do
    width = utf8_width(cp)

    scan_multiline_comment(
      rest,
      acc,
      src,
      line,
      line_start + width - 1,
      offset + width,
      text_start,
      start_pos,
      level
    )
  end

  defp scan_multiline_comment(<<_c, rest::binary>>, acc, src, line, line_start, offset, text_start, start_pos, level) do
    scan_multiline_comment(rest, acc, src, line, line_start, offset + 1, text_start, start_pos, level)
  end

  # Scan quoted string. `chunk` is the offset where the current verbatim span
  # of the string body starts; `chunks` holds the already-rewritten prefix in
  # reverse order and stays empty for the common escape-free string.
  defp scan_string(<<quote, rest::binary>>, acc, src, line, line_start, offset, chunk, chunks, start_pos, quote) do
    # Closing quote
    token = {:string, chunked_text(src, chunk, offset, chunks), start_pos}
    do_tokenize(rest, [token | acc], src, line, line_start, offset + 1)
  end

  # \z escape: skip all following whitespace
  defp scan_string(<<?\\, ?z, rest::binary>>, acc, src, line, line_start, offset, chunk, chunks, start_pos, quote) do
    chunks = flush_chunk(src, chunk, offset, chunks)
    {remaining, line, line_start, offset} = skip_string_whitespace(rest, line, line_start, offset + 2)
    scan_string(remaining, acc, src, line, line_start, offset, offset, chunks, start_pos, quote)
  end

  # \xXX hex escape: exactly two hex digits
  defp scan_string(<<?\\, ?x, h1, h2, rest::binary>>, acc, src, line, line_start, offset, chunk, chunks, start_pos, quote)
       when h1 in ?0..?9 or h1 in ?a..?f or h1 in ?A..?F do
    if hex?(h2) do
      byte = hex_value(h1) * 16 + hex_value(h2)
      chunks = [<<byte>> | flush_chunk(src, chunk, offset, chunks)]
      scan_string(rest, acc, src, line, line_start, offset + 4, offset + 4, chunks, start_pos, quote)
    else
      {:error, {:invalid_escape, position(line, line_start, offset)}}
    end
  end

  defp scan_string(<<?\\, ?x, _rest::binary>>, _acc, _src, line, line_start, offset, _chunk, _chunks, _start_pos, _quote) do
    {:error, {:invalid_escape, position(line, line_start, offset)}}
  end

  # \u{XXX} unicode escape (UTF-8 encoded codepoint)
  defp scan_string(<<?\\, ?u, ?{, rest::binary>>, acc, src, line, line_start, offset, chunk, chunks, start_pos, quote) do
    case scan_unicode_escape(rest, 0, 0) do
      {:ok, codepoint, inner_len, after_brace} when codepoint <= 0x7FFFFFFF ->
        chunks = [encode_lua_utf8(codepoint) | flush_chunk(src, chunk, offset, chunks)]
        # consumed: `\u{` plus the digits and the closing `}`
        offset = offset + 3 + inner_len
        scan_string(after_brace, acc, src, line, line_start, offset, offset, chunks, start_pos, quote)

      _ ->
        {:error, {:invalid_escape, position(line, line_start, offset)}}
    end
  end

  # \ddd decimal escape: 1-3 decimal digits. read_decimal_escape/3 stops
  # before a digit would push the value past 255, so it always fits in a byte.
  defp scan_string(<<?\\, d1, rest::binary>>, acc, src, line, line_start, offset, chunk, chunks, start_pos, quote)
       when d1 in ?0..?9 do
    {value, digits, remaining} = read_decimal_escape(d1 - ?0, 1, rest)
    chunks = [<<value>> | flush_chunk(src, chunk, offset, chunks)]
    offset = offset + 1 + digits
    scan_string(remaining, acc, src, line, line_start, offset, offset, chunks, start_pos, quote)
  end

  # \<newline> line continuation: a backslash before a real end-of-line yields a
  # single \n byte and advances one line. All four line endings (\n, \r, \r\n,
  # \n\r) collapse to one newline, matching PUC-Lua's `read_string`.
  defp scan_string(<<?\\, ?\r, ?\n, rest::binary>>, acc, src, line, _line_start, offset, chunk, chunks, start_pos, quote) do
    continue_string_line(rest, acc, src, line, offset, 3, chunk, chunks, start_pos, quote)
  end

  defp scan_string(<<?\\, ?\n, ?\r, rest::binary>>, acc, src, line, _line_start, offset, chunk, chunks, start_pos, quote) do
    continue_string_line(rest, acc, src, line, offset, 3, chunk, chunks, start_pos, quote)
  end

  defp scan_string(<<?\\, nl, rest::binary>>, acc, src, line, _line_start, offset, chunk, chunks, start_pos, quote)
       when nl in [?\n, ?\r] do
    continue_string_line(rest, acc, src, line, offset, 2, chunk, chunks, start_pos, quote)
  end

  defp scan_string(<<?\\, esc, rest::binary>>, acc, src, line, line_start, offset, chunk, chunks, start_pos, quote) do
    # Escape sequence
    case escape_char(esc) do
      {:ok, char} ->
        chunks = [<<char>> | flush_chunk(src, chunk, offset, chunks)]
        scan_string(rest, acc, src, line, line_start, offset + 2, offset + 2, chunks, start_pos, quote)

      :error ->
        # Invalid escape, but continue scanning — the backslash and the
        # following byte are kept verbatim, so the span needs no rewriting.
        scan_string(rest, acc, src, line, line_start, offset + 2, chunk, chunks, start_pos, quote)
    end
  end

  defp scan_string(<<?\n, _rest::binary>>, _acc, _src, line, line_start, offset, _chunk, _chunks, _start_pos, _quote) do
    {:error, {:unclosed_string, position(line, line_start, offset)}}
  end

  defp scan_string(<<>>, _acc, _src, line, line_start, offset, _chunk, _chunks, _start_pos, _quote) do
    {:error, {:unclosed_string, position(line, line_start, offset)}}
  end

  defp scan_string(<<c, rest::binary>>, acc, src, line, line_start, offset, chunk, chunks, start_pos, quote)
       when c < 128 do
    scan_string(rest, acc, src, line, line_start, offset + 1, chunk, chunks, start_pos, quote)
  end

  defp scan_string(<<cp::utf8, rest::binary>>, acc, src, line, line_start, offset, chunk, chunks, start_pos, quote)
       when cp > 127 do
    width = utf8_width(cp)
    scan_string(rest, acc, src, line, line_start + width - 1, offset + width, chunk, chunks, start_pos, quote)
  end

  defp scan_string(<<_c, rest::binary>>, acc, src, line, line_start, offset, chunk, chunks, start_pos, quote) do
    scan_string(rest, acc, src, line, line_start, offset + 1, chunk, chunks, start_pos, quote)
  end

  # A \<newline> continuation contributes one "\n" byte and starts a new line
  # after `consumed` raw source bytes.
  defp continue_string_line(rest, acc, src, line, offset, consumed, chunk, chunks, start_pos, quote) do
    chunks = ["\n" | flush_chunk(src, chunk, offset, chunks)]
    offset = offset + consumed
    scan_string(rest, acc, src, line + 1, offset, offset, offset, chunks, start_pos, quote)
  end

  # Close the current verbatim span before a rewritten one is appended.
  defp flush_chunk(_src, chunk, offset, chunks) when chunk == offset, do: chunks
  defp flush_chunk(src, chunk, offset, chunks), do: [binary_part(src, chunk, offset - chunk) | chunks]

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

  # Read hex digits inside \u{...}. The reported length covers the digits and
  # the closing brace, i.e. everything after the opening `\u{`.
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
  defp skip_string_whitespace(<<c, rest::binary>>, line, line_start, offset) when c in [?\s, ?\t, ?\v, ?\f] do
    skip_string_whitespace(rest, line, line_start, offset + 1)
  end

  defp skip_string_whitespace(<<?\r, ?\n, rest::binary>>, line, _line_start, offset) do
    skip_string_whitespace(rest, line + 1, offset + 2, offset + 2)
  end

  defp skip_string_whitespace(<<c, rest::binary>>, line, _line_start, offset) when c in [?\n, ?\r] do
    skip_string_whitespace(rest, line + 1, offset + 1, offset + 1)
  end

  defp skip_string_whitespace(rest, line, line_start, offset) do
    {rest, line, line_start, offset}
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
  defp scan_long_string(<<"]", rest::binary>>, acc, src, line, line_start, offset, chunk, chunks, start_pos, level) do
    case try_close_long_bracket(rest, level, 0) do
      {:ok, after_bracket} ->
        token = {:string, chunked_text(src, chunk, offset, chunks), start_pos}
        do_tokenize(after_bracket, [token | acc], src, line, line_start, offset + 2 + level)

      :error ->
        scan_long_string(rest, acc, src, line, line_start, offset + 1, chunk, chunks, start_pos, level)
    end
  end

  # Per Lua 5.3 §3.1, long strings normalize end-of-line sequences (`\r`,
  # `\n`, `\r\n`, `\n\r`) to a single `\n`. A bare `\n` already is that
  # normal form, so only the other three break the verbatim span.
  defp scan_long_string(<<?\r, ?\n, rest::binary>>, acc, src, line, _line_start, offset, chunk, chunks, start_pos, level) do
    long_string_newline(rest, acc, src, line, offset, 2, chunk, chunks, start_pos, level)
  end

  defp scan_long_string(<<?\n, ?\r, rest::binary>>, acc, src, line, _line_start, offset, chunk, chunks, start_pos, level) do
    long_string_newline(rest, acc, src, line, offset, 2, chunk, chunks, start_pos, level)
  end

  defp scan_long_string(<<?\n, rest::binary>>, acc, src, line, _line_start, offset, chunk, chunks, start_pos, level) do
    scan_long_string(rest, acc, src, line + 1, offset + 1, offset + 1, chunk, chunks, start_pos, level)
  end

  defp scan_long_string(<<?\r, rest::binary>>, acc, src, line, _line_start, offset, chunk, chunks, start_pos, level) do
    long_string_newline(rest, acc, src, line, offset, 1, chunk, chunks, start_pos, level)
  end

  defp scan_long_string(<<>>, _acc, _src, line, line_start, offset, _chunk, _chunks, _start_pos, _level) do
    {:error, {:unclosed_long_string, position(line, line_start, offset)}}
  end

  defp scan_long_string(<<c, rest::binary>>, acc, src, line, line_start, offset, chunk, chunks, start_pos, level)
       when c < 128 do
    scan_long_string(rest, acc, src, line, line_start, offset + 1, chunk, chunks, start_pos, level)
  end

  defp scan_long_string(<<cp::utf8, rest::binary>>, acc, src, line, line_start, offset, chunk, chunks, start_pos, level)
       when cp > 127 do
    width = utf8_width(cp)
    scan_long_string(rest, acc, src, line, line_start + width - 1, offset + width, chunk, chunks, start_pos, level)
  end

  defp scan_long_string(<<_c, rest::binary>>, acc, src, line, line_start, offset, chunk, chunks, start_pos, level) do
    scan_long_string(rest, acc, src, line, line_start, offset + 1, chunk, chunks, start_pos, level)
  end

  # An end-of-line sequence other than a bare `\n` becomes a single "\n".
  defp long_string_newline(rest, acc, src, line, offset, consumed, chunk, chunks, start_pos, level) do
    chunks = ["\n" | flush_chunk(src, chunk, offset, chunks)]
    offset = offset + consumed
    scan_long_string(rest, acc, src, line + 1, offset, offset, offset, chunks, start_pos, level)
  end

  # Per Lua 5.3 §3.1: "when the opening long bracket is immediately followed
  # by a newline, the newline is not included in the string." Applies to any
  # line-break sequence (`\n`, `\r`, `\r\n`, `\n\r`).
  defp drop_leading_newline(<<?\r, ?\n, rest::binary>>, line, _line_start, offset),
    do: {rest, line + 1, offset + 2, offset + 2}

  defp drop_leading_newline(<<?\n, ?\r, rest::binary>>, line, _line_start, offset),
    do: {rest, line + 1, offset + 2, offset + 2}

  defp drop_leading_newline(<<c, rest::binary>>, line, _line_start, offset) when c == ?\n or c == ?\r,
    do: {rest, line + 1, offset + 1, offset + 1}

  defp drop_leading_newline(rest, line, line_start, offset), do: {rest, line, line_start, offset}

  # Scan identifier or keyword — only the length is collected, the text is
  # then sliced out of the source binary in one go.
  defp scan_identifier(<<c, rest::binary>>, len) when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?_ do
    scan_identifier(rest, len + 1)
  end

  defp scan_identifier(rest, len), do: {rest, len}

  # Reserved words. Compiled into a binary decision tree, so a non-keyword
  # identifier falls through without any sequential comparison or atom
  # conversion. The results are wrapped because `nil` and `false` are
  # themselves keyword atoms.
  defp keyword_atom("and"), do: {:ok, :and}
  defp keyword_atom("break"), do: {:ok, :break}
  defp keyword_atom("do"), do: {:ok, :do}
  defp keyword_atom("else"), do: {:ok, :else}
  defp keyword_atom("elseif"), do: {:ok, :elseif}
  defp keyword_atom("end"), do: {:ok, :end}
  defp keyword_atom("false"), do: {:ok, false}
  defp keyword_atom("for"), do: {:ok, :for}
  defp keyword_atom("function"), do: {:ok, :function}
  defp keyword_atom("goto"), do: {:ok, :goto}
  defp keyword_atom("if"), do: {:ok, :if}
  defp keyword_atom("in"), do: {:ok, :in}
  defp keyword_atom("local"), do: {:ok, :local}
  defp keyword_atom("nil"), do: {:ok, nil}
  defp keyword_atom("not"), do: {:ok, :not}
  defp keyword_atom("or"), do: {:ok, :or}
  defp keyword_atom("repeat"), do: {:ok, :repeat}
  defp keyword_atom("return"), do: {:ok, :return}
  defp keyword_atom("then"), do: {:ok, :then}
  defp keyword_atom("true"), do: {:ok, true}
  defp keyword_atom("until"), do: {:ok, :until}
  defp keyword_atom("while"), do: {:ok, :while}
  defp keyword_atom(_), do: :error

  # Scan decimal number. `token_start` is the byte offset of the first
  # character of the literal; the digit runs are measured against it and the
  # value is converted straight from the source bytes.
  defp scan_int_digits(<<c, rest::binary>>, acc, src, line, line_start, offset, token_start) when c in ?0..?9 do
    scan_int_digits(rest, acc, src, line, line_start, offset + 1, token_start)
  end

  # ".." is the concat operator, not a decimal point: 0..5 → 0 .. 5
  defp scan_int_digits(<<"..", _rest::binary>> = bin, acc, src, line, line_start, offset, token_start) do
    emit_integer(bin, acc, src, line, line_start, offset, token_start)
  end

  defp scan_int_digits(<<".", rest::binary>>, acc, src, line, line_start, offset, token_start) do
    scan_frac_digits(rest, acc, src, line, line_start, offset + 1, token_start, offset - token_start, offset + 1)
  end

  # Scientific notation without a decimal point: 1e5
  defp scan_int_digits(<<c, rest::binary>>, acc, src, line, line_start, offset, token_start) when c in [?e, ?E] do
    mantissa = binary_part(src, token_start, offset - token_start) <> ".0"
    scan_exponent(rest, acc, src, line, line_start, offset + 1, token_start, mantissa)
  end

  defp scan_int_digits(bin, acc, src, line, line_start, offset, token_start) do
    emit_integer(bin, acc, src, line, line_start, offset, token_start)
  end

  # Scan the fractional digits after a decimal point.
  defp scan_frac_digits(<<c, rest::binary>>, acc, src, line, line_start, offset, token_start, int_len, frac_start)
       when c in ?0..?9 do
    scan_frac_digits(rest, acc, src, line, line_start, offset + 1, token_start, int_len, frac_start)
  end

  defp scan_frac_digits(<<c, rest::binary>>, acc, src, line, line_start, offset, token_start, int_len, frac_start)
       when c in [?e, ?E] do
    mantissa = mantissa_binary(src, token_start, int_len, frac_start, offset - frac_start)
    scan_exponent(rest, acc, src, line, line_start, offset + 1, token_start, mantissa)
  end

  defp scan_frac_digits(bin, acc, src, line, line_start, offset, token_start, int_len, frac_start) do
    mantissa = mantissa_binary(src, token_start, int_len, frac_start, offset - frac_start)
    emit_float(bin, acc, src, line, line_start, offset, token_start, mantissa)
  end

  # Scan the exponent of a decimal float. `mantissa` is already normalized to
  # a form Erlang's binary_to_float/1 accepts (digits on both sides of a dot).
  defp scan_exponent(<<sign, rest::binary>>, acc, src, line, line_start, offset, token_start, mantissa)
       when sign in [?+, ?-] do
    scan_exponent_digits(rest, acc, src, line, line_start, offset + 1, token_start, mantissa <> <<?e, sign>>, offset + 1)
  end

  defp scan_exponent(bin, acc, src, line, line_start, offset, token_start, mantissa) do
    scan_exponent_digits(bin, acc, src, line, line_start, offset, token_start, mantissa <> "e", offset)
  end

  defp scan_exponent_digits(<<c, rest::binary>>, acc, src, line, line_start, offset, token_start, mantissa, digit_start)
       when c in ?0..?9 do
    scan_exponent_digits(rest, acc, src, line, line_start, offset + 1, token_start, mantissa, digit_start)
  end

  # An exponent marker with no digits after it is a malformed number.
  defp scan_exponent_digits(_bin, _acc, _src, line, line_start, offset, token_start, _mantissa, digit_start)
       when offset == digit_start do
    {:error, {:invalid_number, position(line, line_start, token_start)}}
  end

  defp scan_exponent_digits(bin, acc, src, line, line_start, offset, token_start, mantissa, digit_start) do
    literal = mantissa <> binary_part(src, digit_start, offset - digit_start)
    emit_float(bin, acc, src, line, line_start, offset, token_start, literal)
  end

  # Normalize the mantissa so Erlang's strict float syntax accepts it: digits
  # are required on both sides of the decimal point.
  defp mantissa_binary(src, token_start, int_len, _frac_start, 0) when int_len > 0 do
    binary_part(src, token_start, int_len) <> ".0"
  end

  defp mantissa_binary(src, _token_start, 0, frac_start, frac_len) when frac_len > 0 do
    "0." <> binary_part(src, frac_start, frac_len)
  end

  defp mantissa_binary(src, token_start, int_len, _frac_start, frac_len) when int_len > 0 and frac_len > 0 do
    binary_part(src, token_start, int_len + 1 + frac_len)
  end

  defp mantissa_binary(_src, _token_start, _int_len, _frac_start, _frac_len), do: "0.0"

  defp emit_integer(bin, acc, src, line, line_start, offset, token_start) do
    value = :erlang.binary_to_integer(binary_part(src, token_start, offset - token_start))

    # Lua 5.3.3 §3.1: a decimal integer literal that overflows the signed
    # 64-bit range converts to a float (a leading sign is a separate token,
    # so `value` here is always the non-negative magnitude). Hex integer
    # literals instead wrap via wrap_int64; this branch is decimal only.
    # @sign_bit is 2^63, i.e. max_int + 1, so `>= @sign_bit` means overflow.
    number = if value >= @sign_bit, do: value * 1.0, else: value
    token = {:number, number, position(line, line_start, token_start)}
    do_tokenize(bin, [token | acc], src, line, line_start, offset)
  end

  defp emit_float(bin, acc, src, line, line_start, offset, token_start, literal) do
    case parse_float(literal) do
      {:ok, value} ->
        token = {:number, value, position(line, line_start, token_start)}
        do_tokenize(bin, [token | acc], src, line, line_start, offset)

      :error ->
        {:error, {:invalid_number, position(line, line_start, token_start)}}
    end
  end

  # The literal is always well-formed by construction; the only way this can
  # fail is a magnitude outside the double range, e.g. `1e400`.
  defp parse_float(literal) do
    {:ok, :erlang.binary_to_float(literal)}
  rescue
    ArgumentError -> :error
  end

  # Scan hexadecimal number (0x...) — supports integers, hex floats (0xF0.0), and exponents (0xABCp-3)
  defp scan_hex_int(<<c, rest::binary>>, acc, src, line, line_start, offset, digit_start, token_start)
       when c in ?0..?9 or c in ?a..?f or c in ?A..?F do
    scan_hex_int(rest, acc, src, line, line_start, offset + 1, digit_start, token_start)
  end

  # Hex float: dot followed by hex digits
  defp scan_hex_int(<<".", rest::binary>>, acc, src, line, line_start, offset, digit_start, token_start) do
    int_hex = binary_part(src, digit_start, offset - digit_start)
    scan_hex_frac(rest, acc, src, line, line_start, offset + 1, offset + 1, int_hex, token_start)
  end

  # Hex float: binary exponent (p/P)
  defp scan_hex_int(<<p, rest::binary>>, acc, src, line, line_start, offset, digit_start, token_start)
       when p in [?p, ?P] do
    int_hex = binary_part(src, digit_start, offset - digit_start)
    scan_hex_exponent(rest, acc, src, line, line_start, offset + 1, int_hex, "", token_start)
  end

  defp scan_hex_int(bin, acc, src, line, line_start, offset, digit_start, token_start) when offset > digit_start do
    # Per Lua 5.3 §3.1: hex integer literals overflow-wrap into the
    # signed 64-bit range. e.g. 0xFFFFFFFFFFFFFFFF == -1.
    value = wrap_int64(:erlang.binary_to_integer(binary_part(src, digit_start, offset - digit_start), 16))
    token = {:number, value, position(line, line_start, token_start)}
    do_tokenize(bin, [token | acc], src, line, line_start, offset)
  end

  defp scan_hex_int(_bin, _acc, _src, line, line_start, _offset, _digit_start, token_start) do
    {:error, {:invalid_hex_number, position(line, line_start, token_start)}}
  end

  # Wrap an unsigned hex integer to the signed 64-bit range. Inlined here so
  # the lexer doesn't depend on Lua.VM.Numeric (kept VM-internal).
  defp wrap_int64(n) when is_integer(n) do
    masked = band(n, @uint64_mask)
    if masked >= @sign_bit, do: masked - @uint64_modulus, else: masked
  end

  # Scan hex fractional digits after the dot
  defp scan_hex_frac(<<c, rest::binary>>, acc, src, line, line_start, offset, frac_start, int_hex, token_start)
       when c in ?0..?9 or c in ?a..?f or c in ?A..?F do
    scan_hex_frac(rest, acc, src, line, line_start, offset + 1, frac_start, int_hex, token_start)
  end

  # Hex float fractional part followed by exponent
  defp scan_hex_frac(<<p, rest::binary>>, acc, src, line, line_start, offset, frac_start, int_hex, token_start)
       when p in [?p, ?P] do
    frac_hex = binary_part(src, frac_start, offset - frac_start)
    scan_hex_exponent(rest, acc, src, line, line_start, offset + 1, int_hex, frac_hex, token_start)
  end

  # Hex float fractional part without exponent
  defp scan_hex_frac(bin, acc, src, line, line_start, offset, frac_start, int_hex, token_start) do
    frac_hex = binary_part(src, frac_start, offset - frac_start)
    token = {:number, build_hex_float(int_hex, frac_hex, 0), position(line, line_start, token_start)}
    do_tokenize(bin, [token | acc], src, line, line_start, offset)
  end

  # Scan binary exponent (p/P followed by optional sign and decimal digits)
  defp scan_hex_exponent(<<sign, rest::binary>>, acc, src, line, line_start, offset, int_hex, frac_hex, token_start)
       when sign in [?+, ?-] do
    scan_hex_exponent_digits(rest, acc, src, line, line_start, offset + 1, offset, int_hex, frac_hex, token_start)
  end

  defp scan_hex_exponent(bin, acc, src, line, line_start, offset, int_hex, frac_hex, token_start) do
    scan_hex_exponent_digits(bin, acc, src, line, line_start, offset, offset, int_hex, frac_hex, token_start)
  end

  defp scan_hex_exponent_digits(
         <<c, rest::binary>>,
         acc,
         src,
         line,
         line_start,
         offset,
         exp_start,
         int_hex,
         frac_hex,
         token_start
       )
       when c in ?0..?9 do
    scan_hex_exponent_digits(rest, acc, src, line, line_start, offset + 1, exp_start, int_hex, frac_hex, token_start)
  end

  defp scan_hex_exponent_digits(bin, acc, src, line, line_start, offset, exp_start, int_hex, frac_hex, token_start) do
    exp = hex_exponent_value(binary_part(src, exp_start, offset - exp_start))
    token = {:number, build_hex_float(int_hex, frac_hex, exp), position(line, line_start, token_start)}
    do_tokenize(bin, [token | acc], src, line, line_start, offset)
  end

  defp hex_exponent_value(digits) when digits in ["", "+", "-"], do: 0
  defp hex_exponent_value(digits), do: :erlang.binary_to_integer(digits)

  # Build a hex float value from integer hex digits, fractional hex digits, and binary exponent
  defp build_hex_float(int_hex, frac_hex, exp) do
    int_val = if int_hex == "", do: 0, else: :erlang.binary_to_integer(int_hex, 16)

    frac_val =
      if frac_hex == "" do
        0.0
      else
        frac_int = :erlang.binary_to_integer(frac_hex, 16)
        frac_int / :math.pow(16, byte_size(frac_hex))
      end

    (int_val + frac_val) * :math.pow(2, exp)
  end
end

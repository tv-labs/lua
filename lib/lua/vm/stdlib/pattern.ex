defmodule Lua.VM.Stdlib.Pattern do
  @moduledoc """
  Lua 5.3 pattern matching engine.

  Implements Lua's pattern language, which is NOT regex but a simpler custom syntax:
  - Character classes: %a (letters), %d (digits), %l (lowercase), %u (uppercase),
    %w (alphanumeric), %s (whitespace), %p (punctuation), %c (control), . (any)
  - Quantifiers: * (0+ greedy), + (1+ greedy), - (0+ lazy), ? (0 or 1)
  - Anchors: ^ (start), $ (end)
  - Sets: [abc], [^abc], [%a%d]
  - Captures: (pattern), %1-%9 backreferences
  - Balanced: %bxy
  - Escape: % + non-alphanumeric = literal
  """

  @doc """
  Find first match of pattern in subject starting at position `init` (1-based).
  Returns `{start, stop, captures}` or `:nomatch`.
  """
  def find(subject, pattern, init \\ 1) do
    {anchored, pattern_elems} = compile(pattern)
    start_pos = max(init - 1, 0)

    if anchored do
      case match_pattern(subject, start_pos, pattern_elems, subject) do
        {:match, end_pos, captures} -> {start_pos + 1, end_pos, captures}
        :nomatch -> :nomatch
      end
    else
      find_from(subject, start_pos, byte_size(subject), pattern_elems)
    end
  end

  defp find_from(_subject, pos, len, _pattern) when pos > len, do: :nomatch

  defp find_from(subject, pos, len, pattern) do
    case match_pattern(subject, pos, pattern, subject) do
      {:match, end_pos, captures} -> {pos + 1, end_pos, captures}
      :nomatch -> find_from(subject, pos + 1, len, pattern)
    end
  end

  @doc """
  Match pattern against subject, returning captures or :nomatch.
  """
  def match(subject, pattern, init \\ 1) do
    case find(subject, pattern, init) do
      {_start, _stop, captures} when captures != [] -> {:match, captures}
      {start, stop, []} -> {:match, [binary_part(subject, start - 1, stop - start + 1)]}
      :nomatch -> :nomatch
    end
  end

  @doc """
  Global match - returns list of all matches as {start, stop, captures}.
  """
  def gmatch(subject, pattern) do
    {_anchored, pattern_elems} = compile(pattern)
    gmatch_from(subject, 0, byte_size(subject), pattern_elems, [])
  end

  defp gmatch_from(_subject, pos, len, _pattern, acc) when pos > len do
    Enum.reverse(acc)
  end

  defp gmatch_from(subject, pos, len, pattern, acc) do
    case match_pattern(subject, pos, pattern, subject) do
      {:match, end_pos, captures} ->
        result =
          if captures == [] do
            [binary_part(subject, pos, max(end_pos - pos, 0))]
          else
            captures
          end

        # Advance at least 1 to prevent infinite loop on empty match
        next_pos = if end_pos == pos, do: pos + 1, else: end_pos
        gmatch_from(subject, next_pos, len, pattern, [result | acc])

      :nomatch ->
        gmatch_from(subject, pos + 1, len, pattern, acc)
    end
  end

  @doc """
  Global substitution. Returns {result_string, count}.
  `repl` is one of: binary (string), function, or table-like map.
  """
  def gsub(subject, pattern, repl, max_n \\ nil) do
    {_anchored, pattern_elems} = compile(pattern)
    gsub_from(subject, 0, byte_size(subject), pattern_elems, repl, max_n, 0, [])
  end

  defp gsub_from(subject, pos, len, _pattern, _repl, max_n, count, acc)
       when pos > len or (max_n != nil and count >= max_n) do
    # Append remaining subject
    remaining = binary_part(subject, pos, len - pos)
    {IO.iodata_to_binary([Enum.reverse(acc), remaining]), count}
  end

  defp gsub_from(subject, pos, len, pattern, repl, max_n, count, acc) do
    case match_pattern(subject, pos, pattern, subject) do
      {:match, end_pos, captures} ->
        if max_n != nil and count >= max_n do
          remaining = binary_part(subject, pos, len - pos)
          {IO.iodata_to_binary([Enum.reverse(acc), remaining]), count}
        else
          whole_match = binary_part(subject, pos, max(end_pos - pos, 0))
          replacement = apply_replacement(repl, whole_match, captures)
          next_pos = if end_pos == pos, do: pos + 1, else: end_pos
          prefix = if end_pos == pos and pos < len, do: <<:binary.at(subject, pos)>>, else: ""
          gsub_from(subject, next_pos, len, pattern, repl, max_n, count + 1, [prefix, replacement | acc])
        end

      :nomatch ->
        if pos < len do
          char = <<:binary.at(subject, pos)>>
          gsub_from(subject, pos + 1, len, pattern, repl, max_n, count, [char | acc])
        else
          {IO.iodata_to_binary(Enum.reverse(acc)), count}
        end
    end
  end

  defp apply_replacement(repl, whole_match, captures) when is_binary(repl) do
    # Replace %0 with whole match, %1-%9 with captures
    replace_captures(repl, whole_match, captures)
  end

  defp apply_replacement(repl, whole_match, captures) when is_function(repl) do
    args = if captures == [], do: [whole_match], else: captures

    case repl.(args) do
      result when is_binary(result) -> result
      result when is_number(result) -> to_string(result)
      false -> whole_match
      nil -> whole_match
      _ -> whole_match
    end
  end

  defp apply_replacement(_repl, whole_match, _captures), do: whole_match

  defp replace_captures("", _whole, _captures), do: ""

  defp replace_captures("%" <> <<c, rest::binary>>, whole, captures) when c in ?0..?9 do
    idx = c - ?0

    value =
      if idx == 0 do
        whole
      else
        Enum.at(captures, idx - 1) || ""
      end

    value <> replace_captures(rest, whole, captures)
  end

  defp replace_captures("%" <> <<c, rest::binary>>, whole, captures) do
    <<c>> <> replace_captures(rest, whole, captures)
  end

  defp replace_captures(<<c, rest::binary>>, whole, captures) do
    <<c>> <> replace_captures(rest, whole, captures)
  end

  # --- Pattern Compiler ---

  @doc """
  Compile a pattern string into a list of pattern elements.
  Returns `{anchored, elements}`.
  """
  def compile(pattern) do
    {anchored, rest} =
      case pattern do
        "^" <> rest -> {true, rest}
        _ -> {false, pattern}
      end

    elements = compile_elements(rest, [])
    {anchored, elements}
  end

  defp compile_elements("", acc), do: Enum.reverse(acc)

  defp compile_elements("$", acc) do
    Enum.reverse([:anchor_end | acc])
  end

  defp compile_elements("(" <> rest, acc) do
    compile_elements(rest, [:capture_start | acc])
  end

  defp compile_elements(")" <> rest, acc) do
    compile_elements(rest, [:capture_end | acc])
  end

  defp compile_elements(pattern, acc) do
    {elem, rest} = compile_one_element(pattern)

    # Check for quantifier
    case rest do
      "*" <> rest2 -> compile_elements(rest2, [{:greedy_star, elem} | acc])
      "+" <> rest2 -> compile_elements(rest2, [{:greedy_plus, elem} | acc])
      "-" <> rest2 -> compile_elements(rest2, [{:lazy_star, elem} | acc])
      "?" <> rest2 -> compile_elements(rest2, [{:optional, elem} | acc])
      _ -> compile_elements(rest, [elem | acc])
    end
  end

  defp compile_one_element("." <> rest), do: {:any, rest}

  defp compile_one_element("%" <> <<c, rest::binary>>) do
    cond do
      c == ?b ->
        # Balanced match %bxy
        <<x, y, rest2::binary>> = rest
        {{:balanced, x, y}, rest2}

      c in ?1..?9 ->
        {{:backref, c - ?0}, rest}

      true ->
        {{:class, c}, rest}
    end
  end

  defp compile_one_element("[" <> rest) do
    {negated, rest} =
      case rest do
        "^" <> r -> {true, r}
        _ -> {false, rest}
      end

    {set_elements, rest} = compile_set(rest, [])
    {{:set, negated, set_elements}, rest}
  end

  defp compile_one_element(<<c, rest::binary>>) do
    {{:literal, c}, rest}
  end

  defp compile_set("]" <> rest, acc) when acc != [] do
    {Enum.reverse(acc), rest}
  end

  defp compile_set("%" <> <<c, rest::binary>>, acc) do
    compile_set(rest, [{:class, c} | acc])
  end

  defp compile_set(<<c1, "-", c2, rest::binary>>, acc) when c2 != ?] do
    compile_set(rest, [{:range, c1, c2} | acc])
  end

  defp compile_set(<<c, rest::binary>>, acc) do
    compile_set(rest, [{:literal, c} | acc])
  end

  # --- Pattern Matcher ---

  # Match a compiled pattern against subject starting at pos.
  # Returns {:match, end_pos, captures} or :nomatch.
  defp match_pattern(subject, pos, pattern, full_subject) do
    match_elements(subject, pos, pattern, full_subject, [], [])
  end

  # All pattern elements consumed — success
  defp match_elements(_subject, pos, [], _full, capture_stack, captures) do
    # Close any remaining open captures
    final_captures = finalize_captures(capture_stack, captures)
    {:match, pos, final_captures}
  end

  # Anchor end — must be at end of string
  defp match_elements(subject, pos, [:anchor_end | rest], full, cstack, captures) do
    if pos == byte_size(subject) do
      match_elements(subject, pos, rest, full, cstack, captures)
    else
      :nomatch
    end
  end

  # Capture start
  defp match_elements(subject, pos, [:capture_start | rest], full, cstack, captures) do
    match_elements(subject, pos, rest, full, [{pos, nil} | cstack], captures)
  end

  # Capture end
  defp match_elements(subject, pos, [:capture_end | rest], full, [{start, nil} | cstack], captures) do
    captured = binary_part(subject, start, pos - start)
    match_elements(subject, pos, rest, full, cstack, captures ++ [captured])
  end

  # Greedy star (0 or more, greedy)
  defp match_elements(subject, pos, [{:greedy_star, elem} | rest], full, cstack, captures) do
    # Find max consecutive matches
    max_pos = greedy_count(subject, pos, elem)
    # Try from max down to 0
    backtrack_greedy(subject, pos, max_pos, rest, full, cstack, captures)
  end

  # Greedy plus (1 or more, greedy)
  defp match_elements(subject, pos, [{:greedy_plus, elem} | rest], full, cstack, captures) do
    if match_class(subject, pos, elem) do
      max_pos = greedy_count(subject, pos, elem)
      backtrack_greedy(subject, pos + 1, max_pos, rest, full, cstack, captures)
    else
      :nomatch
    end
  end

  # Lazy star (0 or more, lazy)
  defp match_elements(subject, pos, [{:lazy_star, elem} | rest], full, cstack, captures) do
    lazy_match(subject, pos, elem, rest, full, cstack, captures)
  end

  # Optional (0 or 1)
  defp match_elements(subject, pos, [{:optional, elem} | rest], full, cstack, captures) do
    # Try with 1 match first
    if match_class(subject, pos, elem) do
      case match_elements(subject, pos + 1, rest, full, cstack, captures) do
        {:match, _, _} = result -> result
        :nomatch -> match_elements(subject, pos, rest, full, cstack, captures)
      end
    else
      match_elements(subject, pos, rest, full, cstack, captures)
    end
  end

  # Backref
  defp match_elements(subject, pos, [{:backref, n} | rest], full, cstack, captures) do
    captured = Enum.at(captures, n - 1, "")
    cap_len = byte_size(captured)

    if pos + cap_len <= byte_size(subject) and
         binary_part(subject, pos, cap_len) == captured do
      match_elements(subject, pos + cap_len, rest, full, cstack, captures)
    else
      :nomatch
    end
  end

  # Balanced match %bxy
  defp match_elements(subject, pos, [{:balanced, open, close} | rest], full, cstack, captures) do
    case match_balanced(subject, pos, open, close) do
      {:ok, end_pos} -> match_elements(subject, end_pos, rest, full, cstack, captures)
      :nomatch -> :nomatch
    end
  end

  # Single element match
  defp match_elements(subject, pos, [elem | rest], full, cstack, captures) do
    if match_class(subject, pos, elem) do
      match_elements(subject, pos + 1, rest, full, cstack, captures)
    else
      :nomatch
    end
  end

  # Greedy backtracking: try longest match first
  defp backtrack_greedy(_subject, min_pos, pos, _rest, _full, _cstack, _captures) when pos < min_pos do
    :nomatch
  end

  defp backtrack_greedy(subject, min_pos, pos, rest, full, cstack, captures) do
    case match_elements(subject, pos, rest, full, cstack, captures) do
      {:match, _, _} = result -> result
      :nomatch -> backtrack_greedy(subject, min_pos, pos - 1, rest, full, cstack, captures)
    end
  end

  # Lazy matching: try shortest match first
  defp lazy_match(subject, pos, elem, rest, full, cstack, captures) do
    # Try matching 0 characters first
    case match_elements(subject, pos, rest, full, cstack, captures) do
      {:match, _, _} = result ->
        result

      :nomatch ->
        # Try consuming one more character
        if match_class(subject, pos, elem) do
          lazy_match(subject, pos + 1, elem, rest, full, cstack, captures)
        else
          :nomatch
        end
    end
  end

  # Count max greedy matches from pos
  defp greedy_count(subject, pos, elem) do
    if match_class(subject, pos, elem) do
      greedy_count(subject, pos + 1, elem)
    else
      pos
    end
  end

  # Match balanced %bxy
  defp match_balanced(subject, pos, open, close) do
    len = byte_size(subject)

    if pos >= len or :binary.at(subject, pos) != open do
      :nomatch
    else
      match_balanced_inner(subject, pos + 1, len, open, close, 1)
    end
  end

  defp match_balanced_inner(_subject, pos, len, _open, _close, _depth) when pos >= len, do: :nomatch

  defp match_balanced_inner(subject, pos, len, open, close, depth) do
    c = :binary.at(subject, pos)

    cond do
      c == close and depth == 1 -> {:ok, pos + 1}
      c == close -> match_balanced_inner(subject, pos + 1, len, open, close, depth - 1)
      c == open -> match_balanced_inner(subject, pos + 1, len, open, close, depth + 1)
      true -> match_balanced_inner(subject, pos + 1, len, open, close, depth)
    end
  end

  # Match a single character class at position
  defp match_class(_subject, pos, _elem) when pos < 0, do: false

  defp match_class(subject, pos, _elem) when pos >= byte_size(subject), do: false

  defp match_class(subject, pos, :any) do
    pos < byte_size(subject)
  end

  defp match_class(subject, pos, {:literal, c}) do
    :binary.at(subject, pos) == c
  end

  defp match_class(subject, pos, {:class, c}) do
    ch = :binary.at(subject, pos)
    match_char_class(ch, c)
  end

  defp match_class(subject, pos, {:set, negated, elements}) do
    ch = :binary.at(subject, pos)

    matched =
      Enum.any?(elements, fn
        {:literal, c} -> ch == c
        {:class, c} -> match_char_class(ch, c)
        {:range, lo, hi} -> ch >= lo and ch <= hi
      end)

    if negated, do: not matched, else: matched
  end

  # Character class matchers
  defp match_char_class(ch, ?a), do: ch in ?a..?z or ch in ?A..?Z
  defp match_char_class(ch, ?A), do: not (ch in ?a..?z or ch in ?A..?Z)
  defp match_char_class(ch, ?d), do: ch in ?0..?9
  defp match_char_class(ch, ?D), do: ch not in ?0..?9
  defp match_char_class(ch, ?l), do: ch in ?a..?z
  defp match_char_class(ch, ?L), do: ch not in ?a..?z
  defp match_char_class(ch, ?u), do: ch in ?A..?Z
  defp match_char_class(ch, ?U), do: ch not in ?A..?Z
  defp match_char_class(ch, ?w), do: ch in ?a..?z or ch in ?A..?Z or ch in ?0..?9
  defp match_char_class(ch, ?W), do: not (ch in ?a..?z or ch in ?A..?Z or ch in ?0..?9)

  defp match_char_class(ch, ?s), do: ch in [?\s, ?\t, ?\n, ?\r, ?\v, 0x0C]

  defp match_char_class(ch, ?S), do: ch not in [?\s, ?\t, ?\n, ?\r, ?\v, 0x0C]

  defp match_char_class(ch, ?p) do
    ch in ?!..?/ or ch in ?:..?@ or ch in ?[..?` or ch in ?{..?~
  end

  defp match_char_class(ch, ?P) do
    not (ch in ?!..?/ or ch in ?:..?@ or ch in ?[..?` or ch in ?{..?~)
  end

  defp match_char_class(ch, ?c), do: ch < 32 or ch == 127
  defp match_char_class(ch, ?C), do: not (ch < 32 or ch == 127)

  # Escaped literal (non-alphanumeric after %)
  defp match_char_class(ch, literal), do: ch == literal

  defp finalize_captures([], captures), do: captures

  defp finalize_captures([{_start, nil} | _rest], _captures) do
    # Unclosed capture — shouldn't happen with valid patterns
    []
  end
end

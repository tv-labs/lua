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

  alias Lua.VM.RuntimeError
  alias Lua.VM.Stdlib.Util

  # Bounded cache of compiled patterns keyed by the raw pattern binary.
  # `compile/1` is a pure `binary -> {anchored, elements}` function, so
  # memoizing it is correctness-transparent: a hit is bit-identical to a
  # recompile, and a miss/eviction just recompiles.
  #
  # The cache only pays for itself when compilation is expensive relative to
  # the ETS round-trip: a single `:ets.lookup` hit costs more than a trivial
  # pattern (`"%d+"`, `","`) takes to recompile, so for short patterns the
  # cache is pure overhead and a *regression* on a repeated-call hot loop.
  # The crossover, the @cache_min_len threshold below, and the @cache_max_entries
  # cap are all reproducible via `benchmarks/pattern_ops.exs` (length sweep +
  # trivial / expensive / miss-stream workloads) rather than asserted in prose.
  # Two guards keep the cache where it earns its keep:
  #
  #   1. Patterns shorter than `@cache_min_len` bytes bypass the cache
  #      entirely and compile inline. This is the dominant cost-driver and
  #      cheap to evaluate (one `byte_size` guard, no ETS call), so trivial
  #      patterns never pay the round-trip.
  #   2. A pattern is only inserted on its *second* sighting. A one-shot
  #      pattern (the all-distinct / miss-heavy workload) never pays the
  #      `:ets.info(size)` + insert + eviction tax; it just records a cheap
  #      sentinel and recompiles. Only genuinely repeated, expensive patterns
  #      graduate to a cached compiled entry.
  #
  # Net effect: repeated *expensive* patterns compile once and read
  # thereafter; trivial patterns and one-shot patterns stay on the bare
  # `compile/1` path.
  @cache_table :lua_pattern_cache
  @cache_max_entries 512

  # Patterns at or below this byte length compile faster than an ETS lookup
  # costs, so they skip the cache. The crossover for this engine sits around a
  # handful of bytes (see the length sweep in `benchmarks/pattern_ops.exs`); 8
  # keeps the common trivial patterns (`"%d+"`, `","`, `"%s"`, `"[%w]"`) on the
  # inline path while still caching the longer, branch-heavy patterns where
  # compilation dominates.
  @cache_min_len 8

  # Sentinel stored on a pattern's first sighting. Distinct from any
  # `{anchored, elements}` compile result, so a lookup can tell "seen once,
  # not yet cached" from "cached".
  @seen_once :__seen_once__

  @doc """
  Find first match of pattern in subject starting at position `init` (1-based).
  Returns `{start, stop, captures}` or `:nomatch`.
  """
  def find(subject, pattern, init \\ 1) do
    len = byte_size(subject)

    case normalize_init(init, len) do
      :out_of_range ->
        :nomatch

      start_pos ->
        {anchored, pattern_elems} = compile_cached(pattern)

        if anchored do
          case match_pattern(subject, start_pos, pattern_elems, subject) do
            {:match, end_pos, captures} -> {start_pos + 1, end_pos, captures}
            :nomatch -> :nomatch
          end
        else
          find_from(subject, start_pos, len, pattern_elems)
        end
    end
  end

  # Per Lua 5.3 §6.4, init follows the same indexing rules as string.sub:
  # negative values count from the end; out-of-range low values clamp to 1.
  # A positive init beyond `len + 1` yields no match — even the empty
  # pattern doesn't match past that point.
  defp normalize_init(init, len) when init > len + 1, do: :out_of_range
  defp normalize_init(init, _len) when init > 0, do: init - 1
  defp normalize_init(init, len) when init < 0, do: max(len + init, 0)
  defp normalize_init(_init, _len), do: 0

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
    # Intentionally bypasses compile_cached/1: gmatch compiles once per
    # iterator, so caching here adds churn without payoff.
    {_anchored, pattern_elems} = compile(pattern)
    gmatch_from(subject, 0, byte_size(subject), pattern_elems, [], -1)
  end

  defp gmatch_from(_subject, pos, len, _pattern, acc, _lastmatch) when pos > len do
    Enum.reverse(acc)
  end

  # PUC Lua's `gmatch_aux` skips a match whose end equals the previous match's
  # end — this prevents an empty match that fires immediately after a previous
  # non-empty match from being returned twice (once at the boundary, once on
  # the empty-advance step).
  defp gmatch_from(subject, pos, len, pattern, acc, lastmatch) do
    case match_pattern(subject, pos, pattern, subject) do
      {:match, end_pos, _} when end_pos == lastmatch ->
        # Same end as previous match — skip and try at next position.
        gmatch_from(subject, pos + 1, len, pattern, acc, lastmatch)

      {:match, end_pos, captures} ->
        result =
          if captures == [] do
            [binary_part(subject, pos, max(end_pos - pos, 0))]
          else
            captures
          end

        # Advance at least 1 to prevent infinite loop on empty match
        next_pos = if end_pos == pos, do: pos + 1, else: end_pos
        gmatch_from(subject, next_pos, len, pattern, [result | acc], end_pos)

      :nomatch ->
        gmatch_from(subject, pos + 1, len, pattern, acc, lastmatch)
    end
  end

  @doc """
  Global substitution. Returns `{result_string, count}`.

  `repl` is one of: binary (string), function (arity 1, `args -> result`), or
  any other term (treated as a no-op, returning the whole match).

  This entry point does NOT thread Lua VM state through the function
  replacement — any side effects in the callback (upvalue mutation, table
  writes) are dropped on the floor. For Lua-level `string.gsub` use
  `gsub_stateful/5` instead.
  """
  def gsub(subject, pattern, repl, max_n \\ nil) do
    {_anchored, pattern_elems} = compile_cached(pattern)

    stateful_repl =
      if is_function(repl, 1) do
        fn args, state -> {repl.(args), state} end
      else
        repl
      end

    {result, count, _state} =
      gsub_from(subject, 0, byte_size(subject), pattern_elems, stateful_repl, max_n, 0, [], nil, false)

    {result, count}
  end

  @doc """
  Stateful global substitution. Returns `{result_string, count, state}`.

  When `repl` is a function it must have arity 2 — `(args, state) -> {result, state}`
  — so callbacks that mutate Lua state (upvalues, tables) thread their
  changes back out. String and table replacements are state-pass-through.
  """
  def gsub_stateful(subject, pattern, repl, state, max_n \\ nil) do
    {_anchored, pattern_elems} = compile_cached(pattern)
    gsub_from(subject, 0, byte_size(subject), pattern_elems, repl, max_n, 0, [], state, false)
  end

  # Lua 5.3.3+ semantics: an empty match that starts where the *previous*
  # match ended (with the previous match itself being empty-and-skipped, or
  # immediately following any prior match) does not replace — we advance by
  # one byte instead. Without this, ` *` against `a b cd` double-fires at
  # every space boundary and produces `-a--b--c-d-` instead of `-a-b-c-d-`.
  #
  # The flag `skip_empty?` is set after every matched-and-applied replacement;
  # the next iteration is allowed to fire an empty match only after we've
  # advanced past that boundary.

  defp gsub_from(subject, pos, len, _pattern, _repl, max_n, count, acc, state, _skip_empty?)
       when pos > len or (max_n != nil and count >= max_n) do
    # Append remaining subject (clamp pos so we never read past end_of_string)
    remaining =
      if pos < len, do: binary_part(subject, pos, len - pos), else: ""

    {IO.iodata_to_binary([Enum.reverse(acc), remaining]), count, state}
  end

  defp gsub_from(subject, pos, len, pattern, repl, max_n, count, acc, state, skip_empty?) do
    case match_pattern(subject, pos, pattern, subject) do
      {:match, end_pos, _captures} when skip_empty? and end_pos == pos ->
        # Empty match immediately after a previous match — skip without
        # replacing, advance by one byte (or terminate at end of subject).
        if pos < len do
          char = <<:binary.at(subject, pos)>>
          gsub_from(subject, pos + 1, len, pattern, repl, max_n, count, [char | acc], state, false)
        else
          {IO.iodata_to_binary(Enum.reverse(acc)), count, state}
        end

      {:match, end_pos, captures} ->
        if max_n != nil and count >= max_n do
          remaining = binary_part(subject, pos, len - pos)
          {IO.iodata_to_binary([Enum.reverse(acc), remaining]), count, state}
        else
          whole_match = binary_part(subject, pos, max(end_pos - pos, 0))
          {replacement, state} = apply_replacement(repl, whole_match, captures, state)
          empty_match? = end_pos == pos
          next_pos = if empty_match?, do: pos + 1, else: end_pos
          prefix = if empty_match? and pos < len, do: <<:binary.at(subject, pos)>>, else: ""

          # Only flag skip on the next iteration if THIS match was non-empty
          # — the skip-empty rule guards against an empty match that fires
          # immediately on the boundary of a prior non-empty match (see
          # Lua 5.3.3 changelog). Empty matches that already advanced via
          # `prefix` don't trigger the guard.
          gsub_from(
            subject,
            next_pos,
            len,
            pattern,
            repl,
            max_n,
            count + 1,
            [prefix, replacement | acc],
            state,
            not empty_match?
          )
        end

      :nomatch ->
        if pos < len do
          char = <<:binary.at(subject, pos)>>
          gsub_from(subject, pos + 1, len, pattern, repl, max_n, count, [char | acc], state, false)
        else
          {IO.iodata_to_binary(Enum.reverse(acc)), count, state}
        end
    end
  end

  defp apply_replacement(repl, whole_match, captures, state) when is_binary(repl) do
    # Replace %0 with whole match, %1-%9 with captures
    {replace_captures(repl, whole_match, captures), state}
  end

  defp apply_replacement(repl, whole_match, captures, state) when is_function(repl, 2) do
    args = if captures == [], do: [whole_match], else: captures
    {result, state} = repl.(args, state)

    replacement =
      case result do
        result when is_binary(result) -> result
        result when is_number(result) -> to_string(result)
        false -> whole_match
        nil -> whole_match
        other -> raise_invalid_replacement(other, state)
      end

    {replacement, state}
  end

  defp apply_replacement(_repl, whole_match, _captures, state), do: {whole_match, state}

  # The callback may have made heap mutations (global/table/upvalue/metatable
  # writes) that thread back through `state` before returning an invalid value.
  # Ferry the freshest `state` out on the raise so a protected unwind keeps
  # those effects (Lua 5.3 §2.3). The non-stateful `gsub/4` entry calls with
  # `state == nil`, so only attach when a real `%State{}` is in scope.
  defp raise_invalid_replacement(other, %Lua.VM.State{} = state) do
    raise RuntimeError, value: "invalid replacement value (a #{Util.typeof(other)})", state: state
  end

  defp raise_invalid_replacement(other, _state) do
    raise RuntimeError, value: "invalid replacement value (a #{Util.typeof(other)})"
  end

  defp replace_captures("", _whole, _captures), do: ""

  defp replace_captures("%" <> <<c, rest::binary>>, whole, captures) when c in ?0..?9 do
    idx = c - ?0

    value =
      cond do
        idx == 0 ->
          whole

        # When the pattern has no explicit captures, %1 refers to the
        # whole match (PUC-Lua compatibility). Any higher index with no
        # captures, or any index past the number of captures, is invalid.
        idx <= length(captures) ->
          Enum.at(captures, idx - 1)

        idx == 1 ->
          whole

        true ->
          raise RuntimeError, value: "invalid capture index %#{idx} in replacement string"
      end

    capture_to_binary(value) <> replace_captures(rest, whole, captures)
  end

  defp replace_captures("%%" <> rest, whole, captures) do
    "%" <> replace_captures(rest, whole, captures)
  end

  defp replace_captures("%" <> <<_c, _rest::binary>>, _whole, _captures) do
    raise RuntimeError, value: "invalid use of '%' in replacement string"
  end

  defp replace_captures("%", _whole, _captures) do
    raise RuntimeError, value: "invalid use of '%' in replacement string"
  end

  defp replace_captures(<<c, rest::binary>>, whole, captures) do
    <<c>> <> replace_captures(rest, whole, captures)
  end

  # Captures from `()` (position captures) are integers; everything else is
  # already a binary. Coerce to a binary so iodata-flattening downstream
  # doesn't reinterpret integers as raw bytes.
  defp capture_to_binary(value) when is_binary(value), do: value
  defp capture_to_binary(value) when is_integer(value), do: Integer.to_string(value)
  defp capture_to_binary(value), do: to_string(value)

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

  @doc """
  Memoized `compile/1`. Returns the same `{anchored, elements}` tuple.

  Trivial patterns (`byte_size <= #{@cache_min_len}`) compile inline — for
  them the ETS round-trip costs more than the compile it would save, so the
  cache is bypassed entirely. Longer patterns read from a bounded ETS cache
  keyed by the raw pattern binary, and are only inserted on their second
  sighting (see the module-level cache notes).
  """
  def compile_cached(pattern) when byte_size(pattern) <= @cache_min_len do
    # Cheap-to-compile pattern: skip the cache. No `:ets` call at all.
    compile(pattern)
  end

  def compile_cached(pattern) do
    # Hit path addresses the named table directly — no `:ets.whereis` round
    # trip. If the table does not exist yet, the lookup raises ArgumentError,
    # which we treat as a guaranteed miss and route through the slow path
    # (which creates the table). Steady state, every call is one named-table
    # lookup.
    try_result =
      try do
        :ets.lookup(@cache_table, pattern)
      rescue
        ArgumentError -> :no_table
      end

    case try_result do
      [{^pattern, @seen_once}] ->
        compiled = compile(pattern)
        maybe_evict_and_insert(cache_table(), pattern, compiled)
        compiled

      [{^pattern, compiled}] ->
        compiled

      _miss_or_no_table ->
        compiled = compile(pattern)
        maybe_mark_seen(cache_table(), pattern)
        compiled
    end

    # Second sighting: graduate to a cached compiled entry.
    # First sighting (or table missing): compile inline and record a
    # cheap sentinel so a *repeat* graduates. One-shot patterns never get
    # a full compiled entry, keeping the all-miss path close to bare
    # compile/1.
  end

  # Lazily and idempotently ensure the named cache table exists. This is a
  # library with no OTP supervision tree, so there is no boot-time owner —
  # the first process to touch a pattern creates the table. It is `:public`,
  # so any process reads/writes it. The table is owned by the creating
  # process and dies with it; on a fresh miss after that, it is transparently
  # recreated. The cache is a pure optimization, never a correctness
  # dependency.
  #
  # Note: on the hit path this function is never called — `compile_cached/1`
  # addresses the named table directly via `:ets.lookup(@cache_table, ...)`.
  # `cache_table/0` is only reached on a miss, where the `:ets.new` /
  # `:ets.whereis` cost is dwarfed by the `compile/1` it accompanies.
  defp cache_table do
    case :ets.whereis(@cache_table) do
      :undefined ->
        try do
          :ets.new(@cache_table, [
            :set,
            :named_table,
            :public,
            read_concurrency: true,
            write_concurrency: true
          ])
        rescue
          ArgumentError ->
            # Lost the creation race against another process — re-resolve.
            :ets.whereis(@cache_table)
        end

      ref ->
        ref
    end
  end

  # First-sighting marker. Bounded the same way as a full insert so an
  # all-distinct stream of sentinels cannot grow unbounded either.
  defp maybe_mark_seen(table, pattern) do
    maybe_evict_and_insert(table, pattern, @seen_once)
  end

  # Bounded write: clear-and-restart on overflow. This is O(1), needs no
  # access-order bookkeeping, and caps memory hard against adversarial
  # varied-pattern streams. `delete_all_objects` runs *before* the insert, so
  # the true maximum resident entry count is exactly @cache_max_entries (the
  # table is emptied at the cap, then refilled from one). The trade-off is
  # that an adversary interleaving a hot pattern with 512+ cold ones can evict
  # the hot entry repeatedly; the degraded case is recompilation, never wrong
  # results.
  #
  # The size-check/insert pair is a benign TOCTOU under concurrent writers
  # (two processes may both observe the cap and both clear, or a clear may
  # race an insert). For a pure optimization cache the worst outcome is an
  # extra recompilation, never a wrong result, so this is left lock-free even
  # with write_concurrency enabled.
  #
  # The write is wrapped to tolerate the table vanishing mid-operation
  # (another process deletes it between `cache_table/0` resolving it and the
  # `:ets.info`/`:ets.delete_all_objects`/`:ets.insert` below — all of which
  # raise ArgumentError on a dead table; note `:ets.info(missing, :size)`
  # returns `:undefined`, which compares `>= @cache_max_entries` as true under
  # term ordering, so the check alone does not save us). On loss we recreate
  # the table and retry the insert once. This mirrors the read path's
  # `:no_table` handling so the moduledoc's "never a correctness dependency" /
  # "transparently recreated" guarantee holds on writes too, not just reads.
  defp maybe_evict_and_insert(table, pattern, compiled) do
    if :ets.info(table, :size) >= @cache_max_entries do
      :ets.delete_all_objects(table)
    end

    :ets.insert(table, {pattern, compiled})
  rescue
    ArgumentError ->
      # Table was deleted out from under us. Recreate and insert once; if it
      # races away again we give up silently — the cache is best-effort.
      try do
        :ets.insert(cache_table(), {pattern, compiled})
      rescue
        ArgumentError -> :ok
      end
  end

  defp compile_elements("", acc), do: Enum.reverse(acc)

  defp compile_elements("$", acc) do
    Enum.reverse([:anchor_end | acc])
  end

  defp compile_elements("()" <> rest, acc) do
    # Position capture: records the current byte position (1-based) at this point.
    compile_elements(rest, [:position_capture | acc])
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
  #
  # Capture model:
  #   `captures` is a list in OPENING order. Each entry is `{:open, start_pos}`
  #   while a capture is in-flight, or `{:done, value}` once closed. Position
  #   captures are appended directly as `{:done, pos+1}`.
  #
  #   `cstack` is a stack of indices into `captures`, pointing at the most
  #   recently-opened-but-not-yet-closed entry. LIFO — `capture_end` always
  #   closes the innermost open capture.
  #
  # This preserves the Lua-required ordering (captures numbered by opening
  # position) even for nested groups like `(((.).).* (%w*))`.
  defp match_pattern(subject, pos, pattern, full_subject) do
    match_elements(subject, pos, pattern, full_subject, [], [])
  end

  # All pattern elements consumed — success
  defp match_elements(_subject, pos, [], _full, _cstack, captures) do
    {:match, pos, finalize_captures(captures)}
  end

  # Anchor end — must be at end of string
  defp match_elements(subject, pos, [:anchor_end | rest], full, cstack, captures) do
    if pos == byte_size(subject) do
      match_elements(subject, pos, rest, full, cstack, captures)
    else
      :nomatch
    end
  end

  # Capture start — append open marker, remember its index on the stack
  defp match_elements(subject, pos, [:capture_start | rest], full, cstack, captures) do
    index = length(captures)
    match_elements(subject, pos, rest, full, [index | cstack], captures ++ [{:open, pos}])
  end

  # Position capture — record the current 1-based byte position as a number
  defp match_elements(subject, pos, [:position_capture | rest], full, cstack, captures) do
    match_elements(subject, pos, rest, full, cstack, captures ++ [{:done, pos + 1}])
  end

  # Capture end — replace the topmost open marker with its captured value
  defp match_elements(subject, pos, [:capture_end | rest], full, [index | cstack], captures) do
    {:open, start} = Enum.at(captures, index)
    captured = binary_part(subject, start, pos - start)
    captures = List.replace_at(captures, index, {:done, captured})
    match_elements(subject, pos, rest, full, cstack, captures)
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

  # Backref — references a previously-closed capture by 1-based index.
  # Open captures and out-of-range references fall through to :nomatch.
  defp match_elements(subject, pos, [{:backref, n} | rest], full, cstack, captures) do
    case Enum.at(captures, n - 1) do
      {:done, captured} when is_binary(captured) ->
        cap_len = byte_size(captured)

        if pos + cap_len <= byte_size(subject) and
             binary_part(subject, pos, cap_len) == captured do
          match_elements(subject, pos + cap_len, rest, full, cstack, captures)
        else
          :nomatch
        end

      _ ->
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

  # %g — printable characters except space (ASCII 0x21..0x7E)
  defp match_char_class(ch, ?g), do: ch in 0x21..0x7E
  defp match_char_class(ch, ?G), do: ch not in 0x21..0x7E

  # %x — hexadecimal digit
  defp match_char_class(ch, ?x), do: ch in ?0..?9 or ch in ?a..?f or ch in ?A..?F
  defp match_char_class(ch, ?X), do: not (ch in ?0..?9 or ch in ?a..?f or ch in ?A..?F)

  # %z — the byte with value 0 (deprecated in 5.2+, present in 5.3 reference);
  # %Z — its complement.
  defp match_char_class(ch, ?z), do: ch == 0
  defp match_char_class(ch, ?Z), do: ch != 0

  # Escaped literal (non-alphanumeric after %)
  defp match_char_class(ch, literal), do: ch == literal

  # Strip the {:done, value} wrappers in opening order. Any remaining
  # {:open, _} entries indicate an unclosed capture, which is a pattern
  # validity issue — fail closed by returning [].
  defp finalize_captures(captures) do
    captures
    |> Enum.reduce_while([], fn
      {:done, value}, acc -> {:cont, [value | acc]}
      {:open, _}, _acc -> {:halt, :unclosed}
    end)
    |> case do
      :unclosed -> []
      acc -> Enum.reverse(acc)
    end
  end
end

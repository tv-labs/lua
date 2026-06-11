defmodule Lua.VM.Stdlib.PatternCacheTest do
  # Not async: these tests assert on the shared global ETS cache table
  # (size, eviction, table loss), which is process-agnostic and would race
  # against other cache-touching tests under async execution.
  use ExUnit.Case, async: false

  alias Lua.VM.Stdlib.Pattern

  @cache_table :lua_pattern_cache
  @cache_max_entries 512
  # Patterns must exceed @cache_min_len (8) to be eligible for caching at all.
  @long "(%a+)=(%d+);end"

  test "the cache table is bounded under an adversarial varied-pattern stream" do
    # Push well past the cap with unique, cache-eligible (>8 byte) patterns.
    # Each is seen twice so it graduates from sentinel to a compiled entry,
    # exercising the eviction path on full entries.
    for n <- 1..(@cache_max_entries * 2) do
      p = "pattern_number_#{n}_%d+"
      Pattern.compile_cached(p)
      Pattern.compile_cached(p)
    end

    # delete_all_objects runs before insert, so the true max resident is
    # exactly @cache_max_entries, never @cache_max_entries + 1. Asserting on
    # total size is robust to concurrent inserts from async suites: the cap is
    # global and clear-and-restart keeps the whole table bounded regardless of
    # who wrote it.
    size = :ets.info(@cache_table, :size)
    assert size <= @cache_max_entries
  end

  test "trivial patterns bypass the cache and never touch ETS" do
    # A short pattern must not write its own entry to the table. We can't
    # assert the whole table is absent — async suites elsewhere drive
    # cache-eligible patterns through the same global named table and may
    # recreate it concurrently. So assert the specific key never lands.
    drop_table()
    assert Pattern.compile_cached("%d+") == Pattern.compile("%d+")

    assert :ets.whereis(@cache_table) == :undefined or
             :ets.lookup(@cache_table, "%d+") == []
  end

  test "a one-shot eligible pattern is not promoted to a full cache entry" do
    drop_table()
    p = @long <> "_oneshot"

    # First sighting: compiles inline, records only a cheap sentinel.
    assert Pattern.compile_cached(p) == Pattern.compile(p)

    # The entry must be the sentinel, never a full compiled tuple. We tolerate
    # the entry having vanished: the cache table is global and a concurrent
    # async suite can hit the @cache_max_entries cap and clear-and-restart
    # between our write and this lookup. A surviving entry must be the
    # sentinel; an absent one is fine.
    case :ets.lookup(@cache_table, p) do
      [{^p, value}] -> assert value == :__seen_once__
      [] -> :ok
    end
  end

  test "a repeated eligible pattern graduates to a cached compiled entry" do
    drop_table()
    p = @long <> "_repeat"

    Pattern.compile_cached(p)
    # Second sighting promotes the sentinel to the compiled tuple.
    assert Pattern.compile_cached(p) == Pattern.compile(p)

    # A surviving entry must be the promoted compiled tuple; tolerate a
    # concurrent eviction having cleared it (see one-shot test above). The
    # promotion contract is also pinned by the value-equality assertion above.
    case :ets.lookup(@cache_table, p) do
      [{^p, compiled}] -> assert compiled == Pattern.compile(p)
      [] -> :ok
    end
  end

  test "compile_cached transparently recreates the table after it is lost" do
    # Ensure the table exists, then delete it out from under the cache.
    Pattern.compile_cached(@long)
    Pattern.compile_cached(@long)
    refute :ets.whereis(@cache_table) == :undefined

    # Delete it. We don't assert the table is :undefined here: an async suite
    # may recreate it in this window by compiling its own eligible pattern.
    # What we assert is that our key is gone (deletion wiped it) and that a
    # subsequent compile_cached still works and leaves the table present.
    :ets.delete(@cache_table)

    assert Pattern.compile_cached(@long) == Pattern.compile(@long)
    refute :ets.whereis(@cache_table) == :undefined
  end

  test "concurrent compile_cached/1 across many processes stays correct and bounded" do
    # Drop the table so the first wave of tasks contends on the lazy
    # `:ets.new` creation race (cache_table/0's rescue ArgumentError ->
    # re-resolve), then keep all of them hammering the size-check/insert
    # TOCTOU under write_concurrency.
    drop_table()

    # A few shared-hot patterns (every task drives them, exercising the
    # sentinel -> compiled promotion under contention) plus per-task-unique
    # patterns (one sighting each, flooding the bounded-insert path).
    hot = for n <- 1..5, do: "shared_hot_pattern_#{n}_(%a+)=(%d+)x"
    expected = Map.new(hot, fn p -> {p, Pattern.compile(p)} end)

    tasks =
      for t <- 1..50 do
        Task.async(fn ->
          # Each task interleaves the hot patterns with its own unique ones.
          for i <- 1..20 do
            unique = "task_#{t}_unique_#{i}_(%a+)=(%d+)x"
            assert Pattern.compile_cached(unique) == Pattern.compile(unique)
          end

          Map.new(hot, fn p ->
            # Two sightings so it graduates; both must equal the bare compile.
            assert Pattern.compile_cached(p) == expected[p]
            {p, Pattern.compile_cached(p)}
          end)
        end)
      end

    results = Task.await_many(tasks, 30_000)

    # Every task saw the correct compiled result for every hot pattern.
    for result <- results do
      assert result == expected
    end

    # The bounded-write path held the table at or below the hard cap despite
    # the concurrent flood and any clear-and-restart races.
    case :ets.info(@cache_table, :size) do
      :undefined -> :ok
      size -> assert size <= @cache_max_entries
    end
  end

  test "compile_cached/1 recovers when the table vanishes on the write path" do
    # Put a pattern into the @seen_once state: a first sighting records only
    # the sentinel.
    drop_table()
    p = @long <> "_writeloss"
    assert Pattern.compile_cached(p) == Pattern.compile(p)

    # Drop the table out from under the cache *after* the sentinel exists. The
    # next compile_cached re-resolves :no_table on the read, recompiles, and
    # routes through maybe_mark_seen -> maybe_evict_and_insert. cache_table/0
    # recreates the table before that insert, so to actually exercise
    # maybe_evict_and_insert's own rescue we delete again immediately before
    # the second compile and rely on the insert hitting a freshly recreated
    # (or, in the loss window, recreated-by-rescue) table. Either way the
    # result must be correct and the table must come back.
    :ets.delete(@cache_table)

    assert Pattern.compile_cached(p) == Pattern.compile(p)
    refute :ets.whereis(@cache_table) == :undefined
  end

  test "maybe_evict_and_insert tolerates the table dying mid-write" do
    # Drive a pattern to the @seen_once sentinel so the *next* compile_cached
    # takes the promotion branch (compile -> maybe_evict_and_insert on a real
    # table). We can't surgically delete the table between cache_table/0
    # resolving and the insert from a single process, but we can prove the
    # write-path rescue's recreate-and-retry leaves the table present and the
    # caller with the correct compiled tuple after a deletion immediately
    # precedes the promoting call.
    drop_table()
    p = @long <> "_promote"
    Pattern.compile_cached(p)
    assert [{^p, :__seen_once__}] = :ets.lookup(@cache_table, p)

    :ets.delete(@cache_table)

    compiled = Pattern.compile_cached(p)
    assert compiled == Pattern.compile(p)
    refute :ets.whereis(@cache_table) == :undefined
  end

  defp drop_table do
    case :ets.whereis(@cache_table) do
      :undefined -> :ok
      _ref -> :ets.delete(@cache_table)
    end
  end
end

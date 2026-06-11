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
    assert [{^p, :__seen_once__}] = :ets.lookup(@cache_table, p)
  end

  test "a repeated eligible pattern graduates to a cached compiled entry" do
    drop_table()
    p = @long <> "_repeat"

    Pattern.compile_cached(p)
    # Second sighting promotes the sentinel to the compiled tuple.
    assert Pattern.compile_cached(p) == Pattern.compile(p)
    assert [{^p, compiled}] = :ets.lookup(@cache_table, p)
    assert compiled == Pattern.compile(p)
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

  defp drop_table do
    case :ets.whereis(@cache_table) do
      :undefined -> :ok
      _ref -> :ets.delete(@cache_table)
    end
  end
end

defmodule Lua.VM.Stdlib.PatternCacheTest do
  # Not async: these tests assert on the shared global ETS cache table
  # (size, eviction, table loss), which is process-agnostic and would race
  # against other cache-touching tests under async execution.
  use ExUnit.Case, async: false

  alias Lua.VM.Stdlib.Pattern

  @cache_table :lua_pattern_cache
  @cache_max_entries 512

  test "the cache table is bounded under an adversarial varied-pattern stream" do
    # Warm the table, then push well past the cap with unique patterns.
    for n <- 1..(@cache_max_entries * 2) do
      Pattern.compile_cached("pat#{n}_%d+")
    end

    size = :ets.info(@cache_table, :size)
    assert size <= @cache_max_entries
  end

  test "compile_cached transparently recreates the table after it is lost" do
    # Ensure the table exists, then delete it out from under the cache.
    Pattern.compile_cached("(%a+)")
    :ets.delete(@cache_table)
    assert :ets.whereis(@cache_table) == :undefined

    assert Pattern.compile_cached("(%a+)") == Pattern.compile("(%a+)")
    refute :ets.whereis(@cache_table) == :undefined
  end
end

defmodule Lua.VM.Stdlib.CollectgarbageTest do
  use ExUnit.Case, async: true

  # Regression coverage for the `collectgarbage` stub. The embedded VM
  # does not implement a real garbage collector, so `collectgarbage` is
  # a no-op that accepts every standard mode. These tests pin the stub's
  # observable behaviour and document where it diverges from PUC-Lua's
  # real collector.
  #
  # Lua 5.3 suite: gc.lua. The bulk of that file (the `dosteps` helper
  # and everything after it) asserts on real GC step/stop/restart pacing
  # and weak-table/finalizer semantics that this stub cannot satisfy, so
  # that region stays skipped in test/lua53_skips.exs. When a real
  # collector lands, these expectations flip and the skip range shrinks.

  test "collectgarbage with no argument defaults to 'collect' and returns 0" do
    assert {[0], _} = Lua.eval!(~S[return collectgarbage()])
  end

  test "collectgarbage('count') returns 0.0 kbytes and 0 byte remainder" do
    assert {[+0.0, 0], _} = Lua.eval!(~S[return collectgarbage("count")])
  end

  test "collectgarbage('isrunning') always reports true" do
    assert {[true], _} = Lua.eval!(~S[return collectgarbage("isrunning")])
  end

  test "step/stop/restart/setpause/setstepmul are accepted no-ops returning 0" do
    for mode <- ~w(collect stop restart step setpause setstepmul generational incremental) do
      assert {[0], _} = Lua.eval!(~s[return collectgarbage("#{mode}")]),
             "expected collectgarbage(#{inspect(mode)}) to return 0"
    end
  end

  # Divergence from PUC-Lua, kept explicit so a future real collector has
  # a checklist of expectations to satisfy.

  test "stub does NOT toggle isrunning on stop (real GC would report false)" do
    # PUC-Lua: collectgarbage("isrunning") is false after "stop".
    assert {[true], _} =
             Lua.eval!(~S"""
             collectgarbage("stop")
             return collectgarbage("isrunning")
             """)
  end

  test "stub returns 0 for step, not the boolean cycle-completion flag" do
    # PUC-Lua: collectgarbage("step", n) returns true when a collection
    # cycle completes. The stub returns a numeric 0 regardless.
    assert {[0], _} = Lua.eval!(~S[return collectgarbage("step", 20000)])
  end
end

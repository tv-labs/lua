defmodule Lua.VM.RequireOpenUpvalueTest do
  use ExUnit.Case, async: true

  # Pins the invariant that `require` does not leak the inner module's
  # `state.open_upvalues` entries back to the outer caller.
  #
  # The inner module's closures populate `open_upvalues` keyed by the
  # inner's register index. Without a save/restore around the nested
  # execution, the outer caller inherits those entries and any later
  # closure in the outer that captures a local at the *same register
  # index* would reuse the inner's stale cell — silently aliasing the
  # outer's local to whatever the inner had at that register.

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "lua_require_upvalue_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    %{tmp_dir: tmp_dir}
  end

  defp eval_with_path(code, tmp_dir) do
    lua = Lua.new(sandbox: false)
    lua = Lua.set_lua_paths(lua, [Path.join(tmp_dir, "?.lua")])
    Lua.eval!(lua, code)
  end

  test "outer module's local is not aliased to inner module's upvalue cell", %{tmp_dir: tmp_dir} do
    # Inner module: top-level local at reg 0 with a string value, captured
    # by a closure (which populates open_upvalues[0] in the inner's
    # execution).
    File.write!(Path.join(tmp_dir, "inner.lua"), """
    local inner_local = "inner_value"

    local function captures_it()
      return inner_local
    end

    return { tag = "inner", fn = captures_it }
    """)

    # Outer chunk: requires inner (so the inner's body runs and leaves
    # open_upvalues entries on the state), then defines a closure
    # capturing its own top-level local at reg 0. With the bug, the
    # outer closure would reuse the inner's stale cell holding the
    # string "inner_value"; the assertion below would then read
    # "inner_value" instead of the module table's tag.
    code = ~S"""
    local m = require("inner")

    local function captures_m()
      return m
    end

    return m.tag, captures_m().tag
    """

    assert {["inner", "inner"], _} = eval_with_path(code, tmp_dir)
  end

  test "outer local survives many local function definitions after require", %{tmp_dir: tmp_dir} do
    # Mirrors the luassert.assertions shape: a module declares
    # `local assert = require('inner')`, then defines many local
    # functions that close over `assert`, then calls a method on
    # `assert`. The first method call must see the actual obj table,
    # not a stale upvalue from the inner module.
    File.write!(Path.join(tmp_dir, "inner.lua"), """
    local s = "inner_s"

    local function uses_s()
      return s
    end

    local obj = { register = function(self, name) return "registered:" .. name end }
    return obj
    """)

    code = ~S"""
    local assert_obj = require("inner")

    local function noop_1() return assert_obj end
    local function noop_2() return assert_obj end
    local function noop_3() return assert_obj end
    local function noop_4() return assert_obj end
    local function noop_5() return assert_obj end

    return assert_obj:register("ok")
    """

    assert {["registered:ok"], _} = eval_with_path(code, tmp_dir)
  end
end

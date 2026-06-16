defmodule Lua.Integration.LuassertTest do
  use ExUnit.Case, async: true

  # End-to-end regression coverage for the require pipeline against a
  # real-world Lua library. luassert + say exercises:
  #
  #   * Multi-level require chains (luassert → luassert.assertions →
  #     luassert.assert → say).
  #   * Modules with 50+ top-level local-function definitions that close
  #     over top-level locals — the exact shape that surfaced the
  #     open_upvalues leak in issue #244.
  #   * Modules that return tables vs. modules that only register and
  #     return nothing (cached as the `true` sentinel).
  #   * `setmetatable` on returned values, `__call` and `__index`
  #     metamethods.
  #
  # The vendored source under `test/integration/luassert/lua/` is pinned
  # to luassert v1.9.0 and say v1.4.1. See the README in that directory
  # for licensing and update instructions.

  @lua_dir Path.expand("luassert/lua", __DIR__)

  defp new_lua do
    [sandbox: false]
    |> Lua.new()
    |> Lua.set_lua_paths([
      Path.join(@lua_dir, "?.lua"),
      Path.join(@lua_dir, "?/init.lua")
    ])
  end

  # Modules that load cleanly under the sandboxed VM. The omitted ones
  # (`luassert.formatters`, top-level `luassert`) depend on
  # `io.type(io.stdout)` for TTY detection at module-load time, which
  # this VM intentionally does not expose; that gap is orthogonal to
  # issue #244 and tracked separately.
  @loadable_modules ~w[
    luassert.assert
    luassert.assertions
    luassert.modifiers
    luassert.array
    luassert.spy
    luassert.stub
    luassert.mock
    luassert.match
    luassert.state
    luassert.util
    luassert.namespaces
    luassert.compatibility
    luassert.matchers
    luassert.languages.en
    say
  ]

  describe "individual luassert modules load via require" do
    for modname <- @loadable_modules do
      test "require('#{modname}') returns a value without raising" do
        # `assertions`/`modifiers`/`array`/etc. don't `return` anything,
        # so they cache as the `true` sentinel. Modules that return a
        # table cache as the table. Both shapes are valid Lua.
        code = "local m = require('#{unquote(modname)}'); return type(m)"
        {[type_str], _lua} = Lua.eval!(new_lua(), code)
        assert type_str in ["table", "boolean"]
      end
    end
  end

  describe "luassert.assert API survives the require pipeline" do
    test "obj table exposes register/snapshot/level/format functions" do
      # The smoke test for issue #244: load `luassert.assert` and
      # confirm the obj table's documented fields survived the require
      # pipeline. Without the fix, the local `assert` would alias to a
      # leaked inner upvalue cell and lose its fields.
      code = ~S"""
      local assert = require('luassert.assert')
      return type(assert), type(assert.register), type(assert.snapshot),
             type(assert.level), type(assert.format)
      """

      {types, _lua} = Lua.eval!(new_lua(), code)
      assert types == ["table", "function", "function", "function", "function"]
    end

    test "assertions module registers without raising" do
      # The exact failure path from issue #244:
      # `local assert = require('luassert.assert')` at the top of
      # `luassert/assertions.lua`, followed by many `local function`
      # defs, followed by `assert:register('modifier', 'message', …)`
      # at line 307. Loading `luassert.assertions` succeeds iff every
      # one of those `assert:register(...)` calls finds the obj table
      # at the captured upvalue.
      code = ~S"""
      require('luassert.assertions')
      return 'ok'
      """

      assert {["ok"], _lua} = Lua.eval!(new_lua(), code)
    end

    test "array and spy modules (other failure sites from issue #244)" do
      # `luassert.array:66` and `luassert.spy:182` both have the same
      # shape as assertions.lua and were the other reproducers in the
      # bug report.
      code = ~S"""
      require('luassert.array')
      require('luassert.spy')
      return 'ok'
      """

      assert {["ok"], _lua} = Lua.eval!(new_lua(), code)
    end
  end
end

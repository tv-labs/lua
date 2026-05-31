defmodule Lua.VM.ShortCircuitTest do
  use ExUnit.Case, async: true

  # Pins Lua 5.3 §3.4.5 short-circuit semantics for `and`/`or` under deep
  # left-associative composition — `((((a op b) op c) op d) op e)` and the
  # `not(...)` wrapping of each such expression.
  #
  # `and` returns its first operand if that operand is falsy, otherwise its
  # second; `or` returns its first operand if truthy, otherwise its second.
  # Only `nil` and `false` are falsy. The executor compiles these to
  # `test_and` / `test_or` conditional-jump bytecode. The suspected hazards
  # were register aliasing across the conditional branch and a `not`
  # precedence wrinkle when the depth-4 chains nest; the cases below confirm
  # both are handled correctly.

  defp eval!(code) do
    {results, _state} = Lua.eval!(Lua.new(sandboxed: []), code)
    results
  end

  describe "explicit depth-4 left-associative compositions" do
    # Each tuple: {expression, expected_value}. Expected values are the Lua
    # 5.3 results, computed by hand from the short-circuit rules above.
    cases = [
      {"(((10 and 20) and 30) and 40) and 50", 50},
      {"(((nil and 20) and 30) and 40) and 50", nil},
      {"(((false or nil) or false) or 10) or 20", 10},
      {"(((nil or false) or nil) or false) or 99", 99},
      {"(((10 and nil) or 20) and 30) or 40", 30},
      {"(((false and 1) or (nil and 2)) or 3) and 4", 4},
      {"(((10 or error()) and 20) or error()) and 30", 30},
      {"(((nil and error()) or 5) and 6) or error()", 6},
      {"(((true and false) or true) and false) or true", true},
      {"(((1 and 2) and 3) and 4) or 5", 4}
    ]

    for {expr, expected} <- cases do
      test "#{expr} == #{inspect(expected)}" do
        assert [unquote(Macro.escape(expected))] = eval!("return #{unquote(expr)}")
      end
    end
  end

  describe "not(...) wrapping a depth-4 chain" do
    test "not flips the truthiness of the composed result" do
      assert [true] = eval!("return not((((nil and 2) and 3) and 4) and 5)")
      assert [false] = eval!("return not((((10 or 2) or 3) or 4) or 5)")
      assert [false] = eval!("return not((((false or nil) or 0) or 4) or 5)")
    end
  end

  describe "if-condition side effect matches the expression value" do
    # Mirrors the constructs.lua harness shape: a deep `and`/`or` expression
    # is used both as an `if` condition (a side-effecting branch) and as the
    # returned value; the branch must fire iff the value is truthy.
    test "branch fires exactly when the composed value is truthy" do
      [taken?, value] =
        eval!("""
        local taken = false
        local expr = (((10 and nil) or 20) and 30) or 40
        if expr then taken = true end
        return taken, expr
        """)

      assert value == 30
      assert taken? == true
    end

    test "branch is skipped when the composed value is falsy" do
      [taken?, value] =
        eval!("""
        local taken = false
        local expr = (((10 and nil) and 20) and 30) and 40
        if expr then taken = true end
        return taken, expr
        """)

      assert value == nil
      assert taken? == false
    end
  end

  describe "generative harness (constructs.lua)" do
    # Faithful in-process replica of the constructs.lua short-circuit
    # harness, built from the same `createcases` generator. Each level builds
    # every nested `op` composition (and its `not` wrapping) over the five
    # basic cases, then asserts both the returned value and the `IX` branch
    # side effect against a precomputed truth table. Level 3 (4105 cases)
    # pins the generative property in the default suite. Level 4 (204105
    # cases) is the exact surface the suite default exercises but is too slow
    # for every run; it is tagged `:slow` and excluded by default.
    defp harness(level) do
      ~s"""
      _ENV.GLOB1 = 1
      local basiccases = {
        {"nil", nil},
        {"false", false},
        {"true", true},
        {"10", 10},
        {"(0==_ENV.GLOB1)", 0 == _ENV.GLOB1},
      }
      local binops = {
        {" and ", function (a,b) if not a then return a else return b end end},
        {" or ", function (a,b) if a then return a else return b end end},
      }
      local cases = {}
      local function createcases (n)
        local res = {}
        for i = 1, n - 1 do
          for _, v1 in ipairs(cases[i]) do
            for _, v2 in ipairs(cases[n - i]) do
              for _, op in ipairs(binops) do
                  local t = {
                    "(" .. v1[1] .. op[1] .. v2[1] .. ")",
                    op[2](v1[2], v2[2])
                  }
                  res[#res + 1] = t
                  res[#res + 1] = {"not" .. t[1], not t[2]}
              end
            end
          end
        end
        return res
      end
      local level = #{level}
      cases[1] = basiccases
      for i = 2, level do cases[i] = createcases(i) end
      local prog = [[if %s then IX = true end; return %s]]
      local count = 0
      for n = 1, level do
        for _, v in pairs(cases[n]) do
          local s = v[1]
          local p = load(string.format(prog, s, s), "")
          IX = false
          local r = p()
          assert(r == v[2] and IX == not not v[2], s)
          count = count + 1
        end
      end
      return count
      """
    end

    test "every level-3 composition matches its value and branch side effect" do
      assert [4105] = eval!(harness(3))
    end

    @tag :slow
    @tag timeout: :infinity
    test "every level-4 composition matches its value and branch side effect" do
      assert [204_105] = eval!(harness(4))
    end
  end
end

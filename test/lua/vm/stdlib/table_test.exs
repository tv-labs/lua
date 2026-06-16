defmodule Lua.VM.Stdlib.TableTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Lua.Compiler
  alias Lua.Parser
  alias Lua.VM
  alias Lua.VM.State
  alias Lua.VM.Stdlib

  # Compile and run `code` with the stdlib installed, returning the
  # multi-value tuple Lua produced. Keeps the example tests below readable
  # by hiding the Parser/Compiler/State boilerplate.
  defp run!(code) do
    {:ok, ast} = Parser.parse(code)
    {:ok, proto} = Compiler.compile(ast, source: "test.lua")
    {:ok, results, _state} = VM.execute(proto, Stdlib.install(State.new()))
    results
  end

  describe "table library" do
    test "table.insert appends to end" do
      code = """
      local t = {1, 2, 3}
      table.insert(t, 4)
      return t[1], t[2], t[3], t[4]
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert {:ok, [1, 2, 3, 4], _state} = VM.execute(proto, state)
    end

    test "table.insert at position" do
      code = """
      local t = {1, 2, 4}
      table.insert(t, 3, 3)
      return t[1], t[2], t[3], t[4]
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert {:ok, [1, 2, 3, 4], _state} = VM.execute(proto, state)
    end

    test "table.remove from end" do
      # Note: Avoiding local variable to work around VM bug
      code = """
      local t = {1, 2, 3, 4}
      table.remove(t)
      return t[1], t[2], t[3], t[4]
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert {:ok, [1, 2, 3, nil], _state} = VM.execute(proto, state)
    end

    test "table.remove from position" do
      code = """
      local t = {1, 2, 3, 4}
      table.remove(t, 2)
      return t[1], t[2], t[3], t[4]
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert {:ok, [1, 3, 4, nil], _state} = VM.execute(proto, state)
    end

    test "table.concat joins elements" do
      code = """
      local t = {1, 2, 3, 4}
      return table.concat(t, ", ")
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert {:ok, ["1, 2, 3, 4"], _state} = VM.execute(proto, state)
    end

    test "table.concat with range" do
      code = """
      local t = {1, 2, 3, 4, 5}
      return table.concat(t, "-", 2, 4)
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert {:ok, ["2-3-4"], _state} = VM.execute(proto, state)
    end

    test "table.pack creates table with n" do
      code = """
      local t = table.pack(1, 2, 3)
      return t[1], t[2], t[3], t.n
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert {:ok, [1, 2, 3, 3], _state} = VM.execute(proto, state)
    end

    test "table.unpack returns elements" do
      code = """
      local t = {10, 20, 30, 40}
      return table.unpack(t)
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert {:ok, [10, 20, 30, 40], _state} = VM.execute(proto, state)
    end

    test "table.unpack with range" do
      code = """
      local t = {10, 20, 30, 40, 50}
      return table.unpack(t, 2, 4)
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert {:ok, [20, 30, 40], _state} = VM.execute(proto, state)
    end

    test "table.unpack rejects oversized result ranges before materialising" do
      # Lua 5.3 sort.lua line 48: `checkerror("too many results", unpack,
      # {}, 0, maxi)`. A huge `j` must raise up front rather than try to
      # materialise the slice (which would hang the VM). On the BEAM we
      # share the `concat`/`move` element ceiling, so even a sub-INT_MAX
      # range (which PUC would accept) is rejected before allocating.
      for code <- [
            "return table.unpack({}, 0, math.maxinteger)",
            "return table.unpack({}, 1, math.maxinteger)",
            "return table.unpack({}, math.mininteger, math.maxinteger)",
            "return table.unpack({}, 0, (1 << 31) - 1)",
            "return table.unpack({}, 1, (1 << 31) - 1)",
            # A sub-INT_MAX count that PUC accepts but would still allocate
            # hundreds of millions of nils on the BEAM and OOM the host.
            "return table.unpack({}, 1, 500000000)"
          ] do
        assert_raise Lua.RuntimeException, ~r/too many results/, fn ->
          Lua.eval!(Lua.new(), code)
        end
      end
    end

    test "table.unpack with a normal range is unaffected by the size guard" do
      assert {[20, 30, 40], _} =
               Lua.eval!(Lua.new(), "return table.unpack({10, 20, 30, 40, 50}, 2, 4)")
    end

    test "table.unpack with a reversed huge range is an empty result, not an error" do
      # `i > j` short-circuits to an empty range before the size guard.
      assert {[], _} =
               Lua.eval!(Lua.new(), "return table.unpack({}, math.maxinteger, 0)")
    end

    test "table.sort sorts in place" do
      code = """
      local t = {3, 1, 4, 1, 5, 9, 2, 6}
      table.sort(t)
      return t[1], t[2], t[3], t[4]
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert {:ok, [1, 1, 2, 3], _state} = VM.execute(proto, state)
    end

    test "table.sort preserves non-array keys" do
      code = """
      local t = {30, 10, 20}
      t.name = "hi"
      t[100] = "sparse"
      table.sort(t)
      return t[1], t[2], t[3], t.name, t[100]
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert {:ok, [10, 20, 30, "hi", "sparse"], _state} = VM.execute(proto, state)
    end

    # ltablib.c sort rejects a length reaching INT_MAX with "array too
    # big" before touching the table, so a `__len` returning a huge value
    # raises promptly instead of trying to read billions of slots.
    test "table.sort rejects an INT_MAX-length array with 'array too big'" do
      code = """
      local a = setmetatable({}, {__len = function () return math.maxinteger end})
      table.sort(a)
      """

      assert_raise Lua.RuntimeException, ~r/array too big/, fn ->
        Lua.eval!(Lua.new(), code)
      end
    end

    # A negative __len leaves nothing to sort: the comparator is never
    # invoked (here `error` would raise if it were).
    test "table.sort with a negative __len compares nothing" do
      assert run!("""
             local a = setmetatable({}, {__len = function () return -1 end})
             table.sort(a, error)
             return #a
             """) == [-1]
    end

    test "table.move copies elements" do
      code = """
      local t1 = {1, 2, 3, 4, 5}
      local t2 = {10, 20, 30}
      table.move(t1, 2, 4, 1, t2)
      return t2[1], t2[2], t2[3]
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert {:ok, [2, 3, 4], _state} = VM.execute(proto, state)
    end

    test "table.move within same table" do
      code = """
      local t = {1, 2, 3, 4, 5}
      table.move(t, 1, 3, 3)
      return t[1], t[2], t[3], t[4], t[5]
      """

      assert {:ok, ast} = Parser.parse(code)
      assert {:ok, proto} = Compiler.compile(ast, source: "test.lua")
      state = Stdlib.install(State.new())

      assert {:ok, [1, 2, 1, 2, 3], _state} = VM.execute(proto, state)
    end
  end

  describe "table.move argument validation (Lua 5.3 §6.6, sort.lua)" do
    # ltablib.c tmove checks the indices (args 2-4) before the source
    # table (arg 1), so a non-table first arg with valid integer indices
    # is blamed on arg #1, not arg #4.
    test "non-table source with valid indices blames arg #1" do
      assert_raise Lua.RuntimeException, ~r/#1.*table expected, got number/, fn ->
        Lua.eval!(Lua.new(), "table.move(1, 2, 3, 4)")
      end
    end

    # luaL_checkinteger blames the absent argument by position with "got no
    # value", not the last present argument. `table.move(t, 1, 3)` omits the
    # destination (arg #4); `table.move(t, 1)` omits the final index (arg #3).
    test "missing destination blames arg #4 with 'no value'" do
      assert_raise Lua.RuntimeException,
                   ~r/#4 to 'table.move' \(number expected, got no value\)/,
                   fn -> Lua.eval!(Lua.new(), "table.move({1,2,3}, 1, 3)") end
    end

    test "missing final index blames arg #3 with 'no value'" do
      assert_raise Lua.RuntimeException,
                   ~r/#3 to 'table.move' \(number expected, got no value\)/,
                   fn -> Lua.eval!(Lua.new(), "table.move({1,2,3}, 1)") end
    end

    test "overflowing element count raises 'too many'" do
      assert_raise Lua.RuntimeException, ~r/too many elements to move/, fn ->
        Lua.eval!(Lua.new(), "table.move({}, math.mininteger, math.maxinteger, 1)")
      end
    end

    test "overflowing destination raises 'wrap around'" do
      assert_raise Lua.RuntimeException, ~r/destination wrap around/, fn ->
        Lua.eval!(Lua.new(), "table.move({}, 1, math.maxinteger, 2)")
      end
    end

    # A move over a huge range interleaves read/write per element, so a
    # __newindex error aborts after the first slot rather than first
    # materialising the whole (impossibly large) slice.
    test "metamethod error interrupts a maxinteger-wide move after the first slot" do
      code = """
      local pos1, pos2
      local a = setmetatable({}, {
        __index = function (_, k) pos1 = k end,
        __newindex = function (_, k) pos2 = k; error() end,
      })
      local st = pcall(table.move, a, 1, math.maxinteger, 0)
      return st, pos1, pos2
      """

      assert run!(code) == [false, 1, 0]
    end

    # Overlapping in-place moves stay coherent: PUC copies backward when
    # the destination would otherwise clobber an unread source slot.
    test "overlapping forward move with t inside the source range stays coherent" do
      code = """
      local t = {10, 20, 30}
      table.move(t, 1, 3, 3)
      return t[1], t[2], t[3], t[4], t[5]
      """

      assert run!(code) == [10, 20, 10, 20, 30]
    end
  end

  describe "table constructor backfill" do
    test "constructor entries iterate in insertion order via pairs" do
      # The constructor backfill writes consecutive integer keys in one
      # batch; `pairs` must still walk them in ascending insertion order.
      code = """
      local t = {10, 20, 30, 40, 50}
      local keys, vals = {}, {}
      for k, v in pairs(t) do
        keys[#keys + 1] = k
        vals[#vals + 1] = v
      end
      return table.concat(keys, ","), table.concat(vals, ",")
      """

      assert ["1,2,3,4,5", "10,20,30,40,50"] = run!(code)
    end

    test "ipairs over a constructor stops at the first hole" do
      code = """
      local t = {1, 2, 3}
      local out = {}
      for i, v in ipairs(t) do
        out[#out + 1] = v
      end
      return #out, out[1], out[2], out[3]
      """

      assert [3, 1, 2, 3] = run!(code)
    end

    test "clearing a dense integer key to nil and re-adding keeps its array slot" do
      # Backfill five dense integer keys, clear one in the middle, then
      # re-add it. Dense positive integers live in the array, so clearing a
      # slot leaves a hole and re-adding fills the same slot — iteration
      # stays in index order. This matches reference Lua 5.3, where these
      # keys all live in the array part and a revived key keeps its index.
      code = """
      local t = {1, 2, 3, 4, 5}
      t[3] = nil
      t[3] = 30
      local keys = {}
      for k in pairs(t) do
        keys[#keys + 1] = k
      end
      return table.concat(keys, ",")
      """

      assert ["1,2,3,4,5"] = run!(code)
    end

    test "an overwritten constructor slot keeps its original position" do
      code = """
      local t = {1, 2, 3}
      t[2] = 99
      local keys, vals = {}, {}
      for k, v in pairs(t) do
        keys[#keys + 1] = k
        vals[#vals + 1] = v
      end
      return table.concat(keys, ","), table.concat(vals, ",")
      """

      assert ["1,2,3", "1,99,3"] = run!(code)
    end

    test "empty constructor leaves no entries" do
      assert [0] = run!("local t = {}\nlocal n = 0\nfor _ in pairs(t) do n = n + 1 end\nreturn n")
    end
  end

  describe "table.insert edge cases" do
    test "insert at position 1 shifts every existing element up" do
      code = """
      local t = {2, 3, 4}
      table.insert(t, 1, 1)
      return #t, t[1], t[2], t[3], t[4]
      """

      assert run!(code) == [4, 1, 2, 3, 4]
    end

    test "insert at #t + 1 appends without shifting" do
      code = """
      local t = {1, 2, 3}
      table.insert(t, 4, 4)
      return #t, t[1], t[2], t[3], t[4]
      """

      assert run!(code) == [4, 1, 2, 3, 4]
    end

    test "insert at position 1 of an empty table" do
      assert run!("local t = {}; table.insert(t, 1, 'x'); return #t, t[1]") == [1, "x"]
    end

    test "insert at position 1 of a single-element table" do
      code = """
      local t = {2}
      table.insert(t, 1, 1)
      return #t, t[1], t[2]
      """

      assert run!(code) == [2, 1, 2]
    end

    test "insert preserves non-sequence keys across a shift" do
      # Hash-part keys (-7, "label") must survive an integer-key shift.
      code = """
      local t = {2, 3, [-7] = 'ban', label = 'tag'}
      table.insert(t, 1, 1)
      return t[1], t[2], t[3], t[-7], t.label
      """

      assert run!(code) == [1, 2, 3, "ban", "tag"]
    end

    test "insert with pos < 1 raises position out of bounds" do
      assert_raise Lua.RuntimeException, ~r/position out of bounds/, fn ->
        Lua.eval!(Lua.new(), "table.insert({1, 2, 3}, 0, 99)")
      end
    end

    test "insert with pos > #t + 1 raises position out of bounds" do
      assert_raise Lua.RuntimeException, ~r/position out of bounds/, fn ->
        Lua.eval!(Lua.new(), "table.insert({1, 2, 3}, 5, 99)")
      end
    end
  end

  describe "table.remove edge cases" do
    test "remove from position 1 shifts every later element down" do
      code = """
      local t = {1, 2, 3, 4}
      local v = table.remove(t, 1)
      return v, #t, t[1], t[2], t[3], t[4]
      """

      assert run!(code) == [1, 3, 2, 3, 4, nil]
    end

    test "remove from #t doesn't shift" do
      code = """
      local t = {10, 20, 30}
      local v = table.remove(t, 3)
      return v, #t, t[1], t[2], t[3]
      """

      assert run!(code) == [30, 2, 10, 20, nil]
    end

    test "remove with pos == #t + 1 returns nil and leaves table intact" do
      # Mirrors nextvar.lua line 381: `assert(table.remove(a, #a + 1) == nil)`.
      code = """
      local t = {10, 20, 30}
      local v = table.remove(t, 4)
      return v, #t, t[1], t[2], t[3]
      """

      assert run!(code) == [nil, 3, 10, 20, 30]
    end

    test "remove with pos == 0 on empty table returns t[0] (Lua 5.3 ltablib special case)" do
      # Mirrors nextvar.lua line 362.
      assert run!("local t = {[0] = 'ban'}; return table.remove(t), t[0]") == ["ban", nil]
    end

    test "remove with pos == 0 on non-empty table raises" do
      # Mirrors nextvar.lua line 382: `assert(not pcall(table.remove, a, 0))`.
      assert_raise Lua.RuntimeException, ~r/position out of bounds/, fn ->
        Lua.eval!(Lua.new(), "table.remove({1, 2, 3}, 0)")
      end
    end

    test "remove with pos < 0 raises" do
      assert_raise Lua.RuntimeException, ~r/position out of bounds/, fn ->
        Lua.eval!(Lua.new(), "table.remove({1, 2, 3}, -1)")
      end
    end

    test "remove single-element list empties the table" do
      assert run!("local t = {42}; local v = table.remove(t, 1); return v, #t, t[1]") == [42, 0, nil]
    end

    test "remove from empty table returns nil without raising" do
      # Single-arg call: pos defaults to #t == 0, which is the Lua 5.3
      # special case. With no t[0] either, the return is nil.
      assert run!("local t = {}; return table.remove(t), #t") == [nil, 0]
    end

    test "remove preserves non-sequence keys across a shift" do
      code = """
      local t = {1, 2, 3, [-7] = 'ban', label = 'tag'}
      table.remove(t, 1)
      return t[1], t[2], t[3], t[-7], t.label
      """

      assert run!(code) == [2, 3, nil, "ban", "tag"]
    end
  end

  describe "metamethod dispatch" do
    # `table.insert`, `table.remove`, `table.concat`, `table.move`, and
    # `table.sort` route reads through `__index`, writes through
    # `__newindex`, and length lookups through `__len`. The tests below
    # use a "proxy" pattern (an empty table with metamethods that delegate
    # to a backing store) to confirm the stdlib never reaches into the
    # raw table when a metamethod is set.

    test "table.insert calls __newindex on missing slot" do
      code = """
      local backing = {1, 2, 3}
      local proxy = setmetatable({}, {
        __index = backing,
        __newindex = backing,
        __len = function() return #backing end,
      })
      table.insert(proxy, 4)
      return #backing, backing[4], rawlen(proxy)
      """

      # `rawlen` skips __len so we can assert the proxy itself is still
      # empty — the value lives on the backing table.
      assert run!(code) == [4, 4, 0]
    end

    test "table.insert at position writes via __newindex" do
      code = """
      local writes = {}
      local backing = {1, 2, 4}
      local proxy = setmetatable({}, {
        __index = backing,
        __newindex = function(_, k, v)
          writes[#writes + 1] = k
          backing[k] = v
        end,
        __len = function() return #backing end,
      })
      table.insert(proxy, 3, 3)
      return backing[1], backing[2], backing[3], backing[4], writes[1], writes[2]
      """

      # The shift writes to slot 4 first (top-down), then the new value
      # lands at slot 3.
      assert run!(code) == [1, 2, 3, 4, 4, 3]
    end

    test "table.remove reads via __index and writes nil via __newindex" do
      code = """
      local backing = {10, 20, 30}
      local clears = {}
      local proxy = setmetatable({}, {
        __index = backing,
        __newindex = function(_, k, v)
          if v == nil then clears[#clears + 1] = k end
          backing[k] = v
        end,
        __len = function() return #backing end,
      })
      local v = table.remove(proxy)
      return v, #backing, backing[3], clears[1]
      """

      assert run!(code) == [30, 2, nil, 3]
    end

    test "table.remove from middle shifts via metamethods" do
      code = """
      local backing = {10, 20, 30, 40}
      local proxy = setmetatable({}, {
        __index = backing,
        __newindex = backing,
        __len = function() return #backing end,
      })
      local v = table.remove(proxy, 2)
      return v, backing[1], backing[2], backing[3], backing[4]
      """

      assert run!(code) == [20, 10, 30, 40, nil]
    end

    test "table.concat reads via __index and uses __len for upper bound" do
      code = """
      local backing = {"a", "b", "c"}
      local reads = 0
      local proxy = setmetatable({}, {
        __index = function(_, k)
          reads = reads + 1
          return backing[k]
        end,
        __newindex = backing,
        __len = function() return #backing end,
      })
      local result = table.concat(proxy, ",")
      return result, reads
      """

      # 3 reads via __index — one per element. __len is used to determine
      # the default upper bound `j`.
      assert run!(code) == ["a,b,c", 3]
    end

    test "table.concat with explicit range still routes through __index" do
      code = """
      local backing = {"a", "b", "c", "d"}
      local proxy = setmetatable({}, {
        __index = backing,
        __newindex = backing,
      })
      return table.concat(proxy, "-", 2, 3)
      """

      assert run!(code) == ["b-c"]
    end

    test "table.move reads src via __index and writes dst via __newindex" do
      code = """
      local src_backing = {1, 2, 3, 4, 5}
      local dst_writes = {}
      local src = setmetatable({}, {
        __index = src_backing,
        __newindex = src_backing,
        __len = function() return #src_backing end,
      })
      local dst = setmetatable({}, {
        __index = function(_, k) return dst_writes[k] end,
        __newindex = function(_, k, v) dst_writes[k] = v end,
        __len = function()
          local n = 0
          for k in pairs(dst_writes) do
            if type(k) == "number" and k > n then n = k end
          end
          return n
        end,
      })
      table.move(src, 2, 4, 1, dst)
      return dst_writes[1], dst_writes[2], dst_writes[3], dst_writes[4]
      """

      assert run!(code) == [2, 3, 4, nil]
    end

    test "table.sort reads and writes via metamethods" do
      code = """
      local backing = {3, 1, 4, 1, 5}
      local read_count = 0
      local write_count = 0
      local proxy = setmetatable({}, {
        __index = function(_, k)
          read_count = read_count + 1
          return backing[k]
        end,
        __newindex = function(_, k, v)
          write_count = write_count + 1
          backing[k] = v
        end,
        __len = function() return #backing end,
      })
      table.sort(proxy)
      return backing[1], backing[2], backing[3], backing[4], backing[5],
             read_count > 0, write_count == 5
      """

      assert run!(code) == [1, 1, 3, 4, 5, true, true]
    end

    test "table.sort with custom comparator routes through metamethods" do
      code = """
      local backing = {1, 2, 3, 4, 5}
      local proxy = setmetatable({}, {
        __index = backing,
        __newindex = backing,
        __len = function() return #backing end,
      })
      table.sort(proxy, function(a, b) return a > b end)
      return backing[1], backing[2], backing[3], backing[4], backing[5]
      """

      assert run!(code) == [5, 4, 3, 2, 1]
    end

    test "table.sort comparator drives a __lt metamethod on the elements" do
      # The default (no-comparator) sort compares only numbers and
      # strings, so element ordering through a __lt metamethod is only
      # reachable when the comparator itself uses `<` on the elements.
      # This pins that the comparator's `<` dispatches __lt and the
      # elements end up ordered by their `val` field.
      code = """
      local tt = {__lt = function(a, b) return a.val < b.val end}
      local t = {}
      for i = 1, 5 do
        t[i] = setmetatable({val = 6 - i}, tt)
      end
      table.sort(t, function(a, b) return a < b end)
      return t[1].val, t[2].val, t[3].val, t[4].val, t[5].val
      """

      assert run!(code) == [1, 2, 3, 4, 5]
    end

    test "__index as a function metamethod is invoked for table.concat" do
      # When __index is a function (not a table), the stdlib must call
      # it with (proxy, key) and use the returned value.
      code = """
      local proxy = setmetatable({}, {
        __index = function(_, k) return tostring(k * 10) end,
        __len = function() return 3 end,
      })
      return table.concat(proxy, ",")
      """

      assert run!(code) == ["10,20,30"]
    end

    test "__newindex as a function metamethod is invoked for table.insert" do
      code = """
      local store = {}
      local proxy = setmetatable({}, {
        __index = store,
        __newindex = function(_, k, v) store[k] = v * 2 end,
        __len = function()
          local n = 0
          for k in pairs(store) do
            if type(k) == "number" and k > n then n = k end
          end
          return n
        end,
      })
      table.insert(proxy, 5)
      table.insert(proxy, 7)
      return store[1], store[2]
      """

      # __newindex doubles every value on its way in.
      assert run!(code) == [10, 14]
    end

    test "table.insert into raw table without metamethods is unchanged" do
      # Ensure the metamethod path doesn't regress the raw-table case.
      assert run!("local t = {1, 2}; table.insert(t, 3); return t[1], t[2], t[3]") ==
               [1, 2, 3]
    end

    test "table.unpack reads via __index and uses __len" do
      # Picked up alongside the other `table.*` fixes — `nextvar.lua`'s
      # proxy section calls `table.unpack(proxy)` and expects metamethod
      # dispatch the same way ltablib.c uses `lua_geti`.
      code = """
      local backing = {10, 20, 30}
      local proxy = setmetatable({}, {
        __index = backing,
        __len = function() return #backing end,
      })
      return table.unpack(proxy)
      """

      assert run!(code) == [10, 20, 30]
    end

    test "table.concat raises when __len returns a non-integer" do
      # Matches Lua 5.3: aux_getn coerces the __len result via
      # luaL_checkinteger, raising on bad return values.
      assert_raise Lua.RuntimeException, ~r/length is not an integer/, fn ->
        Lua.eval!(Lua.new(), """
        local proxy = setmetatable({}, {
          __index = function() return "x" end,
          __len = function() return "abc" end,
        })
        return table.concat(proxy)
        """)
      end
    end

    test "__len returning a float that is whole-valued is accepted" do
      # luaL_len/lua_tointegerx accepts integer-valued floats. The
      # canonical way an Elixir __len ends up returning a float is
      # `math.huge - math.huge` etc., but a plain `return 3.0` is the
      # tightest pin.
      code = """
      local proxy = setmetatable({}, {
        __index = function(_, k) return k end,
        __len = function() return 3.0 end,
      })
      return table.concat(proxy, ",")
      """

      assert run!(code) == ["1,2,3"]
    end

    test "__len returning a non-whole float raises" do
      # 3.5 has no integer representation — luaL_len would raise.
      assert_raise Lua.RuntimeException, ~r/length is not an integer/, fn ->
        Lua.eval!(Lua.new(), """
        local proxy = setmetatable({}, {
          __index = function() return "x" end,
          __len = function() return 3.5 end,
        })
        return table.concat(proxy)
        """)
      end
    end

    test "__newindex does NOT fire when the slot exists on the proxy itself" do
      # Per Lua 5.3 §2.4: __newindex fires only when the key is absent
      # from the table. If proxy has its own t[k], assignment goes raw.
      # This is exercised by `table.insert(proxy, 1, v)` when the proxy
      # has its own slot inside the shift range — the shift write to
      # that slot must NOT call __newindex.
      code = """
      local backing = {10, 20, 30}
      local newindex_calls = {}
      local proxy = setmetatable({[2] = "own"}, {
        __index = backing,
        __newindex = function(t, k, v)
          newindex_calls[#newindex_calls + 1] = k
          backing[k] = v
        end,
        __len = function() return #backing end,
      })

      table.insert(proxy, 1, "X")

      -- Shifts: 3->4 (no raw [4], fires __newindex),
      --         2->3 (no raw [3], fires __newindex),
      --         1->2 (raw [2] exists, raw write, does NOT fire),
      --         insert at 1 (no raw [1], fires __newindex).
      -- Expected __newindex call keys: {4, 3, 1}
      return rawget(proxy, 2), backing[1], backing[3],
             newindex_calls[1], newindex_calls[2], newindex_calls[3], newindex_calls[4]
      """

      # rawget(proxy, 2) is the value 10 (raw-written during shift 1->2).
      # backing[1] is "X" (newindex fired). backing[3] is "own" (newindex
      # fired, value read from raw proxy[2]). The 4th call slot is nil
      # because only 3 calls happened.
      assert run!(code) == [10, "X", "own", 4, 3, 1, nil]
    end

    test "__index does NOT fire when the slot exists on the proxy itself" do
      # Same spec rule: __index fires only when raw lookup misses. A
      # slot present on the proxy short-circuits the metamethod.
      code = """
      local index_calls = 0
      local proxy = setmetatable({[1] = "own", [2] = "own2"}, {
        __index = function(_, k)
          index_calls = index_calls + 1
          return "fallback"
        end,
        __len = function() return 2 end,
      })

      -- table.concat reads via __index dispatch, but raw hits skip it.
      local result = table.concat(proxy, ",")
      return result, index_calls
      """

      assert run!(code) == ["own,own2", 0]
    end

    test "table.move with f > e is a no-op that returns dst" do
      # Lua 5.3 ltablib.c: tmove with from > end copies nothing and
      # returns the destination unchanged. Make sure neither the read
      # nor the write side fires.
      code = """
      local read_count = 0
      local write_count = 0
      local src = setmetatable({}, {
        __index = function(_, _) read_count = read_count + 1; return nil end,
        __len = function() return 0 end,
      })
      local dst_data = {99}
      local dst = setmetatable({}, {
        __newindex = function(_, _, _) write_count = write_count + 1 end,
        __index = function(_, k) return dst_data[k] end,
      })
      local result = table.move(src, 5, 3, 1, dst)
      return result == dst, read_count, write_count, dst_data[1]
      """

      assert run!(code) == [true, 0, 0, 99]
    end

    test "table.concat with i > j returns empty string without reading" do
      code = """
      local read_count = 0
      local proxy = setmetatable({}, {
        __index = function(_, _) read_count = read_count + 1; return "x" end,
        __len = function() return 5 end,
      })
      local result = table.concat(proxy, ",", 4, 2)
      return result, read_count
      """

      assert run!(code) == ["", 0]
    end

    test "recursive __newindex chain through nested metatables" do
      # The plan's Risks section: "__newindex set as a *table* (not a
      # function) is recursive: writing to the proxy writes to the inner
      # table, which may itself have a metatable." Verify the chain
      # walks all the way through to the deepest layer.
      code = """
      local deep = {}
      local middle = setmetatable({}, {__newindex = deep})
      local outer = setmetatable({}, {__newindex = middle, __len = function() return 0 end})

      table.insert(outer, "passed-through")
      return rawget(outer, 1), rawget(middle, 1), rawget(deep, 1)
      """

      # Only the deepest table actually receives the value — outer and
      # middle stay empty because each layer's __newindex points to the
      # next. (Slot 1 is absent at every level so the chain walks fully.)
      assert run!(code) == [nil, nil, "passed-through"]
    end

    test "recursive __index chain through nested metatables" do
      # Symmetric to the __newindex chain test: a missing slot walks
      # down through layered __index tables until something is found.
      code = """
      local deep = {[1] = "alpha", [2] = "beta", [3] = "gamma"}
      local middle = setmetatable({}, {__index = deep})
      local outer = setmetatable({}, {
        __index = middle,
        __len = function() return 3 end,
      })

      return table.concat(outer, ",")
      """

      assert run!(code) == ["alpha,beta,gamma"]
    end

    test "table.sort with custom comparator that mutates the proxy is observed" do
      # The materialize-sort-writeback approach matches ltablib.c. Even
      # if the comparator pokes the proxy mid-sort, the materialized
      # snapshot is what gets sorted — we don't re-read. This pins
      # the behavior so a future "lazy" sort doesn't silently change it.
      code = """
      local backing = {3, 1, 4, 1, 5}
      local proxy = setmetatable({}, {
        __index = backing,
        __newindex = backing,
        __len = function() return #backing end,
      })
      local mid_sort_writes = 0
      table.sort(proxy, function(a, b)
        -- Try to corrupt the in-progress sort.
        mid_sort_writes = mid_sort_writes + 1
        return a < b
      end)
      return backing[1], backing[2], backing[3], backing[4], backing[5],
             mid_sort_writes > 0
      """

      assert run!(code) == [1, 1, 3, 4, 5, true]
    end
  end

  describe "metamethod-aware operations: proxy/raw equivalence properties" do
    # The strongest signal that the metamethod-aware stdlib hasn't
    # diverged from the raw-table stdlib is to run the same operation
    # on both and compare results. For every random sequence + position
    # the property generates, the backing-table state after operating on
    # a proxy must equal the table state after operating on a raw
    # equivalent. This catches any read/write-ordering bug — including
    # ones I'd never think to enumerate by hand.

    # Build a Lua expression that constructs a proxy delegating
    # __index/__newindex/__len to a fresh backing table. Use a string
    # interpolation helper so the property bodies stay readable.
    defp proxy_setup(elems_lua) do
      """
      local backing = {#{elems_lua}}
      local proxy = setmetatable({}, {
        __index = backing,
        __newindex = backing,
        __len = function() return #backing end,
      })
      """
    end

    property "table.insert(proxy, pos, v) leaves backing in the same shape as table.insert(raw, pos, v)" do
      check all(
              base <- list_of(integer(), max_length: 6),
              pos_offset <- integer(0..length(base)),
              value <- integer()
            ) do
        pos = pos_offset + 1
        elems_lua = Enum.map_join(base, ", ", &Integer.to_string/1)

        # Raw side
        raw_code = """
        local t = {#{elems_lua}}
        table.insert(t, #{pos}, #{value})
        local out = {}
        for i = 1, #t do out[i] = t[i] end
        return table.concat(out, "|"), #t
        """

        # Proxy side — observe `backing`, not `proxy` (proxy is empty).
        proxy_code =
          proxy_setup(elems_lua) <>
            """
            table.insert(proxy, #{pos}, #{value})
            local out = {}
            for i = 1, #backing do out[i] = backing[i] end
            return table.concat(out, "|"), #backing
            """

        assert run!(raw_code) == run!(proxy_code)
      end
    end

    property "table.remove(proxy, pos) leaves backing in the same shape as table.remove(raw, pos)" do
      check all(
              base <- list_of(integer(), min_length: 1, max_length: 6),
              pos_offset <- integer(0..(length(base) - 1))
            ) do
        pos = pos_offset + 1
        elems_lua = Enum.map_join(base, ", ", &Integer.to_string/1)

        raw_code = """
        local t = {#{elems_lua}}
        local removed = table.remove(t, #{pos})
        local out = {}
        for i = 1, #t do out[i] = t[i] end
        return removed, table.concat(out, "|"), #t
        """

        proxy_code =
          proxy_setup(elems_lua) <>
            """
            local removed = table.remove(proxy, #{pos})
            local out = {}
            for i = 1, #backing do out[i] = backing[i] end
            return removed, table.concat(out, "|"), #backing
            """

        assert run!(raw_code) == run!(proxy_code)
      end
    end

    property "table.sort(proxy) leaves backing in the same order as table.sort(raw)" do
      check all(base <- list_of(integer(-100..100), max_length: 8)) do
        elems_lua = Enum.map_join(base, ", ", &Integer.to_string/1)

        raw_code = """
        local t = {#{elems_lua}}
        table.sort(t)
        local out = {}
        for i = 1, #t do out[i] = t[i] end
        return table.concat(out, "|")
        """

        proxy_code =
          proxy_setup(elems_lua) <>
            """
            table.sort(proxy)
            local out = {}
            for i = 1, #backing do out[i] = backing[i] end
            return table.concat(out, "|")
            """

        assert run!(raw_code) == run!(proxy_code)
      end
    end

    property "table.concat(proxy) returns the same string as table.concat(raw)" do
      check all(
              base <- list_of(integer(-1000..1000), max_length: 8),
              sep <- string(:alphanumeric, max_length: 3)
            ) do
        elems_lua = Enum.map_join(base, ", ", &Integer.to_string/1)
        sep_lua = ~s|"#{sep}"|

        raw_code = """
        local t = {#{elems_lua}}
        return table.concat(t, #{sep_lua})
        """

        proxy_code =
          proxy_setup(elems_lua) <>
            """
            return table.concat(proxy, #{sep_lua})
            """

        assert run!(raw_code) == run!(proxy_code)
      end
    end

    property "insert/remove round-trip through a proxy restores the backing sequence" do
      # Symmetric to the existing raw-table round-trip property: insert
      # and then remove at the same pos through a proxy must leave the
      # backing table back at its starting sequence.
      check all(
              base <- list_of(integer(), max_length: 6),
              pos_offset <- integer(0..length(base)),
              value <- integer()
            ) do
        pos = pos_offset + 1
        elems_lua = Enum.map_join(base, ", ", &Integer.to_string/1)

        code =
          proxy_setup(elems_lua) <>
            """
            local original_len = #backing
            table.insert(proxy, #{pos}, #{value})
            local removed = table.remove(proxy, #{pos})

            local matches = #backing == original_len
            for i = 1, original_len do
              if backing[i] ~= ({#{elems_lua}})[i] then matches = false end
            end
            return removed, matches, #backing
            """

        assert run!(code) == [value, true, length(base)]
      end
    end
  end

  describe "table.insert / table.remove round-trip property" do
    # Inserting a value at position `pos` then removing at the same `pos`
    # is the identity for the sequence portion of the table: the original
    # values come back in the original order, the length is restored, and
    # the inserted value is what `table.remove` returns. Property-tests
    # the two shift loops against each other so a regression in either
    # direction surfaces here.

    property "insert(t, pos, v) followed by remove(t, pos) restores the original sequence" do
      check all(
              base <- list_of(integer(), max_length: 8),
              pos_offset <- integer(0..length(base)),
              value <- integer()
            ) do
        # `pos` ranges over [1, #base + 1] — the legal insert positions.
        pos = pos_offset + 1

        elems_lua = Enum.map_join(base, ", ", &Integer.to_string/1)

        code = """
        local t = {#{elems_lua}}
        local original_len = #t
        table.insert(t, #{pos}, #{value})
        local removed = table.remove(t, #{pos})
        local matches_original = #t == original_len
        for i = 1, original_len do
          if t[i] ~= ({#{elems_lua}})[i] then matches_original = false end
        end
        return removed, matches_original, #t
        """

        assert run!(code) == [value, true, length(base)]
      end
    end
  end
end

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

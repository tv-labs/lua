defmodule Lua.VM.GCTest do
  @moduledoc """
  Pins `Lua.gc/2`: what each mode frees and keeps, that the write barrier
  covers every VM write path, how `:auto` paces itself, and that collection
  is refused while Lua code is running.
  """

  use ExUnit.Case, async: true

  @soak """
  local counter = 0
  function step()
    counter = counter + 1
    for i = 1, 100 do
      local scratch = {i, tostring(i), {nested = i}}
    end
    local response = {body = string.rep("x", 8192)}
    return counter
  end
  """

  defp heap_size(%Lua{state: state}) do
    {map_size(state.tables), map_size(state.upvalue_cells)}
  end

  # A minor collection can keep garbage, but it must not free a live object.
  defp assert_minor_keeps_live(lua) do
    minor = Lua.gc(lua, mode: :minor).state
    major = Lua.gc(lua, mode: :major).state

    assert Enum.reject(Map.keys(major.tables), &is_map_key(minor.tables, &1)) == []
    assert Enum.reject(Map.keys(major.upvalue_cells), &is_map_key(minor.upvalue_cells, &1)) == []
  end

  describe "major" do
    test "retained state returns to baseline after every call" do
      {_, lua} = Lua.eval!(Lua.new(), @soak)
      lua = Lua.gc(lua, mode: :major)
      baseline = heap_size(lua)

      lua =
        Enum.reduce(1..1_000, lua, fn n, lua ->
          {:ok, [^n], lua} = Lua.call_function(lua, [:step], [])
          Lua.gc(lua, mode: :major)
        end)

      assert heap_size(lua) == baseline
      assert {[1001], _} = Lua.eval!(lua, "return step()")
    end

    test "frees old garbage a minor collection keeps" do
      {_, lua} = Lua.eval!(Lua.new(), "big = {}")
      lua = Lua.gc(lua, mode: :major)
      {old, _} = heap_size(lua)
      {_, lua} = Lua.eval!(lua, "big = nil")

      assert {^old, _} = heap_size(Lua.gc(lua, mode: :minor))
      assert {freed, _} = heap_size(Lua.gc(lua, mode: :major))
      assert freed == old - 1
    end
  end

  test "without gc the same workload grows" do
    {_, lua} = Lua.eval!(Lua.new(), @soak)
    {before, _} = heap_size(lua)

    lua =
      Enum.reduce(1..10, lua, fn _, lua ->
        {:ok, _, lua} = Lua.call_function(lua, [:step], [])
        lua
      end)

    {after_calls, _} = heap_size(lua)
    assert after_calls - before >= 1_000
  end

  describe "minor" do
    test "frees young garbage and promotes survivors" do
      {_, lua} = Lua.eval!(Lua.new(), @soak)
      lua = Lua.gc(lua, mode: :major)
      baseline = heap_size(lua)

      {:ok, _, lua} = Lua.call_function(lua, [:step], [])
      lua = Lua.gc(lua, mode: :minor)

      assert heap_size(lua) == baseline
      assert lua.state.gc_young_from == lua.state.table_next_id
      assert lua.state.gc_remembered == %{}
    end

    # Each case writes a young table into an old table through a different VM write path.
    for {name, setup, write, read} <- [
          {"field write", "old = {}", "old.k = {v = 1}", "return old.k.v"},
          {"integer key write", "old = {}", "old[1] = {v = 1}", "return old[1].v"},
          {"computed key write", "old = {}", "local k = 'k' old[k] = {v = 1}", "return old.k.v"},
          {"write inside a function", "old = {}", "local function f() old.k = {v = 1} end f()", "return old.k.v"},
          {"write through a metatable without __newindex", "old = setmetatable({}, {})", "old.k = {v = 1}",
           "return old.k.v"},
          {"overwrite through a metatable", "old = setmetatable({k = 0}, {__newindex = error})", "old.k = {v = 1}",
           "return old.k.v"},
          {"__newindex table", "old = {} proxy = setmetatable({}, {__newindex = old})", "proxy.k = {v = 1}",
           "return old.k.v"},
          {"rawset", "old = {}", "rawset(old, 'k', {v = 1})", "return old.k.v"},
          {"table.insert", "old = {}", "table.insert(old, {v = 1})", "return old[1].v"},
          {"table.insert at position", "old = {0}", "table.insert(old, 1, {v = 1})", "return old[1].v"},
          {"table.move", "old = {}", "table.move({{v = 1}}, 1, 1, 1, old)", "return old[1].v"},
          {"table.sort", "old = {}",
           "old[1] = {v = 1} old[2] = {v = 0} table.sort(old, function(a, b) return a.v < b.v end)", "return old[2].v"},
          {"setmetatable", "old = {}", "setmetatable(old, {__index = {v = 1}})", "return old.v"},
          {"global write", "", "g = {v = 1}", "return g.v"},
          {"global write inside a function", "", "local function f() g = {v = 1} end f()", "return g.v"},
          {"closure stored in an old table", "old = {}", "local t = {v = 1} old.f = function() return t end",
           "return old.f().v"},
          {"old upvalue cell", "local c function set(x) c = x end function get() return c end", "set({v = 1})",
           "return get().v"}
        ] do
      test "keeps a young table reachable only through #{name}" do
        {_, lua} = Lua.eval!(Lua.new(sandboxed: []), unquote(setup))
        lua = Lua.gc(lua, mode: :major)
        {_, lua} = Lua.eval!(lua, unquote(write))

        assert_minor_keeps_live(lua)
        lua = Lua.gc(lua, mode: :minor)
        assert {[1], _} = Lua.eval!(lua, unquote(read))
      end
    end

    test "keeps a young table written through Lua.set!" do
      {_, lua} = Lua.eval!(Lua.new(), "old = {}")
      lua = Lua.gc(lua, mode: :major)
      lua = Lua.set!(lua, [:old, :k], %{"v" => 1})

      assert_minor_keeps_live(lua)
      lua = Lua.gc(lua, mode: :minor)
      assert {[1], _} = Lua.eval!(lua, "return old.k.v")
    end

    test "keeps the remembered set across a caught error" do
      {_, lua} = Lua.eval!(Lua.new(), "old = {} function boom() old.k = {v = 1} error('x') end")
      lua = Lua.gc(lua, mode: :major)
      {:error, _, lua} = Lua.call_function(lua, [:boom], [])

      assert_minor_keeps_live(lua)
      lua = Lua.gc(lua, mode: :minor)
      assert {[1], _} = Lua.eval!(lua, "return old.k.v")
    end
  end

  describe "auto" do
    test "first collection is major and sets the pacing threshold" do
      lua = Lua.gc(Lua.new())
      assert lua.state.gc.major_at > 0
      assert lua.state.gc_young_from == lua.state.table_next_id
    end

    test "does nothing until enough tables have been allocated" do
      lua = Lua.gc(Lua.new())
      {_, lua} = Lua.eval!(lua, "for i = 1, 10 do local t = {} end")
      assert Lua.gc(lua) == lua
    end

    test "keeps a long-running soak bounded" do
      {_, lua} = Lua.eval!(Lua.new(), @soak)
      lua = Lua.gc(lua)
      {baseline, _} = heap_size(lua)

      {lua, peak} =
        Enum.reduce(1..1_000, {lua, 0}, fn n, {lua, peak} ->
          {:ok, [^n], lua} = Lua.call_function(lua, [:step], [])
          lua = Lua.gc(lua)
          {tables, _} = heap_size(lua)
          {lua, max(peak, tables)}
        end)

      # Garbage accumulates only until the next minor collection.
      assert peak - baseline < 1_200
      assert {[1001], _} = Lua.eval!(lua, "return step()")
    end

    test "collects a workload that allocates closure cells but no tables" do
      {_, lua} =
        Lua.eval!(Lua.new(), """
        function step()
          local x = 0
          local f = function() return x end
          return f()
        end
        """)

      lua = Lua.gc(lua)
      {_, baseline} = heap_size(lua)

      lua =
        Enum.reduce(1..3_000, lua, fn _, lua ->
          {:ok, [0], lua} = Lua.call_function(lua, [:step], [])
          Lua.gc(lua)
        end)

      {_, cells} = heap_size(lua)
      assert cells - baseline < 1_100
    end

    test "collects a workload that allocates userdata but no tables" do
      lua =
        Lua.set!(Lua.new(), [:make], fn _args, lua ->
          {ud, lua} = Lua.encode!(lua, {:userdata, :payload})
          {[ud], lua}
        end)

      {_, lua} = Lua.eval!(lua, "function step() local u = make() end")
      lua = Lua.gc(lua)

      lua =
        Enum.reduce(1..5_000, lua, fn _, lua ->
          {:ok, _, lua} = Lua.call_function(lua, [:step], [])
          Lua.gc(lua)
        end)

      assert map_size(lua.state.userdata) < 3_000
    end
  end

  describe "roots" do
    test "a Lua.set! callback keeps the tables it captured alive" do
      {[t], lua} = Lua.eval!(Lua.new(), "return {x = 1}", decode: false)
      t = Lua.unwrap(t)
      lua = Lua.set!(lua, [:get], fn _ -> [t] end)
      lua = Lua.gc(lua, mode: :major)

      assert {[1], _} = Lua.eval!(lua, "return get().x")
    end

    test "a callback that captured a Lua state does not pin that state's heap" do
      {_, lua} = Lua.eval!(Lua.new(), "big = {} for i = 1, 100 do big[i] = {} end")
      snapshot = lua
      lua = Lua.set!(lua, [:probe], fn _ -> [map_size(snapshot.state.tables)] end)
      {_, lua} = Lua.eval!(lua, "big = nil")
      before = map_size(lua.state.tables)

      lua = Lua.gc(lua, mode: :major)
      assert map_size(lua.state.tables) <= before - 101
    end

    test "a major collection frees unreachable userdata and what only it referenced" do
      {_, lua} = Lua.eval!(Lua.new(), "inner = {v = 1}")
      inner = lua |> Lua.get!([:inner], decode: false) |> Lua.unwrap()
      {ud, lua} = Lua.encode!(lua, {:userdata, inner})
      lua = Lua.set!(lua, [:holder], ud)
      {_, lua} = Lua.eval!(lua, "inner = nil")

      lua = Lua.gc(lua, mode: :major)
      assert map_size(lua.state.userdata) == 1
      assert {[1], lua} = Lua.eval!(lua, "return 1")
      tables = map_size(lua.state.tables)

      {_, lua} = Lua.eval!(lua, "holder = nil")
      lua = Lua.gc(lua, mode: :major)
      assert lua.state.userdata == %{}
      assert map_size(lua.state.tables) == tables - 1
    end

    test "a deep object graph is traced without deep recursion" do
      {_, lua} = Lua.eval!(Lua.new(), "local n = nil for i = 1, 200000 do n = {next = n} end chain = n")
      lua = Lua.gc(lua, mode: :major)

      assert map_size(lua.state.tables) > 200_000
      assert {[200_000], _} = Lua.eval!(lua, "local c, n = 0, chain while n do c = c + 1 n = n.next end return c")
    end
  end

  test "string.gmatch iterators leave nothing behind once unreachable" do
    {_, lua} =
      Lua.eval!(Lua.new(), """
      function step()
        local n = 0
        for w in string.gmatch("a b c", "%a") do n = n + 1 end
        return n
      end
      """)

    lua = Lua.gc(lua, mode: :major)
    baseline = {map_size(lua.state.private), map_size(lua.state.upvalue_cells)}

    lua =
      Enum.reduce(1..50, lua, fn _, lua ->
        {:ok, [3], lua} = Lua.call_function(lua, [:step], [])
        lua
      end)

    lua = Lua.gc(lua, mode: :major)
    assert {map_size(lua.state.private), map_size(lua.state.upvalue_cells)} == baseline
  end

  test "rejects an unknown mode" do
    assert_raise ArgumentError, ~r/:mode must be/, fn -> Lua.gc(Lua.new(), mode: :full) end
  end

  test "closures keep their captured tables and shared cells alive" do
    {_, lua} =
      Lua.eval!(Lua.new(), """
      local data = {value = 42}
      local n = 0
      get = function() return data.value end
      inc = function() n = n + 1; return n end
      peek = function() return n end
      """)

    lua = Lua.gc(lua, mode: :major)
    {[42], lua} = Lua.eval!(lua, "return get()")
    {[1], lua} = Lua.eval!(lua, "return inc()")
    lua = Lua.gc(lua, mode: :major)
    assert {[1], _} = Lua.eval!(lua, "return peek()")
  end

  test "metatables and string methods survive" do
    {_, lua} =
      Lua.eval!(Lua.new(), """
      cls = setmetatable({}, {__index = function(_, k) return k .. "!" end})
      """)

    lua = Lua.gc(lua, mode: :major)
    assert {["hi!", "ABC"], _} = Lua.eval!(lua, "return cls.hi, ('abc'):upper()")
  end

  test ":keep roots values held only by Elixir" do
    {[t], lua} = Lua.eval!(Lua.new(), "return {answer = 42}", decode: false)
    lua = Lua.gc(lua, keep: [t], mode: :major)
    assert Lua.decode!(lua, t) == [{"answer", 42}]
  end

  describe "refuses to run while Lua frames are active" do
    setup do
      [lua: Lua.set!(Lua.new(), [:collect], fn _args, lua -> {[], Lua.gc(lua, mode: :major)} end)]
    end

    test "from a callback in the main chunk", %{lua: lua} do
      assert_raise Lua.RuntimeException, ~r/must not be called while Lua code is running/, fn ->
        Lua.eval!(lua, "local t = {v = 42} collect() return t.v")
      end
    end

    test "from a callback inside a pcall'd function", %{lua: lua} do
      assert {[false, message], _} =
               Lua.eval!(lua, "local t = {v = 42} return pcall(function() collect() end)")

      assert message =~ "must not be called while Lua code is running"
    end

    test "from a callback reached through call_function", %{lua: lua} do
      {_, lua} = Lua.eval!(lua, "function f() local t = {v = 42} collect() return t.v end")
      assert {:error, %Lua.RuntimeException{}, _} = Lua.call_function(lua, [:f], [])
      assert {:error, %Lua.RuntimeException{}, _} = Lua.call_function(lua, [:collect], [])
    end
  end

  describe "gc_reentrant/2" do
    @churn """
    function churn()
      local t = {}
      for i = 1, 200 do t[i] = {i} end
      published = {from_churn = true}
      return #t
    end
    """

    # `host()` reenters Lua while its caller is suspended, as a host that serves another call
    # during a wait does, and reports the heap around the collection.
    defp reentering(name, function) do
      owner = self()

      Lua.set!(Lua.new(), [name], fn _args, lua ->
        {n, collected} =
          Lua.gc_reentrant(lua, fn lua ->
            {:ok, [n], lua} = Lua.call_function(lua, [function], [])
            send(owner, {:before, Map.keys(lua.state.tables)})
            {n, lua}
          end)

        send(owner, {:after, Map.keys(collected.state.tables)})
        {[n], collected}
      end)
    end

    test "frees what the reentrant call left and keeps the suspended caller's objects" do
      {_, lua} = Lua.eval!(reentering(:host, :churn), @churn)
      lua = Lua.gc(lua, mode: :major)

      {[7, 200, true], lua} =
        Lua.eval!(lua, """
        local before = {value = 7}
        local n = host()
        return before.value, n, published.from_churn
        """)

      assert_received {:before, before}
      assert_received {:after, kept}
      assert length(before) - length(kept) >= 200
      assert lua.state.entry_depth == 0

      # Never more aggressive than a full trace of the finished state.
      live = Map.keys(Lua.gc(lua, mode: :major).state.tables)
      assert Enum.reject(live, &(&1 in kept or &1 >= lua.state.gc_young_from)) == []
    end

    test "nests: an inner collection keeps the middle call's objects" do
      lua = reentering(:inner_host, :churn)

      lua =
        Lua.set!(lua, [:outer_host], fn _args, lua ->
          Lua.gc_reentrant(lua, fn lua ->
            {:ok, results, lua} = Lua.call_function(lua, [:middle], [])
            {results, lua}
          end)
        end)

      {_, lua} =
        Lua.eval!(
          lua,
          @churn <>
            """
            function middle()
              local mine = {value = 5}
              local n = inner_host()
              return mine.value + n
            end
            """
        )

      assert {[205, 9], _} =
               Lua.eval!(lua, "local outer = {value = 9} local r = outer_host() return r, outer.value")
    end

    test "refuses a function that returns at another entry depth" do
      lua =
        Lua.set!(Lua.new(), [:host], fn _args, lua ->
          Lua.gc_reentrant(lua, fn _lua -> {[], Lua.new()} end)
        end)

      assert_raise Lua.RuntimeException, ~r/same entry depth/, fn -> Lua.eval!(lua, "host()") end
    end
  end

  test "is allowed again after a call returns or raises" do
    {_, lua} = Lua.eval!(Lua.new(), "function boom() error('x') end")
    {[false, _], lua} = Lua.eval!(lua, "return pcall(boom)")
    {:error, _, lua} = Lua.call_function(lua, [:boom], [])
    assert lua.state.entry_depth == 0
    assert %Lua{} = Lua.gc(lua, mode: :major)
  end
end

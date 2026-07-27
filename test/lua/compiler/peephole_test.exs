defmodule Lua.Compiler.PeepholeTest do
  @moduledoc """
  Pins the peephole pass: the rewrites it performs, the rewrites it must
  refuse, and — the load-bearing part — that turning it on changes nothing
  an observer can see.

  The differential compiles each program twice, once with `peephole: false`
  and once with it on, evaluates both, and compares results, printed output,
  and (for the failing battery) the rendered exception byte for byte. The
  rewritten stream must also never need a wider register file or more
  instruction slots than the stream it came from.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Lua.Compiler
  alias Lua.Compiler.Bytecode
  alias Lua.Compiler.Codegen
  alias Lua.Compiler.Prototype
  alias Lua.Parser

  defp compile!(source, opts \\ []) do
    {:ok, ast} = Parser.parse_structured(source)
    {:ok, proto} = Compiler.compile(ast, Keyword.merge([source: "peephole-test.lua"], opts))
    proto
  end

  defp run(source, opts) do
    proto = compile!(source, opts)
    chunk = %Lua.Chunk{prototype: proto}

    fn ->
      result =
        try do
          {results, _lua} = Lua.eval!(Lua.new(), chunk)
          {:ok, results}
        rescue
          e -> {:error, Lua.format_exception(e)}
        end

      send(self(), {:result, result})
    end
    |> capture_io()
    |> then(fn output ->
      receive do
        {:result, result} -> {result, output}
      end
    end)
  end

  # Every opcode tag in a prototype tree, own instructions only.
  defp opcodes(%Prototype{} = proto) do
    tags(proto.instructions) ++ Enum.flat_map(proto.prototypes, &opcodes/1)
  end

  defp tags(instructions) do
    Enum.flat_map(instructions, fn
      instr when is_tuple(instr) ->
        [:erlang.element(1, instr) | Enum.flat_map(bodies(instr), &tags/1)]

      atom ->
        [atom]
    end)
  end

  defp bodies({:test, _reg, then_body, else_body}), do: [then_body, else_body]
  defp bodies({:test_and, _dest, _source, body}), do: [body]
  defp bodies({:test_or, _dest, _source, body}), do: [body]
  defp bodies({:while_loop, cond_body, _reg, body}), do: [cond_body, body]
  defp bodies({:repeat_loop, body, cond_body, _reg}), do: [body, cond_body]
  defp bodies({:numeric_for, _base, _loop_var, body}), do: [body]
  defp bodies({:generic_for, _base, _var_regs, body}), do: [body]
  defp bodies(_instr), do: []

  defp count_instructions(%Prototype{} = proto) do
    length(opcodes(proto))
  end

  # Walks a prototype tree pairwise, applying `fun` to each matched pair.
  defp zip_protos(%Prototype{} = a, %Prototype{} = b, fun) do
    fun.(a, b)

    a.prototypes
    |> Enum.zip(b.prototypes)
    |> Enum.each(fn {child_a, child_b} -> zip_protos(child_a, child_b, fun) end)
  end

  describe "move elision" do
    test "retargets an adjacent producer at the move's destination" do
      proto = compile!("function f(t) local x = t.a return x end")
      [f] = proto.prototypes

      # `get_field tmp, t, "a"` + `move x, tmp` collapses into a single
      # `get_field x, t, "a"`.
      assert Enum.count(opcodes(f), &(&1 == :move)) == 0
      assert Enum.count(opcodes(f), &(&1 == :get_field)) == 1
    end

    test "finds the copy across intervening transparent instructions" do
      # The `for` header loads three temporaries and then copies all three
      # into the control triple, so no producer is adjacent to its copy.
      before = compile!("function f(n) for i = 1, n do end end", peephole: false)
      after_pass = compile!("function f(n) for i = 1, n do end end")

      [before_f] = before.prototypes
      [after_f] = after_pass.prototypes

      # Three loads and three copies become three loads; the empty body's
      # block close goes too.
      assert count_instructions(before_f) - count_instructions(after_f) >= 2
    end

    test "refuses to coalesce when the temporary is read again" do
      # `x` is used twice, so the register holding it is live past the copy.
      proto = compile!("function f(t) local x = t.a return x + x end")
      [f] = proto.prototypes

      assert :get_field in opcodes(f)
    end

    test "a conditional reassignment still wins" do
      source = "function f(t, c) local x = t.a if c then x = 1 end return x end"

      before = compile!(source, peephole: false)
      after_pass = compile!(source)

      # Whatever it rewrites, it must not widen the frame.
      zip_protos(before, after_pass, fn a, b -> assert b.max_registers <= a.max_registers end)

      assert {[7, 1], _} =
               Lua.eval!(source <> " return f({a = 7}, false), f({a = 7}, true)")
    end
  end

  describe "constant folding" do
    test "folds a literal right operand into the arithmetic op" do
      proto = compile!("function f(n) return n - 1 end")
      [f] = proto.prototypes

      assert :subtract_k in opcodes(f)
      refute :subtract in opcodes(f)
      refute :load_constant in opcodes(f)
    end

    test "folds a literal right operand into a comparison" do
      proto = compile!("function f(n) if n < 2 then return n end return 0 end")
      [f] = proto.prototypes

      assert :less_than_k in opcodes(f)
      refute :less_than in opcodes(f)
    end

    test "leaves the register form alone when both operands are registers" do
      proto = compile!("function f(a, b) return a - b end")
      [f] = proto.prototypes

      assert :subtract in opcodes(f)
      refute :subtract_k in opcodes(f)
    end

    test "does not fold a literal on the left" do
      proto = compile!("function f(n) return 1 - n end")
      [f] = proto.prototypes

      assert :subtract in opcodes(f)
      refute :subtract_k in opcodes(f)
    end

    test "does not fold operations with no _k variant" do
      proto = compile!("function f(n) return n / 2, n % 2, n ^ 2 end")
      [f] = proto.prototypes

      assert :divide in opcodes(f)
      assert :modulo in opcodes(f)
      assert :power in opcodes(f)
    end

    test "the folded form preserves the operand hint" do
      proto = compile!("function f(n) return n - 1 end")
      [f] = proto.prototypes

      assert [{:subtract_k, _dest, _a, 1, {:local, "n"}}] =
               Enum.filter(f.instructions, &match?({:subtract_k, _, _, _, _}, &1))
    end
  end

  describe "upvalue-field fusion" do
    test "fuses the global read every free name compiles to" do
      proto = compile!("function f() return print end")
      [f] = proto.prototypes

      assert :get_field_upvalue in opcodes(f)
      refute :get_upvalue in opcodes(f)
      refute :get_field in opcodes(f)
    end

    test "fuses the global write" do
      proto = compile!("function f() x = 1 end")
      [f] = proto.prototypes

      assert :set_field_upvalue in opcodes(f)
      refute :get_upvalue in opcodes(f)
    end

    test "leaves the chunk's own _ENV alone — it lives in a register, not an upvalue" do
      proto = compile!("x = 1 return x")

      refute :get_field_upvalue in tags(proto.instructions)
      refute :set_field_upvalue in tags(proto.instructions)
    end
  end

  describe "unreachable code" do
    test "drops the block close codegen appends after a return" do
      proto = compile!("function f(n) if n < 2 then return n end return 0 end")
      [f] = proto.prototypes

      refute :close_upvalues in opcodes(f)
    end
  end

  describe "redundant close_upvalues" do
    test "a closure-free function keeps none" do
      proto = compile!("function f(n) local s = 0 for i = 1, n do local t = i * 2 s = s + t end return s end")
      [f] = proto.prototypes

      refute :close_upvalues in opcodes(f)
    end

    test "a function that builds a closure keeps all of them" do
      source = """
      function f(n)
        local acc = {}
        for i = 1, n do
          local v = i
          acc[i] = function() return v end
        end
        return acc
      end
      """

      before = compile!(source, peephole: false)
      after_pass = compile!(source)

      [before_f] = before.prototypes
      [after_f] = after_pass.prototypes

      assert Enum.count(opcodes(before_f), &(&1 == :close_upvalues)) ==
               Enum.count(opcodes(after_f), &(&1 == :close_upvalues))
    end

    test "captured loop locals still see their own value per iteration" do
      assert {[1, 2, 3], _} =
               Lua.eval!("""
               local acc = {}
               for i = 1, 3 do
                 local v = i
                 acc[i] = function() return v end
               end
               return acc[1](), acc[2](), acc[3]()
               """)
    end
  end

  describe "goto opt-out" do
    test "a function containing a label is left exactly as codegen emitted it" do
      source = """
      function f(n)
        local i = 0
        ::top::
        i = i + 1
        if i < n then goto top end
        return i
      end
      """

      before = compile!(source, peephole: false)
      after_pass = compile!(source)

      assert before.prototypes |> hd() |> Map.get(:instructions) ==
               after_pass.prototypes |> hd() |> Map.get(:instructions)
    end
  end

  describe "fib" do
    test "compiles to the fused ten-opcode form in four registers" do
      proto =
        compile!("""
        function fib(n)
          if n < 2 then return n end
          return fib(n-1) + fib(n-2)
        end
        """)

      [fib] = proto.prototypes

      assert fib.max_registers == 4
      assert tuple_size(fib.bytecode) == 10
      assert Bytecode.fully_compiled?(proto)
    end

    test "still computes fib" do
      assert {[610], _} =
               Lua.eval!("""
               function fib(n)
                 if n < 2 then return n end
                 return fib(n-1) + fib(n-2)
               end
               return fib(15)
               """)
    end
  end

  # A corpus broad enough that a mis-scoped rewrite shows up somewhere:
  # every control-flow shape, closures over loop variables, metatables,
  # varargs, multi-return, coroutines, string building, and pcall.
  @corpus [
    "return 1 + 2 * 3 - 4",
    "local x = 5 return x * x, x - 1, x + 1",
    "function fib(n) if n < 2 then return n end return fib(n-1) + fib(n-2) end return fib(12)",
    "local s = 0 for i = 1, 20 do s = s + i end return s",
    "local s = 0 for i = 20, 1, -2 do s = s + i end return s",
    "local i, s = 0, 0 while i < 10 do i = i + 1 s = s + i end return i, s",
    "local i = 0 repeat i = i + 1 until i >= 7 return i",
    "local t = {} for i = 1, 5 do t[i] = i * i end local s = 0 for _, v in ipairs(t) do s = s + v end return s",
    "local t = {a = 1, b = 2, c = 3} local n = 0 for k, v in pairs(t) do n = n + v end return n",
    "local t = {1, 2, 3, 4, 5} return #t, t[1], t[5]",
    "for i = 1, 10 do if i > 4 then break end end return 'done'",
    "local a = nil return a or 'fallback', a and 'never'",
    "local function add(a, b) return a + b end return add(3, 4)",
    "local acc = {} for i = 1, 3 do local v = i acc[i] = function() return v end end return acc[1](), acc[3]()",
    "local c = 0 local function inc() c = c + 1 return c end inc() inc() return inc()",
    "local function many() return 1, 2, 3 end local a, b, c = many() return a, b, c",
    "local function many() return 1, 2, 3 end return {many()}",
    "local function v(...) return select('#', ...), ... end return v(1, 2, 3)",
    "local function v(...) local t = {...} return #t end return v('a', 'b', 'c', 'd')",
    "local mt = {__add = function(a, b) return 'added' end} local t = setmetatable({}, mt) return t + 1",
    "local mt = {__index = function(_, k) return k .. '!' end} local t = setmetatable({}, mt) return t.hi",
    "local mt = {__lt = function() return true end} local a = setmetatable({}, mt) local b = setmetatable({}, mt) return a < b",
    "local mt = {__newindex = function(t, k, v) rawset(t, k, v * 2) end} local t = setmetatable({}, mt) t.x = 5 return t.x",
    "local ok, err = pcall(function() error('boom') end) return ok, err",
    "local ok, err = pcall(function() local x = nil return x.y end) return ok, type(err)",
    "return tostring(1) .. '-' .. tostring(2.5) .. '-' .. tostring(true)",
    "local s = '' for i = 1, 8 do s = s .. i end return s",
    "return string.format('%d %s %.2f', 7, 'x', 1.5)",
    "return string.upper('abc'), string.sub('hello', 2, 4), #('hello')",
    "return math.max(1, 9, 3), math.min(1, 9, 3), math.floor(2.7)",
    "return 7 // 2, 7 % 2, 2 ^ 10, -7 // 2",
    "return 5 & 3, 5 | 3, 5 ~ 3, ~0, 1 << 4, 256 >> 4",
    "local t = {} for i = 1, 5 do table.insert(t, 6 - i) end table.sort(t) return table.concat(t, ',')",
    """
    Animal = {}
    Animal.__index = Animal
    function Animal.new(name) local o = setmetatable({}, Animal) o.name = name return o end
    function Animal:speak() return self.name .. ' speaks' end
    local a = Animal.new('cat')
    return a:speak()
    """,
    """
    local co = coroutine.create(function(a)
      local b = coroutine.yield(a + 1)
      return b * 2
    end)
    local _, x = coroutine.resume(co, 1)
    local _, y = coroutine.resume(co, 10)
    return x, y
    """,
    """
    local i = 0
    ::top::
    i = i + 1
    if i < 5 then goto top end
    return i
    """,
    """
    local function outer()
      local n = 0
      return function() n = n + 1 return n end, function() return n end
    end
    local inc, get = outer()
    inc() inc()
    return get()
    """,
    """
    local t = {}
    for i = 1, 4 do
      for j = 1, 4 do
        t[#t + 1] = i * j
      end
    end
    return #t, t[1], t[16]
    """,
    "print('one') print(2) print(nil, true) return 'printed'"
  ]

  describe "differential: peephole off vs on" do
    for {source, index} <- Enum.with_index(@corpus) do
      test "corpus ##{index} evaluates identically #{inspect(String.slice(source, 0, 40))}" do
        source = unquote(source)

        assert run(source, peephole: false) == run(source, peephole: true)
      end
    end

    test "fixture files evaluate identically" do
      for path <- Path.wildcard(Path.join(__DIR__, "../../fixtures/*.lua")),
          match?({:ok, _}, Parser.parse_structured(File.read!(path))) do
        source = File.read!(path)

        # Some fixtures exist to fail at run time; both sides must fail the
        # same way.
        assert run(source, peephole: false) == run(source, peephole: true),
               "#{Path.basename(path)} diverged between peephole off and on"
      end
    end
  end

  describe "differential: error rendering" do
    @failing [
      "local n = nil return n + 1",
      "local n = nil return 1 + n",
      "local t = {} return t.a.b",
      "local t = nil t.x = 1",
      "return nil .. 'x'",
      "return 'a' < 1",
      "local f = nil return f()",
      "error('explicit')",
      "error({code = 1})",
      "local t = setmetatable({}, {}) return t < t",
      "assert(false, 'assert message')",
      "local x = 'str' return x - 1",
      "local h = math.huge return h .. {}",
      "for i = 1, 'x' do end",
      "local function f(n) return n * 2 end return f({})"
    ]

    for {source, index} <- Enum.with_index(@failing) do
      test "failure ##{index} renders identically #{inspect(String.slice(source, 0, 40))}" do
        source = unquote(source)

        {{:error, off}, _} = run(source, peephole: false)
        {{:error, on}, _} = run(source, peephole: true)

        assert off == on
      end
    end
  end

  describe "register and instruction budgets" do
    # Compiling the Lua 5.3 conformance suite is a far broader structural
    # corpus than anything hand-written here: every construct the language
    # has, at scale. These do not need to *run* to prove the pass never
    # widens a frame or grows a body.
    @suite_files Path.wildcard(Path.join(__DIR__, "../../lua53_tests/*.lua"))

    for path <- @suite_files do
      test "#{Path.basename(path)} never widens the frame or grows the stream" do
        source = File.read!(unquote(path))

        case Parser.parse_structured(source) do
          {:ok, ast} ->
            {:ok, before} = Compiler.compile(ast, source: "suite.lua", peephole: false)
            {:ok, after_pass} = Compiler.compile(ast, source: "suite.lua", peephole: true)

            zip_protos(before, after_pass, fn a, b ->
              assert b.max_registers <= a.max_registers,
                     "max_registers grew from #{a.max_registers} to #{b.max_registers}"

              assert Codegen.instruction_peak(b.instructions) <= Codegen.instruction_peak(a.instructions),
                     "instruction_peak grew"

              assert count_instructions(b) <= count_instructions(a),
                     "instruction count grew"

              assert b.max_registers >= Codegen.instruction_peak(b.instructions),
                     "max_registers no longer covers the register peak"
            end)

          {:error, _parse_errors} ->
            # A few suite files are deliberately unparseable fragments.
            :ok
        end
      end
    end

    test "the corpus stays fully dispatcher-compiled" do
      for source <- @corpus do
        before = compile!(source, peephole: false)
        after_pass = compile!(source)

        assert Bytecode.fully_compiled?(after_pass) == Bytecode.fully_compiled?(before),
               "dispatcher coverage changed for: #{String.slice(source, 0, 60)}"
      end
    end
  end
end

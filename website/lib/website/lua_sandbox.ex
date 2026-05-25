defmodule Website.LuaSandbox do
  @moduledoc """
  Safe(-ish) execution wrapper around `Lua.eval!/2`.

  Runs user-submitted Lua snippets in a supervised, time-bounded task and
  captures any output produced via the `print` builtin. The host VM is
  sandboxed via the library's default deny-list (no `io.*`, `os.*`,
  `require`, `package`, `load`, etc.), and execution is killed if it
  exceeds the configured timeout.
  """

  alias Lua.Compiler.Prototype
  alias Lua.Compiler.Instruction

  @default_timeout_ms 1_000

  @doc """
  Compiles a Lua snippet into a `Lua.Chunk` (without running it) and
  returns the chunk plus the disassembled prototype tree. Returns
  `{:error, formatted_messages}` if parsing or compilation fails.
  """
  @spec compile(String.t()) ::
          {:ok, Lua.Chunk.t(), [map()]} | {:error, [String.t()]}
  def compile(source) when is_binary(source) do
    case Lua.parse_chunk(source) do
      {:ok, %Lua.Chunk{prototype: proto} = chunk} ->
        {:ok, chunk, disassemble(proto)}

      {:error, messages} ->
        {:error, messages}
    end
  end

  @doc """
  Executes a Lua snippet under a sandboxed VM, capturing `print` output,
  returned values, and any error. Returns a `t:result/0` map.
  """
  @type result :: %{
          status: :ok | :error | :timeout,
          output: String.t(),
          returns: [term()],
          error: nil | String.t(),
          duration_us: non_neg_integer(),
          bytecode: [map()]
        }

  @spec run(String.t(), keyword()) :: result()
  def run(source, opts \\ []) when is_binary(source) do
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    parent = self()
    ref = make_ref()

    task =
      Task.async(fn ->
        send(parent, {ref, :starting})
        do_run(source)
      end)

    receive do
      {^ref, :starting} -> :ok
    after
      100 -> :ok
    end

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      nil ->
        %{
          status: :timeout,
          output: "",
          returns: [],
          error: "Execution timed out after #{timeout}ms",
          duration_us: timeout * 1000,
          bytecode: []
        }
    end
  end

  defp do_run(source) do
    started = System.monotonic_time(:microsecond)
    output_pid = start_output_collector()

    lua =
      Lua.new()
      |> Lua.set!([:print], fn args ->
        line =
          args
          |> Enum.map(&to_lua_string/1)
          |> Enum.join("\t")

        send(output_pid, {:line, line})
        []
      end)

    try do
      bytecode =
        case Lua.parse_chunk(source) do
          {:ok, %Lua.Chunk{prototype: proto}} -> disassemble(proto)
          _ -> []
        end

      {results, _lua} = Lua.eval!(lua, source)

      %{
        status: :ok,
        output: collect_output(output_pid),
        returns: Enum.map(results, &inspect_value/1),
        error: nil,
        duration_us: System.monotonic_time(:microsecond) - started,
        bytecode: bytecode
      }
    rescue
      e in [Lua.CompilerException, Lua.RuntimeException] ->
        %{
          status: :error,
          output: collect_output(output_pid),
          returns: [],
          error: e |> Exception.message() |> strip_ansi(),
          duration_us: System.monotonic_time(:microsecond) - started,
          bytecode: []
        }

      e ->
        %{
          status: :error,
          output: collect_output(output_pid),
          returns: [],
          error: e |> Exception.message() |> strip_ansi(),
          duration_us: System.monotonic_time(:microsecond) - started,
          bytecode: []
        }
    end
  end

  defp strip_ansi(s) when is_binary(s) do
    String.replace(s, ~r/\e\[[0-9;]*[a-zA-Z]/, "")
  end

  defp start_output_collector do
    spawn_link(fn -> collect_loop([]) end)
  end

  defp collect_loop(acc) do
    receive do
      {:line, line} ->
        collect_loop([line | acc])

      {:dump, from} ->
        send(from, {:lines, Enum.reverse(acc)})
    end
  end

  defp collect_output(pid) do
    send(pid, {:dump, self()})

    receive do
      {:lines, lines} -> Enum.join(lines, "\n")
    after
      50 -> ""
    end
  end

  defp to_lua_string(nil), do: "nil"
  defp to_lua_string(true), do: "true"
  defp to_lua_string(false), do: "false"
  defp to_lua_string(s) when is_binary(s), do: s
  defp to_lua_string(n) when is_integer(n), do: Integer.to_string(n)

  defp to_lua_string(n) when is_float(n) do
    if n == trunc(n) and abs(n) < 1.0e15 do
      "#{trunc(n)}.0"
    else
      Float.to_string(n)
    end
  end

  defp to_lua_string({:tref, id}), do: "table: 0x#{Integer.to_string(id, 16)}"
  defp to_lua_string(other), do: inspect(other)

  defp inspect_value(v), do: inspect(v, pretty: true, limit: 50)

  # ---- Disassembly ----

  @doc """
  Walks a `%Lua.Compiler.Prototype{}` (and its nested prototypes) and
  returns a flat list of "proto blocks" suitable for rendering in a
  compiler-explorer view.

  Each block looks like:

      %{
        index: 0,
        name: "main chunk" | "function #1",
        param_count: 0,
        is_vararg: true,
        max_registers: 4,
        instructions: [
          %{pc: 0, line: nil, op: :load_env, args: [0], pretty: "load_env r0"},
          ...
        ]
      }
  """
  def disassemble(%Prototype{} = proto) do
    {blocks, _} = walk_proto(proto, "main chunk", 0, [])
    Enum.reverse(blocks)
  end

  defp walk_proto(%Prototype{} = proto, name, next_index, acc) do
    {instrs, _last_line} =
      Enum.map_reduce(Enum.with_index(proto.instructions), nil, fn {ins, pc}, line ->
        case ins do
          {:source_line, ln, _file} ->
            {%{pc: pc, line: ln, op: :source_line, args: [ln], pretty: "; line #{ln}"}, ln}

          tuple when is_tuple(tuple) ->
            [op | args] = Tuple.to_list(tuple)
            {%{pc: pc, line: line, op: op, args: args, pretty: pretty_ins(op, args)}, line}

          atom when is_atom(atom) ->
            {%{pc: pc, line: line, op: atom, args: [], pretty: Atom.to_string(atom)}, line}
        end
      end)

    block = %{
      index: next_index,
      name: name,
      param_count: proto.param_count,
      is_vararg: proto.is_vararg,
      max_registers: proto.max_registers,
      upvalue_count: length(proto.upvalue_descriptors),
      source: proto.source,
      lines: proto.lines,
      instructions: instrs
    }

    acc = [block | acc]
    next_index = next_index + 1

    Enum.reduce(Enum.with_index(proto.prototypes), {acc, next_index}, fn {child, child_local_idx},
                                                                         {acc, next_idx} ->
      name = "function ##{next_idx} (proto[#{child_local_idx}])"
      walk_proto(child, name, next_idx, acc)
    end)
  end

  defp pretty_ins(op, args), do: "#{op} #{format_op_args(op, args)}"

  # All-register triadic arithmetic and comparison ops
  defp format_op_args(op, [a, b, c])
       when op in [
              :add,
              :subtract,
              :multiply,
              :divide,
              :floor_divide,
              :modulo,
              :power,
              :concatenate,
              :bitwise_and,
              :bitwise_or,
              :bitwise_xor,
              :shift_left,
              :shift_right,
              :equal,
              :less_than,
              :less_equal
            ],
       do: "r#{a}, r#{b}, r#{c}"

  defp format_op_args(op, [a, b])
       when op in [:negate, :not, :length, :bitwise_not, :move],
       do: "r#{a}, r#{b}"

  defp format_op_args(:load_constant, [d, val]), do: "r#{d}, #{format_lit(val)}"
  defp format_op_args(:load_nil, [d, count]), do: "r#{d}, #{count}"
  defp format_op_args(:load_boolean, [d, v]), do: "r#{d}, #{v}"
  defp format_op_args(:load_env, [d]), do: "r#{d}"
  defp format_op_args(:get_upvalue, [d, idx]), do: "r#{d}, up[#{idx}]"
  defp format_op_args(:set_upvalue, [idx, s]), do: "up[#{idx}], r#{s}"
  defp format_op_args(:get_open_upvalue, [d, r]), do: "r#{d}, r#{r}"
  defp format_op_args(:set_open_upvalue, [r, s]), do: "r#{r}, r#{s}"
  defp format_op_args(:get_global, [d, name]), do: ~s|r#{d}, _G["#{name}"]|
  defp format_op_args(:set_global, [name, s]), do: ~s|_G["#{name}"], r#{s}|
  defp format_op_args(:new_table, [d, a, h]), do: "r#{d}, array=#{a}, hash=#{h}"
  defp format_op_args(:get_table, [d, t, k | _]), do: "r#{d}, r#{t}[#{pretty_arg(k)}]"
  defp format_op_args(:set_table, [t, k, v | _]), do: "r#{t}[#{pretty_arg(k)}], r#{v}"
  defp format_op_args(:get_field, [d, t, name | _]), do: ~s|r#{d}, r#{t}.#{name}|
  defp format_op_args(:set_field, [t, name, v | _]), do: ~s|r#{t}.#{name}, r#{v}|
  defp format_op_args(:set_list, [t, s, c, o]), do: "r#{t}, start=#{s}, count=#{c}, off=#{o}"

  defp format_op_args(:call, [b, ac, rc | _]),
    do: "r#{b}, args=#{count(ac)}, results=#{count(rc)}"

  defp format_op_args(:tail_call, [b, ac | _]), do: "r#{b}, args=#{count(ac)}"
  defp format_op_args(:return, [b, c]), do: "r#{b}, count=#{count(c)}"
  defp format_op_args(:return_vararg, _), do: "(varargs)"
  defp format_op_args(:vararg, [b, c]), do: "r#{b}, count=#{count(c)}"
  defp format_op_args(:self, [b, o, name | _]), do: "r#{b}, r#{o}, .#{name}"
  defp format_op_args(:closure, [d, idx]), do: "r#{d}, proto[#{idx}]"
  defp format_op_args(:test, [r | _]), do: "r#{r}"
  defp format_op_args(:test_true, [r | _]), do: "r#{r}"
  defp format_op_args(:test_and, [d, s | _]), do: "r#{d}, r#{s}"
  defp format_op_args(:test_or, [d, s | _]), do: "r#{d}, r#{s}"
  defp format_op_args(:numeric_for, [b | _]), do: "r#{b}"
  defp format_op_args(:generic_for, [b, vc | _]), do: "r#{b}, vars=#{vc}"
  defp format_op_args(:scope, [n | _]), do: "registers=#{n}"
  defp format_op_args(:source_line, [ln]), do: "line #{ln}"
  defp format_op_args(_op, args), do: args |> Enum.map(&pretty_arg/1) |> Enum.join(", ")

  defp pretty_arg({:constant, val}), do: format_lit(val)
  defp pretty_arg({:global, name}), do: ~s|<#{name}>|
  defp pretty_arg(atom) when is_atom(atom), do: inspect(atom)
  defp pretty_arg(n) when is_integer(n), do: Integer.to_string(n)
  defp pretty_arg(other), do: inspect(other, limit: 25)

  defp format_lit(val) when is_binary(val), do: inspect(val)
  defp format_lit(val), do: inspect(val, limit: 20)

  defp count({:multi, n}), do: "multi(#{n})"
  defp count(:varargs), do: "..."
  defp count(n) when is_integer(n), do: Integer.to_string(n)
  defp count(other), do: inspect(other)

  @doc """
  Returns the Lua snippets that are rendered on the marketing home page
  (currently the compiler-explorer card). Same shape as `examples/0` so
  the example test loop can iterate over every snippet uniformly.
  """
  def home_snippets do
    [
      %{
        id: "home-fib",
        title: "Hero compiler-explorer",
        source: """
        local function fib(n)
          if n < 2 then return n end
          return fib(n - 1)
               + fib(n - 2)
        end

        return fib(15)
        """
      }
    ]
  end

  @doc """
  Returns a list of canonical example snippets for the playground/tour.
  Each snippet has an id, title, blurb, and Lua source.
  """
  def examples do
    [
      %{
        id: "hello",
        title: "Hello, Lua",
        blurb: "Your first Lua program on the BEAM.",
        source: ~s|print("Hello, Lua on the BEAM!")\nreturn 42\n|
      },
      %{
        id: "fib",
        title: "Recursive Fibonacci",
        blurb: "Classic recursion. Watch the closure prototype and tail-calls in the bytecode.",
        source: """
        local function fib(n)
          if n < 2 then return n end
          return fib(n - 1) + fib(n - 2)
        end

        for i = 0, 10 do
          print(i, fib(i))
        end

        return fib(15)
        """
      },
      %{
        id: "tables",
        title: "Tables &amp; iteration",
        blurb: "Lua's one true data structure. Mix array and hash parts freely.",
        source: """
        local people = {
          { name = "Joe Armstrong",  role = "co-creator of Erlang" },
          { name = "Robert Virding", role = "co-creator of Erlang" },
          { name = "Mike Williams",  role = "co-creator of Erlang" },
          { name = "José Valim",     role = "creator of Elixir" },
          { name = "Chris McCord",   role = "creator of Phoenix" },
        }

        for i, p in ipairs(people) do
          print(i, p.name, "->", p.role)
        end

        return #people
        """
      },
      %{
        id: "closures",
        title: "Closures &amp; upvalues",
        blurb: "Counter factory — see how upvalues are captured in the bytecode.",
        source: """
        local function make_counter(start)
          local n = start or 0
          return function()
            n = n + 1
            return n
          end
        end

        local c = make_counter(10)
        print(c(), c(), c())
        return c()
        """
      },
      %{
        id: "patterns",
        title: "String patterns",
        blurb: "Lua's tiny but mighty pattern engine — no regex needed.",
        source: """
        local s = "the quick brown fox"
        for word in string.gmatch(s, "%a+") do
          print(word, #word)
        end

        return (string.gsub(s, "(%a+)", function(w)
          return w:upper()
        end))
        """
      },
      %{
        id: "metatables",
        title: "Metatables",
        blurb: "Operator overloading via __add. Lua's secret weapon for DSLs.",
        source: """
        local Vec = {}
        Vec.__index = Vec
        Vec.__add = function(a, b)
          return setmetatable({ x = a.x + b.x, y = a.y + b.y }, Vec)
        end
        Vec.__tostring = function(v)
          return string.format("(%g, %g)", v.x, v.y)
        end

        local function vec(x, y)
          return setmetatable({ x = x, y = y }, Vec)
        end

        local a = vec(1, 2)
        local b = vec(3, 4)
        print(tostring(a + b))
        return (a + b).x, (a + b).y
        """
      },
      %{
        id: "sandbox",
        title: "Sandbox escape",
        blurb:
          "Watch the VM refuse to run dangerous stdlib calls — this is the reason it's agent-ready.",
        source: """
        -- The host process never had to defend itself.
        local ok, err = pcall(function()
          return os.execute("rm -rf /")
        end)
        print("os.execute ok?", ok)
        print("err:", err)

        local ok2 = pcall(io.open, "/etc/passwd", "r")
        print("io.open ok?", ok2)

        return ok, ok2
        """
      },
      %{
        id: "error",
        title: "Compile error",
        blurb: "See the friendly compiler error path.",
        expect: :compile_error,
        source: """
        local x = 10
        local y = 20
        return x +
        """
      },
      %{
        id: "runtime-error",
        title: "Runtime error",
        blurb: "Watch the VM blame the offending local by name, with a real stack trace.",
        expect: :runtime_error,
        source: """
        local function greet(person)
          return "hi, " .. person.name
        end

        local visitors = {
          { name = "Ada" },
          { name = "Joe" },
          nil,                   -- oops!
        }

        print(greet(visitors[1]))
        print(greet(visitors[2]))
        print(greet(visitors[3]))  -- boom
        """
      }
    ]
  end

  @doc """
  Returns the ordered list of tour lessons. Each lesson is a small
  bite-sized snippet with prose and explanation, plus an optional
  one-sentence learning objective and a "try it" exercise prompt.
  """
  def tour_lessons do
    [
      %{
        slug: "values",
        title: "Values & types",
        objective: "Recognise Lua's eight types and how its dual integer/float numbers behave.",
        body: """
        Lua has just eight types: `nil`, `boolean`, `number`, `string`,
        `function`, `userdata`, `thread`, and `table`. Numbers are 64-bit
        integers *or* floats — Lua picks whichever fits. Strings are
        interned immutable byte sequences.
        """,
        exercise:
          "Add a line that prints `type(3.0 == 3)` and predict the result before running.",
        source: """
        print(type(nil), type(true), type(1), type(1.5))
        print(type("hi"), type(print), type({}))
        return 1 + 2, 1 / 2, 1 // 2
        """
      },
      %{
        slug: "control-flow",
        title: "Control flow",
        objective: "Use `if`/`for`/`while` and learn which values Lua treats as falsy.",
        body: """
        `if`/`elseif`/`else`, `while`, `repeat..until`, and both numeric
        and generic `for` loops. Falsy values are `nil` and `false` — only.
        `0`, `""`, and `{}` are all truthy.
        """,
        exercise: "Change the threshold in `sign` so that very-small floats are treated as zero.",
        source: """
        local function sign(n)
          if n > 0 then return 1
          elseif n < 0 then return -1
          else return 0 end
        end

        for i = -2, 2 do print(i, sign(i)) end
        return sign(42)
        """
      },
      %{
        slug: "tables",
        title: "Tables are everything",
        objective:
          "Understand Lua's one data structure — arrays, records, hashes, all in one shape.",
        body: """
        Tables are *the* data structure: arrays, hash maps, records,
        objects, modules — all tables. Indexed from `1` by convention,
        with `#t` giving the length of the array part.
        """,
        exercise: "Add `t.kind = 'numeric'` and print `t.kind`. Does `#t` change?",
        source: """
        local t = { 10, 20, 30, name = "trio" }
        print(t[1], t[2], t[3], t.name, #t)

        t[#t + 1] = 40
        for i, v in ipairs(t) do print(i, v) end

        return t.name, #t
        """
      },
      %{
        slug: "functions",
        title: "First-class functions",
        objective: "Pass and return functions, and unpack multiple return values.",
        body: """
        Functions are values. They can be passed around, returned,
        and stored in tables. Multiple return values are first-class:
        `return a, b, c`.
        """,
        exercise:
          "Capture only the *quotient* from `divmod(17, 5)` and discard the remainder — what's the idiomatic way?",
        source: """
        local function divmod(a, b)
          return a // b, a % b
        end

        local q, r = divmod(17, 5)
        print(q, r)
        return divmod(100, 7)
        """
      },
      %{
        slug: "varargs",
        title: "Varargs & multiple returns",
        objective: "Use `...` to accept variable arguments and forward them with `select`.",
        body: """
        A function declared with `...` receives any number of extra
        arguments. `select("#", ...)` is the count, `select(n, ...)` is
        the tail starting at position `n`. Multiple returns flatten
        when they're the last expression in a call.
        """,
        exercise:
          "Add a `min(...)` function next to `sum` that returns the smallest argument. Use `math.huge` as the seed.",
        source: """
        local function sum(...)
          local n = select("#", ...)
          local total = 0
          for i = 1, n do total = total + select(i, ...) end
          return total, n
        end

        print(sum(1, 2, 3, 4, 5))   -- 15, 5
        print(sum())                -- 0, 0
        return sum(10, 20, 30)
        """
      },
      %{
        slug: "method-syntax",
        title: "Method syntax: `:` vs `.`",
        objective: "Read OO-style Lua and know when `self` is implicitly passed.",
        body: """
        `obj:method(args)` is sugar for `obj.method(obj, args)` — the
        colon implicitly threads `obj` as the first argument. Use `:`
        when calling methods, and `function T:foo(...)` when declaring
        them. The two forms below produce the same bytecode.
        """,
        exercise: "Toggle 'Bytecode' on and compare the disassembly for the two `greet` calls.",
        source: """
        local Greeter = { lang = "en" }

        function Greeter:hello(name)
          return self.lang .. ":hello " .. name
        end

        local g = Greeter
        print(g:hello("Ada"))      -- method call
        print(g.hello(g, "Joe"))   -- equivalent
        return g:hello("Linus")
        """
      },
      %{
        slug: "closures",
        title: "Closures & upvalues",
        objective:
          "Capture an outer-scope binding and watch the `:closure` op build the function at runtime.",
        body: """
        Inner functions capture outer locals by reference — these
        captured bindings are called *upvalues*. Run this snippet and
        click "Bytecode" to watch the `closure` opcode and the upvalue
        descriptors on the prototype.
        """,
        exercise:
          "Make `make_adder` return *two* closures, one that adds and one that subtracts. They should share the same `n`.",
        source: """
        local function make_adder(n)
          return function(x) return x + n end
        end

        local add5 = make_adder(5)
        print(add5(10), add5(100))
        return add5(0)
        """
      },
      %{
        slug: "metatables",
        title: "Metatables",
        objective: "Override operators and indexing to build OO-style classes from plain tables.",
        body: """
        Every table can have a *metatable* that customises operators,
        indexing, and tostring. This is how Lua does inheritance,
        operator overloading, and OO — all from one mechanism.
        """,
        exercise:
          "Add a `__tostring` metamethod on `Stack` that returns `'Stack(n=...)'` and `print(s)` it.",
        source: """
        local Stack = {}; Stack.__index = Stack
        function Stack.new() return setmetatable({ n = 0 }, Stack) end
        function Stack:push(v) self.n = self.n + 1; self[self.n] = v end
        function Stack:pop() local v = self[self.n]; self[self.n] = nil; self.n = self.n - 1; return v end

        local s = Stack.new()
        s:push(1); s:push(2); s:push(3)
        print(s:pop(), s:pop(), s:pop())
        return s.n
        """
      },
      %{
        slug: "strings",
        title: "Pattern matching",
        objective: "Use Lua patterns — smaller than regex, big enough for 90% of jobs.",
        body: """
        Lua's pattern engine is smaller than regex but covers most
        needs: `%a` letters, `%d` digits, `%s` spaces, `*` zero-or-more,
        `+` one-or-more, captures with `()`.
        """,
        exercise:
          "Match an ISO date *with optional time* and capture only year/month/day, ignoring the rest.",
        source: """
        local s = "2026-05-23 21:00:00"
        local y, m, d = string.match(s, "(%d+)-(%d+)-(%d+)")
        print(y, m, d)
        return y .. "/" .. m .. "/" .. d
        """
      },
      %{
        slug: "errors",
        title: "Errors & pcall",
        objective: "Raise and catch errors without leaving the VM. No try/catch needed.",
        body: """
        Errors are raised with `error()` and caught with `pcall` (or
        `xpcall` for a custom handler). No try/catch — just protected
        calls returning a status and value.
        """,
        exercise:
          "Wrap the failing call with `xpcall` and a handler that prefixes the error with `'oops: '`.",
        source: """
        local ok, err = pcall(function()
          error("boom!")
        end)
        print(ok, err)

        local ok2, val = pcall(function() return 42 end)
        print(ok2, val)
        return ok, ok2
        """
      },
      %{
        slug: "stdlib",
        title: "The standard library",
        objective:
          "Get comfortable with `string`, `table`, and `math` — the three you'll reach for daily.",
        body: """
        Lua ships a small but well-shaped stdlib. `string` has format,
        upper/lower, find/match/gmatch/gsub, byte/char. `table` has
        insert/remove/concat/sort/unpack. `math` has floor/ceil/abs/min/
        max/random/sqrt/log/sin/cos. There's no `os` or `io` in this
        sandbox — see the *Sandbox* lesson for why.
        """,
        exercise:
          "Sort `nums` in place using `table.sort(nums, function(a,b) return a > b end)` and print it.",
        source: """
        local nums = { 5, 1, 4, 2, 3 }
        print(table.concat(nums, ","))
        table.sort(nums)
        print(table.concat(nums, ","))

        print(string.format("pi ≈ %.5f", math.pi))
        return math.floor(math.pi), math.ceil(math.pi)
        """
      },
      %{
        slug: "sandbox",
        title: "The sandbox",
        objective: "See what's blocked by default — the reason this VM is agent-ready.",
        body: """
        This playground runs your code in a sandboxed VM: dangerous
        functions like `os.execute`, `io.open`, `require`, and `load`
        are stubbed to raise. Those are the libraries a host
        application typically locks down before exposing a scripting
        surface to users or LLMs. The block below tries to escape; it
        produces a friendly error instead of a catastrophe.
        """,
        exercise:
          "Try your own escape — `io.open('/etc/passwd', 'r')` or `require('os')`. Same outcome.",
        source: """
        -- This is what the agent-tool pitch protects you from:
        local ok, err = pcall(function()
          return os.execute("rm -rf /")
        end)
        print("ok?", ok)
        print("err:", err)

        -- The names exist, but they refuse to do real work:
        local ok2 = pcall(io.open, "/etc/passwd", "r")
        print("io.open?", ok2)

        return ok, ok2
        """
      },
      %{
        slug: "interop",
        title: "Talking to Elixir",
        objective:
          "Read how `deflua` exposes Elixir functions to Lua — the secret behind the agent-tool pitch.",
        body: """
        This snippet runs on the playground sandbox, where only safe
        Lua-level functions are exposed. In your *own* Elixir app you
        can register any function with `deflua` and call it from Lua.

        The snippet on the right is what your host module looks like —
        we render it as a Lua call so you can see the bytecode that an
        agent's script would compile to. The actual Elixir definition
        of `pricing.discount` lives in your codebase.
        """,
        exercise:
          "Add another call after the existing one with a different discount percentage. Watch the `call` opcode in the bytecode.",
        source: """
        -- The Elixir side (in your project):
        -- defmodule Pricing do
        --   use Lua.API, scope: "pricing"
        --   deflua discount(amount, pct), do: amount * (1 - pct/100)
        -- end
        --
        -- In the playground we stub `pricing` so you can see the shape:
        pricing = { discount = function(amount, pct)
          return amount * (1 - pct / 100)
        end }

        local total = pricing.discount(100, 15)
        print("after 15% off:", total)
        return total
        """
      },
      %{
        slug: "sigil",
        title: "The `~LUA` sigil",
        objective:
          "Embed compile-time-validated Lua inside Elixir — and pre-compile it for zero per-call parsing.",
        body: """
        `~LUA"..."` parses your Lua at *Elixir compile time*. A typo in
        the script becomes a compile error in your release, not a
        runtime surprise on a Tuesday. Add the `c` modifier and the
        sigil emits a pre-compiled `Lua.Chunk` — repeated runs skip
        the parser entirely.

        The snippet below is Elixir, not Lua — but you can run the Lua
        portion in the playground to see the bytecode the sigil
        compiles to.
        """,
        exercise:
          "Change `n + 1` to `n + ` (drop the operand) and run — see the compile error path light up the editor.",
        source: """
        -- The Lua body of `~LUA"..."c` — try editing this and toggling
        -- 'Bytecode' to see what your release would ship.
        local total = 0
        for i = 1, 100 do total = total + i end
        return total
        """
      },
      %{
        slug: "bytecode",
        title: "The bytecode model",
        objective:
          "Read a disassembled prototype: instructions, registers, upvalues, and nested protos.",
        body: """
        The compiler in this library lowers Lua to a stream of
        *register-based* opcodes — no labels, no PC-relative jumps.
        Each `function` becomes a `%Lua.Compiler.Prototype{}` with its
        own register window and upvalue descriptors. Toggle 'Bytecode'
        to see the layout. Full reference at
        `/reference/opcodes`.
        """,
        exercise:
          "Toggle 'Bytecode' on. Find the `closure` opcode that builds the inner function and the `call` that invokes it.",
        source: """
        local function double(n)
          return n * 2
        end

        return double(21)
        """
      }
    ]
  end

  # Quiet unused-warning on Instruction (kept for future opcode docs)
  @doc false
  def _instructions, do: Instruction
end

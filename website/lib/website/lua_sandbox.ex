defmodule Website.LuaSandbox do
  @moduledoc """
  Safe(-ish) execution wrapper around `Lua.eval!/2`.

  Synchronously evaluates user-submitted Lua snippets and captures any
  output produced via the `print` builtin. The host VM is sandboxed via
  the library's default deny-list (no `io.*`, `os.*`, `require`,
  `package`, `load`, etc.).

  This module is intentionally process-free: timeout enforcement and
  task lifecycle are the caller's responsibility (the LiveView wraps
  `run/1` in `start_async/3` and cancels it on a timer).
  """

  import Lua, only: [sigil_LUA: 2]

  alias Lua.Compiler.Prototype

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

  @spec run(String.t()) :: result()
  def run(source) when is_binary(source), do: do_run(source)

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
    String.replace(s, ~r/\e\[[\d;]*[\x40-\x7E]/, "")
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

  defp format_op_args(:set_list, [t, s, c, o]),
    do: "r#{t}, start=#{s}, count=#{count(c)}, off=#{o}"

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
        source: ~s|print("Hello, Lua on the BEAM!")\nreturn 42\n|,
        chunk: ~LUA"""
        print("Hello, Lua on the BEAM!")
        return 42
        """c
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
        """,
        chunk: ~LUA"""
        local function fib(n)
          if n < 2 then return n end
          return fib(n - 1) + fib(n - 2)
        end

        for i = 0, 10 do
          print(i, fib(i))
        end

        return fib(15)
        """c
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
        """,
        chunk: ~LUA"""
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
        """c
      },
      %{
        id: "closures",
        title: "Closures &amp; upvalues",
        blurb: "Counter factory. See how upvalues are captured in the bytecode.",
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
        """,
        chunk: ~LUA"""
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
        """c
      },
      %{
        id: "patterns",
        title: "String patterns",
        blurb: "Lua's tiny but mighty pattern engine. No regex needed.",
        source: """
        local s = "the quick brown fox"
        for word in string.gmatch(s, "%a+") do
          print(word, #word)
        end

        return (string.gsub(s, "(%a+)", function(w)
          return w:upper()
        end))
        """,
        chunk: ~LUA"""
        local s = "the quick brown fox"
        for word in string.gmatch(s, "%a+") do
          print(word, #word)
        end

        return (string.gsub(s, "(%a+)", function(w)
          return w:upper()
        end))
        """c
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
        """,
        chunk: ~LUA"""
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
        """c
      },
      %{
        id: "sandbox",
        title: "Sandbox escape",
        blurb:
          "Watch the VM refuse to run dangerous stdlib calls. This is the reason it's agent-ready.",
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
        """,
        chunk: ~LUA"""
        -- The host process never had to defend itself.
        local ok, err = pcall(function()
          return os.execute("rm -rf /")
        end)
        print("os.execute ok?", ok)
        print("err:", err)

        local ok2 = pcall(io.open, "/etc/passwd", "r")
        print("io.open ok?", ok2)

        return ok, ok2
        """c
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
        """,
        chunk: ~LUA"""
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
        """c
      }
    ]
  end

  @doc """
  Returns the pre-disassembled bytecode blocks for an example by id.

  Examples carry a `~LUA"..."c` chunk compiled at module compile time,
  so this is a cheap disassembly walk — no parsing. Returns `[]` for
  unknown ids or examples that intentionally omit a chunk (e.g. the
  compile-error showcase).
  """
  @spec example_blocks(String.t()) :: [map()]
  def example_blocks(id) when is_binary(id) do
    case Enum.find(examples(), &(&1.id == id)) do
      %{chunk: %Lua.Chunk{prototype: proto}} -> disassemble(proto)
      _ -> []
    end
  end

  @doc """
  Ordered chapter metadata for the tour. Each entry is `{slug, title}`.

  The sidebar in `DemoWeb.TourLive` groups lessons by `lesson.chapter`
  using this list as the section order.
  """
  def chapters do
    [
      {:basics, "Language basics"},
      {:idioms, "Idioms & deeper language"},
      {:stdlib, "The standard library"},
      {:integration, "Lua.ex integration"},
      {:internals, "Under the hood"}
    ]
  end

  @doc """
  Human title for a chapter slug. Returns `nil` for unknown slugs so the
  template can no-op rather than crashing on stale data.
  """
  def chapter_title(chapter) when is_atom(chapter) do
    Enum.find_value(chapters(), fn {slug, title} -> slug == chapter && title end)
  end

  @doc """
  Ordered list of tour lessons.

  Each lesson is a map with at least `:slug`, `:title`, `:objective`,
  `:body`, `:chapter`. Optional keys: `:source` (Lua snippet for the
  runnable editor; omit for prose-only lessons), `:elixir_source`
  (the host-side companion shown above the Lua pane in Chapter IV),
  `:exercise`, `:see_also` (list of related slugs), `:runnable`
  (default `true`; `false` makes the editor display-only and skips
  it in `lua_examples_test.exs`), and `:expect`
  (`:ok | :compile_error | :runtime_error`, default `:ok`).

  Quality rubric (enforced in `lua_examples_test.exs`):

    * `:title` ≤ 32 chars
    * `:body` ≤ 90 words
    * `:source` ≤ 18 lines (≤ 12 for `chapter: :integration`)
    * Every concept named in `:objective` and `:body` must be
      demonstrated in `:source` (human-reviewed)
    * `:exercise` must require a concept beyond what `:source` shows
  """
  def tour_lessons do
    [
      # ----- Chapter I: Language basics -----
      %{
        slug: "values",
        title: "Values & types",
        chapter: :basics,
        objective: "Recognise Lua's eight types and how integer/float numbers behave.",
        body: """
        Lua has just eight types: `nil`, `boolean`, `number`, `string`,
        `function`, `userdata`, `thread`, and `table`. Numbers split into
        two subtypes (64-bit *integer* and *float*) and Lua tracks which
        is which. Strings are interned immutable byte sequences.
        """,
        exercise:
          "Add a line that prints `type(3.0 == 3)` and predict the result before running.",
        source: """
        print(type(nil), type(true), type(1), type(1.5))
        print(type("hi"), type(print), type({}))
        print(math.type(1), math.type(1.0))   -- integer  float
        return 1 + 2, 1 / 2, 1 // 2
        """,
        see_also: ["math-and-numbers"]
      },
      %{
        slug: "variables",
        title: "Locals & assignment",
        chapter: :basics,
        objective: "Declare locals, swap with one statement, and scope with `do…end`.",
        body: """
        Bare assignment creates a *global*, which is almost never what you
        want. Use `local` for everything except top-level configuration.
        Multiple assignment is first-class: `a, b = 1, 2` (and
        `a, b = b, a` swaps without a temp). `do…end` opens a fresh
        scope; locals declared inside vanish after `end`.
        """,
        exercise:
          "Drop the `local` keyword from `x, y` and re-run. Lua quietly created a global. Print `_G.x` to confirm.",
        source: """
        local x, y = 1, 2
        print(x, y)

        x, y = y, x                -- swap with no temp
        print(x, y)

        local outer = "outside"
        do
          local inner = "inside the block"
          print(outer, inner)
        end
        print(outer, inner)        -- `inner` is nil here
        return x, y
        """
      },
      %{
        slug: "truthiness",
        title: "Truthiness & `and`/`or`",
        chapter: :basics,
        objective: "Use Lua's truthiness rule and the operand-returning behaviour of `and`/`or`.",
        body: """
        Only `nil` and `false` are falsy. `0`, `""`, and even `{}` are
        all truthy, which surprises everyone. `and`/`or` don't return
        booleans; they return whichever *operand* decided the result.
        `x or default` is the canonical default-value idiom;
        `(cond and a) or b` is Lua's ternary expression.
        """,
        exercise:
          "Make `(false and \"a\") or \"b\"` return `\"b\"`. Now make it return `false` when the first branch is false. Why is `(c and a) or b` unsafe when `a` can be `false`?",
        source: """
        print(0 and "zero is truthy")
        print("" and "empty string is truthy")
        print({} and "empty table is truthy too")

        local name = nil
        print(name or "anonymous")                  -- "anonymous"

        local age = 21
        local label = (age >= 18 and "adult") or "minor"
        print(label)
        return label
        """
      },
      %{
        slug: "control-flow",
        title: "Control flow",
        chapter: :basics,
        objective: "Use `if`, `while`, `repeat..until`, and numeric `for` with explicit steps.",
        body: """
        `if`/`elseif`/`else` are statements, not expressions. `while`
        checks before entering the body; `repeat..until` checks after,
        so the body always runs at least once. Numeric `for` takes
        `start, stop[, step]`; a negative step counts down. See
        *Iteration* for the generic `for`.
        """,
        exercise:
          "Rewrite the `while` loop as a `repeat..until`. Then flip the initial value of `i` to `5`. `while` skips, `repeat` still runs once.",
        source: """
        local function sign(n)
          if n > 0 then return 1
          elseif n < 0 then return -1
          else return 0 end
        end

        local i = 0
        while i < 3 do i = i + 1; print("while", i) end

        repeat
          i = i - 1
        until i == 0
        print("after repeat: i =", i)

        for j = 10, 6, -2 do print("for", j) end
        return sign(-42)
        """
      },
      %{
        slug: "tables",
        title: "Tables are everything",
        chapter: :basics,
        objective:
          "Build arrays, records, and nested tables, and know what `#t` actually counts.",
        body: """
        Tables are *the* data structure: arrays, hash maps, records,
        modules, all tables. Indexed from `1` by convention. `#t` is
        defined for *sequences* (`{v1, v2, ..., vn}` with no nils) and
        unspecified for sparse tables. Mix array and hash keys in one
        literal.
        """,
        exercise:
          "Add `user.prefs.shortcuts = { save = \"⌘S\" }` and print `user.prefs.shortcuts.save`. Then add `user[5] = \"trailing\"`. What does `#user` return now?",
        source: """
        local user = {
          "first row",                 -- user[1]
          "second row",                -- user[2]
          name  = "Ada",               -- user.name
          prefs = { theme = "dark" },  -- nested table
        }

        print(user[1], user.name, user.prefs.theme, #user)

        user.prefs.theme = "light"
        print(user.prefs.theme)

        local sparse = { [1] = "a", [3] = "c" }
        print("#sparse =", #sparse, "(implementation-defined)")
        return user.name
        """
      },
      %{
        slug: "iteration",
        title: "Iteration",
        chapter: :basics,
        objective:
          "Use `pairs` for hash walks, `ipairs` for sequences, and write your own iterator.",
        body: """
        `ipairs` walks the array part from `1` and stops at the first
        `nil`. `pairs` walks every key in unspecified order. The generic
        `for` accepts any *iterator function*. `range(n)` below shows
        how to write one yourself: return `(iter, state, control)` and
        Lua takes care of the rest.
        """,
        exercise:
          "Add a `step` parameter to `range` so `range(10, 2)` yields `1, 3, 5, 7, 9` with their squares.",
        source: """
        local t = { 10, 20, 30, name = "trio" }
        for i, v in ipairs(t) do print("ipairs", i, v) end
        for k, v in pairs(t)  do print("pairs ", k, v) end

        local function range(n)
          return function(_, i)
            i = i + 1
            if i <= n then return i, i * i end
          end, nil, 0
        end

        for i, sq in range(4) do print("range", i, sq) end
        return "done"
        """,
        see_also: ["coroutines", "varargs"]
      },
      %{
        slug: "functions",
        title: "First-class functions",
        chapter: :basics,
        objective: "Pass and return functions, capture multiple returns, and discard with `_`.",
        body: """
        Functions are values: pass them, return them, store them in
        tables. Multiple return values are first-class. Assigning fewer
        names drops extras (`local q = divmod(17, 5)`). Use `_` as a
        discard. Only the *last* call in an expression list flattens;
        wrap in parens to truncate to one.
        """,
        exercise:
          "Wrap the last call as `(divmod(100, 7))`. The remainder vanishes from the return; the extra parens force single-value context.",
        source: """
        local function divmod(a, b)
          return a // b, a % b
        end

        local q, r = divmod(17, 5)
        print("q, r =", q, r)

        local _, only_r = divmod(17, 5)
        print("only r =", only_r)

        -- Only the last call flattens; otherwise extras are dropped.
        local pair = { divmod(17, 5) }
        print("#pair =", #pair, pair[1], pair[2])
        return divmod(100, 7)
        """
      },
      %{
        slug: "varargs",
        title: "Varargs & multiple returns",
        chapter: :basics,
        objective: "Use `...` to accept variable arguments and forward them with `select`.",
        body: """
        A function declared with `...` receives any number of extra
        arguments. `select("#", ...)` is the count; `select(n, ...)` is
        the tail starting at position `n`. Multiple return values
        flatten when they're the last expression in a call.
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

      # ----- Chapter II: Idioms & deeper language -----
      %{
        slug: "closures",
        title: "Closures & upvalues",
        chapter: :idioms,
        objective:
          "Capture an outer-scope binding and watch the `closure` op build the function at runtime.",
        body: """
        Inner functions capture outer locals *by reference*. These
        captured bindings are called *upvalues*. Two closures over the
        same local share that storage. Run this snippet and toggle
        Bytecode to see the `closure` opcode and the upvalue
        descriptors on the inner prototype.
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
        """,
        see_also: ["bytecode", "method-syntax"]
      },
      %{
        slug: "method-syntax",
        title: "Method syntax: `:` vs `.`",
        chapter: :idioms,
        objective: "Read OO-style Lua and know when `self` is implicitly passed.",
        body: """
        `obj:method(args)` is sugar for `obj.method(obj, args)`. The
        colon implicitly threads `obj` as the first argument. Use `:`
        when calling methods, and `function T:foo(...)` when declaring
        them. The two forms below produce the same bytecode.
        """,
        exercise: "Toggle Bytecode and compare the disassembly for the two `hello` calls.",
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
        slug: "metatables-index",
        title: "Metatables: `__index`",
        chapter: :idioms,
        objective:
          "Use `__index` (table or function) for fallback lookup and single-inheritance chains.",
        body: """
        Every table can have a *metatable*. When a key is missing on
        `t`, Lua consults `t`'s metatable's `__index`. If `__index` is a
        table, lookup recurses there. That's how OO inheritance works.
        If `__index` is a function, it's called with `(t, key)`. That's
        how computed/lazy lookups work.
        """,
        exercise:
          "Toggle Bytecode and find the `get_table` op for `rex.kingdom`. It misses on `rex` and `Dog` and lands on `Animal` via two metatable hops.",
        source: """
        local Animal = { kingdom = "Animalia" }
        function Animal:describe()
          return self.name .. " is a " .. self.species
        end

        -- Dog inherits from Animal; Rex inherits from Dog.
        local Dog = setmetatable({ species = "dog" }, { __index = Animal })
        local rex = setmetatable({ name = "Rex" }, { __index = Dog })
        print(rex.kingdom)              -- found two hops up on Animal
        print(rex:describe())           -- method found on Animal

        -- __index as a function: compute on demand.
        local squares = setmetatable({}, { __index = function(_, n) return n * n end })
        print(squares[7], squares[12])
        return rex:describe()
        """,
        see_also: ["metatables-ops", "bytecode"]
      },
      %{
        slug: "metatables-ops",
        title: "Operator overloading",
        chapter: :idioms,
        objective:
          "Implement `__add`, `__eq`, `__tostring`, and `__call` so a Vector feels like a native value.",
        body: """
        Metamethods customise operators (`__add`, `__sub`, `__mul`,
        `__div`, `__unm`, `__pow`, `__concat`), equality (`__eq`),
        ordering (`__lt`, `__le`), length (`__len`), stringification
        (`__tostring`), and the call protocol (`__call`). Pair them
        with `__index = self` to make instance methods discoverable.
        """,
        exercise:
          "Add a `__sub` metamethod and a `:dot(other)` method. Use them: `print((a - b):dot(a + b))`.",
        source: """
        local Vec = {}
        Vec.__index = Vec
        Vec.__add = function(a, b) return Vec.new(a.x + b.x, a.y + b.y) end
        Vec.__eq  = function(a, b) return a.x == b.x and a.y == b.y end
        Vec.__tostring = function(v) return string.format("(%g, %g)", v.x, v.y) end
        Vec.__call = function(_, x, y) return Vec.new(x, y) end

        function Vec.new(x, y) return setmetatable({ x = x, y = y }, Vec) end
        function Vec:length() return math.sqrt(self.x ^ 2 + self.y ^ 2) end

        local a, b = Vec.new(1, 2), Vec.new(3, 4)
        print(tostring(a + b))
        print((a + b) == Vec.new(4, 6))
        print(string.format("|a| = %.3f", a:length()))
        return tostring(a + b)
        """,
        see_also: ["metatables-index"]
      },
      %{
        slug: "errors",
        title: "Errors, `pcall`, `xpcall`",
        chapter: :idioms,
        objective:
          "Raise errors as strings *or* tables, catch them with `pcall`, and add a handler with `xpcall`.",
        body: """
        `error(value)` raises. The value is usually a string, but a
        table works and is great for structured failures. `pcall(f, …)`
        returns `(true, ret…)` or `(false, err)`. `xpcall(f, handler,
        …)` lets you attach context (e.g. a traceback) *before* the
        stack unwinds.
        """,
        exercise:
          "Replace `handler` with one that returns `{ wrapped = true, original = tostring(e) }` and read `wrapped.wrapped` from the caller side.",
        source: """
        local function risky(x)
          if x < 0 then error("negative: " .. x) end
          if x == 0 then error({ code = "ZERO", retry = false }) end
          return math.sqrt(x)
        end

        local ok, err = pcall(risky, -1)
        print(ok, err)

        local ok2, payload = pcall(risky, 0)
        print(ok2, payload.code, payload.retry)

        local function handler(e) return "oops: " .. tostring(e) end
        local ok3, wrapped = xpcall(risky, handler, -9)
        print(ok3, wrapped)
        return pcall(risky, 16)                  -- true, 4.0
        """,
        see_also: ["errors-host"]
      },
      %{
        slug: "coroutines",
        title: "Coroutines (preview)",
        chapter: :idioms,
        runnable: false,
        objective:
          "Read the coroutine API and see why it's the engine behind stateful iterators.",
        body: """
        Coroutines are cooperative threads inside a single OS thread:
        `create` builds one, `resume` runs it, `yield` suspends it and
        passes values back to the caller. They're the canonical engine
        for stateful iterators and generator pipelines. The snippet
        below is canonical Lua 5.3. Coroutines are on the Lua.ex
        roadmap, so this lesson is read-only for now.
        """,
        exercise:
          "Re-read *Iteration*: `range(n)` reached the same generator-shape result by capturing state in a closure instead of yielding from a coroutine.",
        source: """
        local function producer(n)
          for i = 1, n do
            coroutine.yield(i * i)
          end
        end

        -- coroutine.wrap returns an iterator-shaped function.
        local squares = coroutine.wrap(function() producer(5) end)
        for v in squares do print(v) end

        -- coroutine.create returns a handle you drive with resume.
        local co = coroutine.create(function()
          print("step 1"); coroutine.yield()
          print("step 2"); coroutine.yield()
          print("step 3")
        end)
        coroutine.resume(co); coroutine.resume(co); coroutine.resume(co)
        """,
        see_also: ["iteration"]
      },

      # ----- Chapter III: The standard library -----
      %{
        slug: "strings",
        title: "Strings & patterns",
        chapter: :stdlib,
        objective:
          "Format, slice, and concatenate strings, then capture matches with `gmatch` and `gsub`.",
        body: """
        `..` concatenates, `#s` is byte length (not codepoints),
        `string.format` is `printf`. Patterns are *not* regex: `%a`
        letters, `%d` digits, `%s` spaces, `.` any, `%p` punctuation.
        Quantifiers: `*` 0+, `+` 1+, `?` optional, `-` shortest match.
        `gmatch` yields each match; `gsub` rewrites with a string or
        function.
        """,
        exercise:
          "Use `gsub` with a function replacement to capitalise every word: `\"hello there\"` → `\"Hello There\"`. Hint: pattern `(%a)(%a*)`.",
        source: """
        local s = "Hello, World!"
        print(#s, s:upper(), s:sub(1, 5))
        print(string.format("len=%d, first=%q", #s, s:sub(1, 5)))

        -- Captures: pattern groups in parens become return values.
        print(string.match("admin42", "(%a+)(%d+)"))
        print(string.match("2026-05-25", "(%d+)%-(%d+)%-(%d+)"))

        -- gmatch iterates every match.
        for word in string.gmatch("the quick brown fox", "%a+") do
          print(word)
        end

        -- gsub with a function replacement.
        print((string.gsub("snake_case", "_(%a)", function(c) return c:upper() end)))
        return string.format("%d words", 4)
        """
      },
      %{
        slug: "tables-stdlib",
        title: "Working with tables",
        chapter: :stdlib,
        objective:
          "Use `table.insert`, `remove`, `sort`, `concat`, and `unpack` to manipulate sequences.",
        body: """
        `table.insert(t, v)` pushes; `table.insert(t, pos, v)` inserts
        at `pos`. `table.remove(t)` pops the tail. `table.concat(t,
        sep)` is the fast string-buffer pattern. `table.sort(t[, cmp])`
        sorts in place. `table.unpack(t)` spreads a table back into a
        value list.
        """,
        exercise:
          "Sort `{3, 1, 4, 1, 5, 9, 2, 6}` so even numbers come before odd, and within each group ascending. Use a single comparator function.",
        source: """
        local t = { "b", "d", "a" }
        table.insert(t, "c")                  -- push to tail
        table.insert(t, 1, "_")               -- insert at head
        print(table.concat(t, ","))

        table.sort(t)                         -- ascending strings
        print(table.concat(t, ","))

        table.sort(t, function(a, b) return a > b end)
        print(table.concat(t, ","))

        local popped = table.remove(t)        -- pop tail
        print("popped:", popped)

        local x, y, z = table.unpack({ 10, 20, 30 })
        return x + y + z                       -- 60
        """
      },
      %{
        slug: "math-and-numbers",
        title: "Numbers: int & float",
        chapter: :stdlib,
        objective:
          "Tell integers from floats, convert between them, and know which operator returns which.",
        body: """
        Lua 5.3 has two number subtypes: 64-bit *integer* and *float*
        (double). `/` always returns a float; `//` floor-divides and
        stays integer when both operands are integers. `math.type(x)`
        reports the subtype; `math.tointeger(x)` narrows or returns
        `nil` when the value isn't representable as an integer.
        """,
        exercise:
          "Predict `math.type(1/1)` and `math.type(2^10)`. Then run and confirm. Why does `2^10` *not* return an integer?",
        source: """
        print(math.type(1), math.type(1.0))            -- integer  float
        print(math.type(1 + 1), math.type(1 + 1.0))    -- integer  float

        print(7 / 2)      -- 3.5      (/ always returns float)
        print(7 // 2)     -- 3        (int // int = int)
        print(7.0 // 2)   -- 3.0      (any float = float)
        print(-7 // 2)    -- -4       (floor, not truncate)

        print(math.tointeger(3.0))    -- 3
        print(math.tointeger(3.5))    -- nil  (not representable)
        print(tonumber("42"))         -- 42   (string -> number)

        return math.maxinteger, math.mininteger
        """,
        see_also: ["values"]
      },
      %{
        slug: "sandbox",
        title: "The sandbox",
        chapter: :stdlib,
        objective: "See what's blocked by default. This is why the VM is agent-ready.",
        body: """
        This playground runs in a sandboxed VM: dangerous functions
        like `os.execute`, `io.open`, `require`, and `load` are stubbed
        to raise. Those are the libraries a host application typically
        locks down before exposing a scripting surface to users or
        LLMs. *Chapter IV* shows how to expose your *own* safe
        functions back into Lua.
        """,
        exercise:
          "Try your own escape: `io.open('/etc/passwd', 'r')` or `require('os')`. Same outcome. Now check the *Embedding* lesson to see how to allow specific paths through.",
        source: """
        local ok, err = pcall(function()
          return os.execute("rm -rf /")
        end)
        print("os.execute ok?", ok)
        print("err:", err)

        -- The names exist, but they refuse to do real work:
        local ok2 = pcall(io.open, "/etc/passwd", "r")
        print("io.open ok?", ok2)

        return ok, ok2
        """,
        see_also: ["host-intro", "deflua"]
      },

      # ----- Chapter IV: Lua.ex integration (dual-pane) -----
      %{
        slug: "host-intro",
        title: "Embedding Lua in Elixir",
        chapter: :integration,
        objective: "Initialize a sandboxed VM and evaluate a Lua snippet from your Elixir app.",
        body: """
        `Lua.new()` returns a sandboxed VM. `Lua.eval!/2` runs a
        snippet and returns `{results, lua}`. The updated VM threads
        through, so every call yields a state you keep using. Multiple
        return values from Lua come back as an Elixir list.
        """,
        exercise:
          "Change the snippet to return three values, including a table `{ ok = true }`. The Elixir caller gets a 3-element list with the table at the end.",
        elixir_source: """
        lua = Lua.new()

        {results, lua} = Lua.eval!(lua, \"\"\"
          return 1 + 2, "hello"
        \"\"\")

        results
        # => [3, "hello"]
        """,
        source: """
        return 1 + 2, "hello"
        """,
        see_also: ["set-and-get", "call-function"]
      },
      %{
        slug: "set-and-get",
        title: "Reading & writing state",
        chapter: :integration,
        objective:
          "Define globals from Elixir with `Lua.set!` and read them back with `Lua.get!`.",
        body: """
        `Lua.set!(lua, [:greeting], "hi")` writes a global. `Lua.get!(
        lua, [:total])` reads one. Paths nest into tables:
        `Lua.set!(lua, [:cfg, :api_key], …)` writes to `cfg.api_key`.
        After `eval!`, anything the script wrote to a global is
        readable from Elixir.
        """,
        exercise:
          "Add a nested-path read on the Elixir side: `Lua.set!(lua, [:cfg, :rate], 0.08)`, then use `cfg.rate` in the Lua snippet to compute tax.",
        elixir_source: """
        lua =
          Lua.new()
          |> Lua.set!([:discount_pct], 15)
          |> Lua.set!([:prices], [10, 20, 30])

        {_, lua} = Lua.eval!(lua, source)
        Lua.get!(lua, [:final_total])
        # => 51.0
        """,
        source: """
        -- discount_pct and prices come from the Elixir host (Lua.set!).
        -- The stubs let this snippet run standalone in the playground.
        discount_pct = discount_pct or 15
        prices       = prices       or { 10, 20, 30 }

        local total = 0
        for _, p in ipairs(prices) do
          total = total + p * (1 - discount_pct / 100)
        end

        final_total = total      -- host reads this back with Lua.get!
        return total
        """,
        see_also: ["host-intro", "deflua"]
      },
      %{
        slug: "deflua",
        title: "Exposing Elixir with `deflua`",
        chapter: :integration,
        objective:
          "Define a module with `use Lua.API` + `deflua`, then load it with `Lua.load_api/2`.",
        body: """
        `deflua` turns an Elixir function into a Lua-callable. The
        optional `scope:` puts it under a namespace, so `scope:
        \"pricing\"` exposes `pricing.discount(…)`.
        `Lua.load_api(lua, MyModule)` registers the module on the VM.
        The Lua side just calls a function; the Elixir side runs the
        body.
        """,
        exercise:
          "Add `deflua tax(amount, rate)` to `Pricing`, returning `amount * rate`. Call `pricing.tax(85, 0.08)` from Lua. Remember to extend the playground stub too.",
        elixir_source: """
        defmodule Pricing do
          use Lua.API, scope: "pricing"

          deflua discount(amount, pct) do
            amount * (1 - pct / 100)
          end
        end

        lua = Lua.new() |> Lua.load_api(Pricing)
        {[total], _} = Lua.eval!(lua, ~S|return pricing.discount(100, 15)|)
        # total = 85.0
        """,
        source: """
        -- In your host, Lua.load_api(Pricing) registers `pricing.discount`.
        -- Stub it here so the snippet runs in the standalone playground.
        pricing = pricing or {
          discount = function(amount, pct) return amount * (1 - pct / 100) end,
        }

        print(string.format("$%d after 15%%: $%.2f", 100, pricing.discount(100, 15)))
        print(string.format("$%d after 30%%: $%.2f", 80,  pricing.discount(80, 30)))
        return pricing.discount(250, 10)
        """,
        see_also: ["put-private", "call-function"]
      },
      %{
        slug: "call-function",
        title: "Calling Lua from Elixir",
        chapter: :integration,
        objective:
          "Define a Lua function in a snippet, then invoke it from Elixir with `call_function!`.",
        body: """
        `Lua.call_function!(lua, [:name], [arg1, arg2])` calls a Lua
        function from Elixir. Path tuples work too: `[:string, :upper]`
        reaches stdlib. This is the pattern when your script is
        *configuration*: it defines hooks (`on_request`, `pricing`, …)
        and your Elixir code drives the loop.
        """,
        exercise:
          "Define a second function `farewell(name)` that returns `\"bye, \" .. name`. The host could now drive a request/response cycle through two hooks defined in one script.",
        elixir_source: """
        {_, lua} = Lua.eval!(Lua.new(), \"\"\"
          function greet(name) return "hi, " .. name end
        \"\"\")

        Lua.call_function!(lua, [:greet], ["Ada"])
        # => ["hi, Ada"]

        # Stdlib paths work too:
        Lua.call_function!(lua, [:string, :upper], ["heya"])
        # => ["HEYA"]
        """,
        source: """
        -- The host will call greet/1 by name after this snippet runs.
        function greet(name)
          return "hi, " .. name
        end

        -- For the playground, drive it ourselves so you see the output.
        print(greet("Ada"))
        print(greet("Joe"))
        return greet("Linus")
        """,
        see_also: ["host-intro", "deflua"]
      },
      %{
        slug: "put-private",
        title: "Private host context",
        chapter: :integration,
        objective:
          "Pass authenticated context to `deflua` handlers without exposing it to Lua scripts.",
        body: """
        `Lua.put_private(lua, :user_id, 42)` stores host state inside
        the VM that *Lua scripts cannot see*. In a `deflua` body taking
        `state`, `Lua.get_private!(state, :user_id)` reads it back.
        This is the pattern for multi-tenant sandboxes: auth, tenant
        id, and API keys stay on the host side; the script sees only
        return values.
        """,
        exercise:
          "Print `type(user_id)` from Lua. It stays `nil`. Now write a malicious-looking snippet that *tries* to read the user id (`return _G.user_id`) and confirm it can't.",
        elixir_source: """
        defmodule Account do
          use Lua.API, scope: "account"

          deflua balance(), state do
            user_id = Lua.get_private!(state, :user_id)
            {[fetch_balance(user_id)], state}
          end
        end

        lua =
          Lua.new()
          |> Lua.load_api(Account)
          |> Lua.put_private(:user_id, 42)

        {[bal], _} = Lua.eval!(lua, "return account.balance()")
        """,
        source: """
        -- account.balance is a deflua handler that reads user_id via
        -- Lua.get_private!. Lua sees only the return value.
        account = account or { balance = function() return 12847 end }

        local b = account.balance()
        print("balance:", b)
        print("can Lua see user_id?", type(user_id))   -- nil; private!
        return b
        """,
        see_also: ["deflua", "sandbox"]
      },
      %{
        slug: "sigil",
        title: "The `~LUA` sigil",
        chapter: :integration,
        objective: "Validate Lua at Elixir compile time and pre-compile chunks for hot paths.",
        body: """
        `~LUA"..."` parses your Lua at *Elixir compile time*. A typo
        crashes `mix compile`, not your release on a Tuesday. The `c`
        modifier emits a pre-compiled `%Lua.Chunk{}`; `Lua.eval!(lua,
        chunk)` skips the parser at runtime. Use this for repeatedly
        executed snippets and config-as-code.
        """,
        exercise:
          "Drop the closing `end` of an inner function and run. Lua.ex compiles fine here (the playground re-parses every Run), but as a `~LUA` body the same typo crashes `mix compile`.",
        elixir_source: """
        defmodule Money do
          import Lua

          # Parsed at Elixir compile time; runtime still parses.
          def discount_lua,
            do: ~LUA"return amount * (1 - pct/100)"

          # Parsed AND compiled at Elixir compile time. Re-runs skip
          # the parser entirely.
          def discount_chunk,
            do: ~LUA"return amount * (1 - pct/100)"c
        end

        lua = Lua.new() |> Lua.set!([:amount], 100) |> Lua.set!([:pct], 15)
        {[total], _} = Lua.eval!(lua, Money.discount_chunk())
        """,
        source: """
        -- The body of the ~LUA chunk above. Edit and re-run.
        -- In a real app, `amount` and `pct` come from Lua.set! first.
        amount = amount or 100
        pct    = pct    or 15
        return amount * (1 - pct / 100)
        """,
        see_also: ["host-intro", "bytecode"]
      },
      %{
        slug: "errors-host",
        title: "Errors across the boundary",
        chapter: :integration,
        expect: :runtime_error,
        objective:
          "Catch `Lua.RuntimeException` on the Elixir side. Line, source, and call stack come along.",
        body: """
        Runtime errors in Lua raise `Lua.RuntimeException` on the
        Elixir side. The exception carries the offending line, the
        source snippet, and the call stack. `try/rescue` catches it;
        `Exception.message/1` formats the pretty version you see in
        this playground.
        """,
        exercise:
          "Change `nil` to `{ missing = { field = 42 } }` and the error disappears: you get `42` back. Now toggle Bytecode and find the `get_table` op that the runtime stack points at.",
        elixir_source: """
        try do
          Lua.eval!(Lua.new(), \"\"\"
            local function deep(x) return x.missing.field end
            deep(nil)
          \"\"\")
        rescue
          e in Lua.RuntimeException ->
            IO.puts(Exception.message(e))
            {:error, e.line, e.source}
        end
        """,
        source: """
        -- Run this to see the same error the Elixir caller rescues.
        local function inner(x)
          return x.missing.field
        end

        local function middle(x)
          return inner(x)       -- error propagates up the stack
        end

        return middle(nil)
        """,
        see_also: ["errors"]
      },

      # ----- Chapter V: Under the hood -----
      %{
        slug: "bytecode",
        title: "The bytecode model",
        chapter: :internals,
        objective:
          "Read a disassembled prototype: instructions, registers, upvalues, and nested protos.",
        body: """
        The compiler lowers Lua to a stream of *register-based*
        opcodes. No labels, no PC-relative jumps. Each function
        becomes a `%Lua.Compiler.Prototype{}` with its own register
        window and upvalue descriptors. Toggle Bytecode to see the
        layout. Full reference at [`/reference/opcodes`](/reference/opcodes).
        """,
        exercise:
          "Toggle Bytecode. Count the prototypes (`function #N` headers). Find the `closure` op that builds the inner function and the `get_upvalue` op that reads `seed`.",
        source: """
        -- Two prototypes nest below. `outer` captures `seed` as an
        -- upvalue, and the inner closure captures it again. Open
        -- Bytecode and look for: load_constant, closure, get_upvalue,
        -- call, return.
        local function outer(seed)
          return function(x) return x + seed end
        end

        local add10 = outer(10)
        print(add10(5), add10(100))
        return add10(0)
        """,
        see_also: ["closures", "metatables-index"]
      },
      %{
        slug: "next-steps",
        title: "Where to go from here",
        chapter: :internals,
        objective: "Pick the next stop: playground, opcode reference, or the canonical Lua book.",
        body: """
        You've seen the language, the standard library, the host
        integration, and the bytecode pipeline. Three places to go
        next: the [Playground](/playground) for an empty editor, the
        [opcode reference](/reference/opcodes) for the VM internals,
        and [Programming in Lua](https://www.lua.org/pil/), the
        canonical reference written by the language's authors.
        """
      }
    ]
  end
end

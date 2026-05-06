# VM Performance Optimization Design Document

## Context

This document specifies two architectural changes to `lib/lua/vm/executor.ex` and
`lib/lua/vm/state.ex`. Both are motivated by the following benchmark gap:

| Implementation | ips   | avg time | memory/iter |
|---------------|-------|----------|-------------|
| C Lua         | 138x  | 7ms      | ~0 GB       |
| luerl         | 0.80  | 1.25s    | 2.45 GB     |
| **this VM**   | 0.62  | 1.60s    | 8.07 GB     |

After a first-pass fix (right-sizing register tuples, fixing O(N²) upvalue append,
converting upvalue list to tuple), the gap narrowed from 382x to 221x vs C Lua, and
from 2.58x to 1.28x vs luerl. The remaining gap has two architectural causes described
below.

**Relevant source files:**
- `lib/lua/vm/executor.ex` — 1,778 lines, the entire interpreter loop
- `lib/lua/vm/state.ex` — the `%State{}` struct and helpers
- `lib/lua/vm.ex` — the public `execute/2` entry point

---

## Why These Two Targets

### What luerl actually does

Luerl's `emul/7` function is **fully tail-recursive**. Every instruction handler ends
with a tail call to `emul`. Function calls are handled by:

1. Saving `{Is, Cont, Lvs, Env}` (current execution state) into a `#call_frame` on `Cs`
2. Tail-calling `emul` for the callee's instructions
3. When the callee returns, `do_return` pops the `#call_frame` and resumes

Control flow (`?IF`, `?WHILE`, etc.) uses an explicit **continuation list** `Cont`:
instead of recursing for a body, luerl tail-calls `emul(Body, [Rest | Cont], ...)`.
When the body exhausts its instructions, `emul([], [Rest|Cont], ...)` pops `Rest`
and continues. Everything is a tail call. The Erlang call stack stays at depth ~1
regardless of Lua call depth.

Luerl also stores line tracking info on the call stack `Cs` (as `#current_line{}`
records), not in the main state `St`. So executing a line-tracking instruction does
not modify `St` at all.

### Why this VM is slower

**Source of most remaining allocation:**

Every `source_line` instruction executes:

```elixir
# executor.ex:195-197
defp do_execute([{:source_line, line, _file} | rest], regs, upvalues, proto, state) do
  state = %{state | current_line: line}   # ← new State struct allocated
  do_execute(rest, regs, upvalues, proto, state)
end
```

With ~3–4 statements per function, this is 3–4 `State` struct allocations per Lua
function call, contributing roughly 1–2 GB of the 8.07 GB measured.

**Source of unbounded Erlang stack growth:**

Every Lua-to-Lua function call in the `:call` handler does:

```elixir
# executor.ex:524-531
{results, _callee_regs, state} =
  do_execute(
    callee_proto.instructions,
    callee_regs,
    callee_upvalues,
    callee_proto,
    state
  )
```

This is a **non-tail recursive Erlang call**. The Erlang call stack grows with Lua
call depth and holds all intermediate `regs` tuples live until unwinding. For `fib(30)`
(max depth 30), this keeps 30 Erlang frames alive simultaneously. For deeply recursive
programs this can cause stack overflow.

Additionally, the `:test` instruction makes a non-tail recursive call for its body:

```elixir
# executor.ex:208-223
case do_execute(body, regs, upvalues, proto, state) do
  {:break, regs, state} -> {:break, regs, state}
  {results, regs, state} when results != [] -> {results, regs, state}
  {_results, regs, state} -> do_execute(rest, regs, upvalues, proto, state)
end
```

This nests Erlang frames for every if/else/while block inside a function.

---

## Target A: Decouple Line Tracking from the State Struct

### Goal

Eliminate `State` struct allocations caused by `source_line` instructions. This
is ~3–4 allocations per Lua function call, contributing materially to the 8 GB figure.

### Solution

Remove `current_line` and `current_source` from the `%State{}` struct. Thread
`current_line` as a plain integer parameter to `do_execute`. This means a
`source_line` instruction only updates a local variable, not the heap.

`current_source` is always equal to `proto.source` for the currently executing
function, so it can be read directly from `proto` where needed. It does not need
to be threaded.

### Changes Required

#### 1. `lib/lua/vm/state.ex` — remove fields

```elixir
# BEFORE (state.ex:8-20)
defstruct globals: %{},
          call_stack: [],
          metatables: %{},
          upvalue_cells: %{},
          open_upvalues: %{},
          tables: %{},
          table_next_id: 0,
          userdata: %{},
          userdata_next_id: 0,
          private: %{},
          current_line: 0,       # ← remove
          current_source: nil,   # ← remove
          multi_return_count: 0

# AFTER
defstruct globals: %{},
          call_stack: [],
          metatables: %{},
          upvalue_cells: %{},
          open_upvalues: %{},
          tables: %{},
          table_next_id: 0,
          userdata: %{},
          userdata_next_id: 0,
          private: %{},
          multi_return_count: 0
```

Remove both fields from the `@type t` spec in the same file.

#### 2. `lib/lua/vm/executor.ex` — new `do_execute` signature

Add `current_line` as the **6th parameter** to every `do_execute` clause.
The public entry point `execute/5` initialises it to `0`.

```elixir
# BEFORE: execute/5 (executor.ex:21-24)
def execute(instructions, registers, upvalues, proto, state) do
  state = %{state | open_upvalues: %{}}
  do_execute(instructions, registers, upvalues, proto, state)
end

# AFTER: execute/5 — pass 0 as initial current_line
def execute(instructions, registers, upvalues, proto, state) do
  state = %{state | open_upvalues: %{}}
  do_execute(instructions, registers, upvalues, proto, state, 0)
end
```

`call_function/3` for `{:lua_closure, ...}` (executor.ex:33-65) also calls
`do_execute` directly. Update it the same way, passing `0`.

#### 3. `lib/lua/vm/executor.ex` — `source_line` clause

```elixir
# BEFORE (executor.ex:195-197)
defp do_execute([{:source_line, line, _file} | rest], regs, upvalues, proto, state) do
  state = %{state | current_line: line}
  do_execute(rest, regs, upvalues, proto, state)
end

# AFTER — no state allocation, just pass line forward
defp do_execute([{:source_line, line, _file} | rest], regs, upvalues, proto, state, _line) do
  do_execute(rest, regs, upvalues, proto, state, line)
end
```

#### 4. `lib/lua/vm/executor.ex` — all other `do_execute` clauses

Every other clause must accept and forward `current_line` unchanged. The mechanical
change for a typical clause is:

```elixir
# BEFORE
defp do_execute([{:load_constant, dest, value} | rest], regs, upvalues, proto, state) do
  regs = put_elem(regs, dest, value)
  do_execute(rest, regs, upvalues, proto, state)
end

# AFTER
defp do_execute([{:load_constant, dest, value} | rest], regs, upvalues, proto, state, line) do
  regs = put_elem(regs, dest, value)
  do_execute(rest, regs, upvalues, proto, state, line)
end
```

This is a mechanical change to all ~35 clauses. Every `do_execute(rest, regs, upvalues, proto, state)` tail call becomes `do_execute(rest, regs, upvalues, proto, state, line)`.

#### 5. `lib/lua/vm/executor.ex` — call frame construction (executor.ex:492-496)

```elixir
# BEFORE
frame = %{
  source: proto.source,
  line: Map.get(state, :current_line, 0),
  name: nil
}

# AFTER — use the threaded parameter
frame = %{
  source: proto.source,
  line: current_line,
  name: nil
}
```

#### 6. `lib/lua/vm/executor.ex` — error-raising sites

Three sites pass `call_stack: state.call_stack` and `line: Map.get(state, :current_line)`.
Replace the line reads with the `current_line` parameter:

```elixir
# executor.ex:552-558 — call_nil TypeError
raise TypeError,
  value: "attempt to call a nil value",
  source: proto.source,
  call_stack: state.call_stack,
  line: current_line,        # ← was: Map.get(state, :current_line)
  error_kind: :call_nil,
  value_type: nil

# executor.ex:563-570 and executor.ex:576-583 — call_non_function TypeErrors
# Same substitution: line: current_line
```

#### 7. `lib/lua/vm.ex` — top-level `execute/2`

```elixir
# BEFORE (vm.ex:21)
registers = Tuple.duplicate(nil, 256)

# AFTER — already fixed in prior pass, confirm it reads proto.max_registers + 1
registers = Tuple.duplicate(nil, proto.max_registers + 1)
```

No change to the call to `Executor.execute/5` needed — that already passes `proto`.

#### 8. Any external callers reading `state.current_line` or `state.current_source`

Search the codebase for these field accesses:

```
grep -r "current_line\|current_source" lib/
```

Update them to use context-appropriate alternatives. In error formatters, accept
`current_line` as an explicit argument rather than reading from state.

---

## Target B: Fully Tail-Recursive Executor (CPS Transformation)

### Goal

Eliminate Erlang call stack growth for Lua function calls, and eliminate the
non-tail recursive execution of `do_execute` for control-flow bodies (`:test`,
`:while_loop`, etc.). After this change, Erlang call stack depth is O(1) regardless
of Lua recursion depth or control-flow nesting depth.

### Why Partial CPS Is Insufficient

A tempting approach is to convert only the `:call` instruction to CPS while leaving
`:test` bodies recursive. This fails because:

If `:call` becomes a CPS tail-call and `:test` bodies are still executed via a
non-tail recursive `do_execute(body, ...)`, then a `return` inside a body would
trigger a CPS frame pop to the wrong place — the `:test` handler's `case` expression
would never receive a result.

**The entire `do_execute` dispatch must become tail-recursive.** This is exactly
what luerl does with its `emul` function.

### New Execution Model

The new `do_execute` takes two additional parameters:

```elixir
defp do_execute(instructions, registers, upvalues, proto, state, cont, frames, line)
```

| Parameter      | Type                | Purpose |
|----------------|---------------------|---------|
| `instructions` | `[instruction()]`   | Current instruction list |
| `registers`    | `tuple()`           | Register file for current function |
| `upvalues`     | `tuple()`           | Current function's captured upvalues |
| `proto`        | `Prototype.t()`     | Current function prototype |
| `state`        | `State.t()`         | VM heap state (globals, tables, etc.) |
| `cont`         | `[cont_entry()]`    | Continuation stack for control flow |
| `frames`       | `[frame()]`         | Call frame stack for function returns |
| `line`         | `non_neg_integer()` | Current source line (from Target A) |

**Continuation stack (`cont`):**
A list of continuation entries consumed when the current instruction list is
exhausted. Two kinds of entry exist:

```elixir
# Normal continuation: instructions to execute next
[instruction()]

# Loop boundary marker: signals a breakable loop boundary
{:loop_exit, exit_instructions :: [instruction()]}
```

When `instructions` becomes `[]`, the executor inspects `cont`:

- If `cont = []` and `frames = []` → top-level return, done.
- If `cont = []` and `frames = [frame | rest]` → function returned, call `do_frame_return`.
- If `cont = [next_is | rest_cont]` → tail-call `do_execute(next_is, ...)`.
- If `cont = [{:loop_exit, _} | rest_cont]` → fell off the end of a loop body normally; consume the marker and continue with `rest_cont`.

**Call frame stack (`frames`):**
Each entry captures everything needed to resume the caller after a Lua function call
returns:

```elixir
%{
  rest:            [instruction()],   # caller instructions after the :call
  cont:            [cont_entry()],    # caller's continuation stack
  regs:            tuple(),           # caller's register file
  upvalues:        tuple(),           # caller's upvalues
  proto:           Prototype.t(),     # caller's prototype
  base:            non_neg_integer(), # base register for result placement
  result_count:    integer(),         # -1, -2, or n (same semantics as today)
  open_upvalues:   map()              # caller's saved open_upvalues
}
```

### Instruction-by-Instruction Changes

#### Instructions exhausted (implicit nil return)

```elixir
# BEFORE
defp do_execute([], regs, _upvalues, _proto, state) do
  {[], regs, state}
end

# AFTER
defp do_execute([], regs, upvalues, proto, state, cont, frames, line) do
  case cont do
    [next_is | rest_cont] when is_list(next_is) ->
      do_execute(next_is, regs, upvalues, proto, state, rest_cont, frames, line)

    [{:loop_exit, _exit_is} | rest_cont] ->
      # Consumed a loop boundary marker — fell off end of loop body normally
      do_execute([], regs, upvalues, proto, state, rest_cont, frames, line)

    [] ->
      case frames do
        [] ->
          {[], regs, state}

        [frame | rest_frames] ->
          do_frame_return([], regs, state, frame, rest_frames, line)
      end
  end
end
```

#### `:return` instructions

Extract the result-collection logic into a private helper, then call `do_frame_return`:

```elixir
# AFTER — both :return variants delegate to do_frame_return
defp do_execute([{:return, base, count} | _], regs, _upvalues, _proto, state, _cont, frames, line) do
  results = collect_return_values(regs, base, count, state)
  case frames do
    []                    -> {results, regs, state}
    [frame | rest_frames] -> do_frame_return(results, regs, state, frame, rest_frames, line)
  end
end

defp do_execute([{:return, base, {:multi_return, fixed}} | _], regs, _upvalues, _proto, state, _cont, frames, line) do
  total = fixed + state.multi_return_count
  results = if total > 0, do: for(i <- 0..(total - 1), do: elem(regs, base + i)), else: []
  case frames do
    []                    -> {results, regs, state}
    [frame | rest_frames] -> do_frame_return(results, regs, state, frame, rest_frames, line)
  end
end
```

#### `do_frame_return/6` — new private function

This handles returning from a Lua function call by restoring the caller's context:

```elixir
defp do_frame_return(results, _callee_regs, state, frame, rest_frames, line) do
  %{
    rest: rest,
    cont: caller_cont,
    regs: caller_regs,
    upvalues: caller_upvalues,
    proto: caller_proto,
    base: base,
    result_count: result_count,
    open_upvalues: saved_open_upvalues
  } = frame

  # Pop the VM call stack (for error reporting) and restore open upvalues
  state = %{state |
    call_stack: tl(state.call_stack),
    open_upvalues: saved_open_upvalues
  }

  case result_count do
    -1 ->
      # Return-position call: pass results through to the caller's caller.
      # The `rest` of this frame's instructions is irrelevant (there is nothing
      # after `return f()` that matters). This is effectively TCO.
      case rest_frames do
        [] ->
          {results, caller_regs, state}
        [outer_frame | outer_rest_frames] ->
          do_frame_return(results, caller_regs, state, outer_frame, outer_rest_frames, line)
      end

    -2 ->
      # Multi-return expansion: place all results into caller regs from base
      results_list = List.wrap(results)
      caller_regs =
        results_list
        |> Enum.with_index()
        |> Enum.reduce(caller_regs, fn {val, i}, regs -> put_elem(regs, base + i, val) end)
      state = %{state | multi_return_count: length(results_list)}
      do_execute(rest, caller_regs, caller_upvalues, caller_proto, state, caller_cont, rest_frames, line)

    n when n > 0 ->
      # Fixed count: place first n results into caller regs from base
      results_list = List.wrap(results)
      caller_regs =
        Enum.reduce(0..(n - 1), caller_regs, fn i, regs ->
          put_elem(regs, base + i, Enum.at(results_list, i))
        end)
      do_execute(rest, caller_regs, caller_upvalues, caller_proto, state, caller_cont, rest_frames, line)

    0 ->
      # No results captured
      do_execute(rest, caller_regs, caller_upvalues, caller_proto, state, caller_cont, rest_frames, line)
  end
end
```

#### `:call` instruction — Lua closure branch

```elixir
# AFTER — push frame, tail-call into callee
{:lua_closure, callee_proto, callee_upvalues} ->
  frame = %{
    rest:          rest,
    cont:          upvalues_cont,    # see note below
    regs:          regs,
    upvalues:      upvalues,
    proto:         proto,
    base:          base,
    result_count:  result_count,
    open_upvalues: state.open_upvalues
  }

  call_info = %{source: proto.source, line: line, name: nil}
  state = %{state |
    call_stack:   [call_info | state.call_stack],
    open_upvalues: %{}
  }

  callee_regs =
    Tuple.duplicate(nil, max(callee_proto.max_registers, callee_proto.param_count) + 4)

  callee_regs = copy_args_to_regs(callee_regs, args, callee_proto.param_count)

  callee_proto =
    if callee_proto.is_vararg,
      do: %{callee_proto | varargs: Enum.drop(args, callee_proto.param_count)},
      else: callee_proto

  # TAIL CALL — Erlang stack does not grow
  do_execute(callee_proto.instructions, callee_regs, callee_upvalues, callee_proto,
             state, [], [frame | frames], line)
```

> **Note on `cont` in the frame:** The saved `cont` in the frame is the **caller's**
> continuation stack at the point of the call. This must be captured before the
> `do_execute` tail call. In the full implementation, this is `cont` (the current
> continuation parameter), not a new value.

#### `:test` instruction

```elixir
# BEFORE
defp do_execute([{:test, reg, then_body, else_body} | rest], regs, upvalues, proto, state) do
  body = if Value.truthy?(elem(regs, reg)), do: then_body, else: else_body
  case do_execute(body, regs, upvalues, proto, state) do
    {:break, regs, state} -> {:break, regs, state}
    {results, regs, state} when results != [] -> {results, regs, state}
    {_results, regs, state} -> do_execute(rest, regs, upvalues, proto, state)
  end
end

# AFTER — push `rest` as continuation, tail-call into body
defp do_execute([{:test, reg, then_body, else_body} | rest], regs, upvalues, proto, state, cont, frames, line) do
  body = if Value.truthy?(elem(regs, reg)), do: then_body, else: else_body
  do_execute(body, regs, upvalues, proto, state, [rest | cont], frames, line)
end
```

There is no longer a need to pattern-match on the result of the body execution:
- If the body contains a `return`, `do_frame_return` handles it (pops `frames`).
- If the body contains a `break`, the `:break` handler handles it (see below).
- If the body ends normally (instructions exhausted), `do_execute([], ...)` pops
  `rest` from `cont` and continues — which is exactly `do_execute(rest, ...)`.

#### `:test_and` / `:test_or` instructions

```elixir
# BEFORE
do_execute(rest_body ++ rest, regs, upvalues, proto, state)

# AFTER — push rest as continuation instead of concatenating lists
defp do_execute([{:test_and, dest, source, rest_body} | rest], regs, upvalues, proto, state, cont, frames, line) do
  value = elem(regs, source)
  if Value.truthy?(value) do
    do_execute(rest_body, regs, upvalues, proto, state, [rest | cont], frames, line)
  else
    regs = put_elem(regs, dest, value)
    do_execute(rest, regs, upvalues, proto, state, cont, frames, line)
  end
end
```

This also eliminates the O(N) `++` list concatenation that existed in these handlers.

#### Loop instructions — `:while_loop`, `:repeat_loop`, `:numeric_for`, `:generic_for`

These are already iterative (they self-tail-call). The only change needed is:

1. Push a `{:loop_exit, rest}` marker onto `cont` when **entering** a loop, so that
   `:break` can find it.
2. When the loop condition fails (loop terminates normally), call
   `do_execute(rest, ...)` which continues past the loop — same as today but with
   `cont` and `frames` threaded.

Example for `:while_loop`:

```elixir
# AFTER
defp do_execute([{:while_loop, cond_body, test_reg, loop_body} | rest], regs, upvalues, proto, state, cont, frames, line) do
  # Execute condition inline (tail call) with a continuation that checks the test reg
  # and loops or exits. Use {:loop_exit, rest} to mark the break target.
  loop_cont = [{:loop_exit, rest} | cont]
  do_execute(cond_body, regs, upvalues, proto, state,
             [{:while_check, test_reg, loop_body, rest, loop_cont} | loop_cont],
             frames, line)
end
```

The `:while_check` continuation is a new synthetic entry type that is handled when
instructions are exhausted, analogous to how luerl's `?WHILE_LOOP` instruction works.

Alternatively, keep while/for loops as they are (Erlang-iterative within a function,
not recursively across functions) and only make the `{:loop_exit, rest}` marker
visible for break. This is simpler and acceptable because loop depth is bounded by the
static nesting level in source code, not by runtime call count.

#### `:break` instruction

```elixir
# BEFORE
defp do_execute([:break | _rest], regs, _upvalues, _proto, state) do
  {:break, regs, state}
end

# AFTER — scan cont for the nearest {:loop_exit, exit_is} marker
defp do_execute([:break | _rest], regs, upvalues, proto, state, cont, frames, line) do
  {exit_is, rest_cont} = find_loop_exit(cont)
  do_execute(exit_is, regs, upvalues, proto, state, rest_cont, frames, line)
end

defp find_loop_exit([{:loop_exit, exit_is} | rest_cont]), do: {exit_is, rest_cont}
defp find_loop_exit([_ | rest_cont]), do: find_loop_exit(rest_cont)
defp find_loop_exit([]), do: raise(Lua.VM.InternalError, value: "break outside loop")
```

The `{:break, regs, state}` return tuple is **eliminated entirely**. All callers
that pattern-match on it (`:while_loop`, `:numeric_for`, `:generic_for` body handling)
no longer need it, because breaks are handled directly through the continuation stack.

#### `:goto` instruction

```elixir
# AFTER — same logic, thread new params
defp do_execute([{:goto, label} | rest], regs, upvalues, proto, state, cont, frames, line) do
  case find_label(rest, label) do
    {:found, after_label} ->
      do_execute(after_label, regs, upvalues, proto, state, cont, frames, line)
    :not_found ->
      raise InternalError, value: "goto target '#{label}' not found"
  end
end
```

For a forward goto, this searches `rest`. For a backward goto (to a label earlier in
the function), the current search will fail. If backward gotos are used anywhere in
the test suite, the label search must be expanded to scan the full `proto.instructions`
list. Check the test suite for goto-backward cases.

#### All other instructions

Every other clause (`load_constant`, `get_global`, `set_global`, `move`, `add`,
`subtract`, ...) requires only mechanical addition of `cont, frames, line` to the
parameter list and all recursive `do_execute` tail calls:

```elixir
# Pattern for every simple instruction
defp do_execute([{:some_op, ...} | rest], regs, upvalues, proto, state, cont, frames, line) do
  # ... operation logic unchanged ...
  do_execute(rest, regs, upvalues, proto, state, cont, frames, line)
end
```

### Entry Points

#### `Lua.VM.execute/2` (`lib/lua/vm.ex`)

```elixir
# AFTER
def execute(%Prototype{} = proto, state \\ State.new()) do
  registers = Tuple.duplicate(nil, proto.max_registers + 1)
  state = %{state | open_upvalues: %{}}

  {results, _final_regs, final_state} =
    Executor.execute(proto.instructions, registers, [], proto, state)

  {:ok, results, final_state}
end
```

No change needed here — `Executor.execute/5` is the public boundary.

#### `Executor.execute/5` (`lib/lua/vm/executor.ex:21-24`)

```elixir
# AFTER
def execute(instructions, registers, upvalues, proto, state) do
  state = %{state | open_upvalues: %{}}
  do_execute(instructions, registers, upvalues, proto, state, [], [], 0)
end
```

#### `Executor.call_function/3` (used by pcall/xpcall, `executor.ex:33-65`)

```elixir
# AFTER — {lua_closure, ...} branch
def call_function({:lua_closure, callee_proto, callee_upvalues}, args, state) do
  callee_regs =
    Tuple.duplicate(nil, max(callee_proto.max_registers, callee_proto.param_count) + 4)

  callee_regs = copy_args_to_regs(callee_regs, args, callee_proto.param_count)

  callee_proto =
    if callee_proto.is_vararg,
      do: %{callee_proto | varargs: Enum.drop(args, callee_proto.param_count)},
      else: callee_proto

  saved_open_upvalues = state.open_upvalues
  state = %{state | open_upvalues: %{}}

  # Empty cont and frames — standalone invocation
  {results, _regs, state} =
    do_execute(callee_proto.instructions, callee_regs, callee_upvalues, callee_proto,
               state, [], [], 0)

  state = %{state | open_upvalues: saved_open_upvalues}
  {results, state}
end
```

### Native Function Calls

Native functions (`{:native_func, fun}`) are synchronous and do not enter
`do_execute`. They are called inline within the `:call` handler and their results
are placed into registers before continuing. No frame is pushed. This is identical
to the current behaviour.

```elixir
# AFTER — native branch of :call handler
{:native_func, fun} ->
  {results, state} =
    case fun.(args, state) do
      {r, %State{} = s} when is_list(r) -> {r, s}
      {r, %State{} = s}                 -> {List.wrap(r), s}
    end

  regs = place_call_results(regs, results, base, result_count, state)
  do_execute(rest, regs, upvalues, proto, state, cont, frames, line)
```

### Error Handling

Errors are still raised as Elixir exceptions. Since all execution is now tail-calls,
the Erlang stack when an exception is raised will be shallow (~3–5 frames rather than
depth-of-recursion). This is strictly better for error messages.

The `call_stack` field of `State` continues to track the Lua-level call stack for
error reporting. Frames are still pushed on Lua function entry and popped on return
— the difference is that push/pop now happens via `do_frame_return` rather than via
Erlang call/return.

---

## Sequencing

**Implement both targets together in a single PR.**

Target A adds a 6th parameter (`line`) to `do_execute`.
Target B adds 7th and 8th parameters (`cont`, `frames`).

Doing them separately means touching every `do_execute` clause twice. The combined
final signature is:

```elixir
defp do_execute(instructions, registers, upvalues, proto, state, cont, frames, line)
```

**Recommended implementation order:**

1. Add `cont` and `frames` parameters (Target B mechanical changes — all clauses)
2. Remove `{:break, regs, state}` return type; convert `:break` to use cont
3. Convert `:test` to use continuation
4. Convert `:test_and` / `:test_or` to use continuation (eliminates `++` too)
5. Convert `:call` to push frame and tail-call
6. Implement `do_frame_return/6`
7. Add `line` parameter and remove from State (Target A)
8. Run full test suite

---

## Testing Checklist

Run after every step:

```bash
mix test
mix test test/lua/vm/executor_test.exs   # if it exists
mix test --only regression
```

Specific scenarios to verify after full implementation:

- [ ] `fib(10)` returns correct result
- [ ] Nested function calls 10 levels deep return correctly
- [ ] `return f()` in tail position (result_count == -1) returns correct values
- [ ] `break` inside nested `for` and `while` exits the correct loop
- [ ] `break` inside an `if` inside a `while` exits the `while`
- [ ] `goto` forward (to label after current position) works
- [ ] `pcall` catching a runtime error from a nested function
- [ ] `pcall` with a deeply recursive function that raises
- [ ] Multi-return values (`return a, b, c`) work correctly
- [ ] Vararg (`...`) functions work correctly
- [ ] Closures capturing upvalues from enclosing function work
- [ ] Memory: run `mix run benchmarks/fibonacci.exs` and confirm < 2.45 GB
  (the luerl figure — we should be roughly equivalent)

---

## Expected Outcome

After both targets are implemented:

| Metric | Current | Expected |
|--------|---------|----------|
| Memory per fib(30) | 8.07 GB | < 2.5 GB |
| Erlang stack depth | O(recursion depth) | O(1) |
| State copies per Lua call | ~6–7 | ~2–3 (call stack push/pop only) |
| Speed vs luerl | 1.28x slower | ~1.0x (roughly equivalent) |

The remaining gap with C Lua (~140x) is fundamental to the BEAM vs native code and
cannot be closed without C NIFs or a JIT layer.

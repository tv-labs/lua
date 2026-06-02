# Security and sandboxing

`Lua` is designed to run untrusted scripts, but running untrusted code
safely takes more than calling `Lua.eval!/2`. There are three layers to
think about, from "what a script is allowed to *do*" down to "how much it
is allowed to *consume*":

1. **Capability sandboxing** — which standard-library functions the
   script can call (filesystem, OS, module loading, …).
2. **Resource limits** — bounds on a single script's allocations and
   recursion, enforced inside the VM.
3. **Host-level isolation** — wall-clock time and total memory, which the
   VM cannot enforce on its own and which are *your* responsibility.

This guide covers all three.

## Capability sandboxing

### The default deny-list

`Lua.new/1` installs a sandbox by default. A sandboxed path is replaced
with a function that raises when called, so the script can still *refer*
to it but cannot *use* it. The defaults block the dangerous corners of
the standard library:

* **Filesystem / IO** — the whole `io` table (`io.open`, `io.read`,
  `io.write`, `io.lines`, `io.popen`, …) and `file`
* **Operating system** — `os.execute`, `os.exit`, `os.getenv`,
  `os.remove`, `os.rename`, `os.tmpname`
* **Code loading** — `package`, `require`, `load`, `loadfile`,
  `loadstring`, `dofile`

Everything else — `string`, `table`, `math`, `utf8`, the `debug`
library, metatables, coroutity-free control flow — remains available.

```elixir
# os.exit is sandboxed by default
{[false, message], _} =
  Lua.eval!(Lua.new(), "return pcall(os.exit)")

message =~ "sandboxed"
#=> true
```

### Adding to the sandbox

Pass `:sandboxed` to replace the default list with your own set of paths.
This is an *allow-by-default* model: anything not listed stays callable.

```elixir
# Block string.rep specifically, on top of nothing else
lua = Lua.new(sandboxed: [[:string, :rep]])
```

### Removing from the sandbox

If you want the defaults *minus* a few entries, use `:exclude` to punch
holes in the default deny-list rather than re-listing everything.

```elixir
# Keep all the defaults, but allow `require`
lua = Lua.new(exclude: [[:require], [:package]])
```

To disable capability sandboxing entirely (for trusted code only), pass
an empty list:

```elixir
lua = Lua.new(sandboxed: [])
```

### Sandboxing a single path

`Lua.sandbox/2` sandboxes one path on an existing VM, which is handy when
building a configuration up in steps:

```elixir
lua =
  Lua.new(sandboxed: [])
  |> Lua.sandbox([:os, :exit])
  |> Lua.sandbox([:os, :execute])
```

## Resource limits (always on)

Several standard-library functions take a size or count argument that an
attacker can inflate to force a huge allocation — the classic
`string.rep("x", 1e15)` "allocate until the host dies" attack. `Lua`
computes the resulting size *before* allocating and raises a catchable
error when it would be unreasonable, so the attempt fails in microseconds
instead of exhausting memory.

These guards are always on and need no configuration. They cover:

| Operation | Guard | Error (catchable with `pcall`) |
| :-------- | :---- | :----------------------------- |
| `string.rep`, the `..` operator | result larger than ~256 MiB | `resulting string too large` |
| `string.format` width/precision | field wider than 99 | `invalid conversion` |
| `table.unpack` | more than 10M results | `too many results to unpack` |
| `table.concat`, `table.move` | range wider than 10M | `range too large` |
| `load` (when enabled) | reader returns > ~256 MiB total | `resulting string too large` |

```elixir
{[false, message], _} =
  Lua.eval!(Lua.new(), ~s|return pcall(string.rep, "x", 1e15)|)

message =~ "resulting string too large"
#=> true
```

Because these surface as ordinary Lua errors, a script can even recover
from them with `pcall`.

## Call depth

By default the VM places no limit on call depth, so deeply recursive or
runaway-recursive scripts can grow the host process stack until it
crashes. Set `:max_call_depth` to bound it; exceeding the limit raises a
catchable `"stack overflow"`:

```elixir
lua = Lua.new(max_call_depth: 200)

{[false, message], _} =
  Lua.eval!(lua, "local function f() return f() end return pcall(f)")

message =~ "stack overflow"
#=> true
```

> #### Tail calls count {: .info}
> This VM does not implement tail-call optimization, so a call in tail
> position (`return f(x)`) consumes a frame like any other. A finite
> `:max_call_depth` therefore also bounds tail recursion — including
> loops that PUC-Lua would run forever. Leave the default `:infinity`
> if you rely on unbounded tail recursion.

## Limiting CPU time and total memory

The VM has **no internal wall-clock timeout** and does **not** cap the
host process's total memory. A script can still spin forever
(`while true do end`) or accumulate memory in ways the per-operation
guards above don't catch (for example, growing a table in a loop). These
limits have to be enforced by the BEAM, around the call.

Run untrusted scripts in a **separate, monitored process** with both a
timeout and a heap ceiling. The key is to keep the wall-clock timeout and
the memory kill on **separate `receive` arms** so the two failure modes
stay distinguishable:

```elixir
defmodule SafeLua do
  # ~64 MB, in heap words (8 bytes/word on a 64-bit VM).
  @heap_words 8_000_000
  @timeout_ms 1_000

  def run(lua, source) do
    parent = self()

    # Trap exits so the worker dying — whether it finishes, is killed by
    # the memory ceiling, or we tear it down on timeout — arrives as a
    # message instead of crashing the caller. Restore the flag afterwards.
    prev_trap = Process.flag(:trap_exit, true)

    worker =
      spawn_link(fn ->
        # CRITICAL: include_shared_binaries: true. Without it, max_heap_size
        # counts only the process heap, NOT off-heap reference-counted
        # binaries (>64 bytes) — so a binary bomb would slip past the limit.
        # This option requires OTP 27+.
        Process.flag(:max_heap_size, %{
          size: @heap_words,
          kill: true,
          error_logger: false,
          include_shared_binaries: true
        })

        send(parent, {:result, Lua.eval!(lua, source)})
      end)

    try do
      receive do
        {:result, {result, _lua}} ->
          {:ok, result}

        # Worker hit the memory ceiling: max_heap_size kills it with
        # `:killed`, the only abnormal exit we attribute to the limit.
        {:EXIT, ^worker, :killed} ->
          {:error, :memory_limit}

        # Any other abnormal worker exit is an unrelated crash.
        {:EXIT, ^worker, reason} ->
          {:error, reason}
      after
        @timeout_ms ->
          Process.exit(worker, :kill)
          {:error, :timeout}
      end
    after
      Process.flag(:trap_exit, prev_trap)
    end
  end
end
```

Two details make this robust:

* **Separate `receive` arms for timeout and `:killed`.** A wall-clock
  timeout fires the `after` clause and reports `:timeout`; a memory kill
  arrives as `{:EXIT, worker, :killed}` and reports `:memory_limit`. The
  tempting `Task.yield(task, @timeout_ms) || Task.shutdown(task,
  :brutal_kill)` shape collapses the two: `brutal_kill` on a timeout also
  exits the worker with `:killed`, so a CPU-bound infinite loop would be
  mislabeled a memory limit.
* **`trap_exit` + `spawn_link`** turns the worker's exit into a message
  the caller can match on, instead of letting the kill propagate and
  crash the caller. Restoring the previous `trap_exit` flag in the
  `after` block leaves the caller's state untouched.
* **`include_shared_binaries: true`** is what makes the memory ceiling
  actually work for the binary-allocation attacks. Large Lua strings
  become off-heap BEAM binaries; without this flag they are not counted
  toward `max_heap_size` and the kill never fires.

> #### max_heap_size is a backstop, not a precise fence {: .warning}
> The heap limit is checked at garbage-collection time, so a single
> enormous allocation can momentarily exceed it before the kill lands.
> The VM's built-in per-operation guards (above) are the deterministic
> defense; `max_heap_size` catches the accumulation cases they can't see.

## Putting it together

A typical configuration for running untrusted scripts combines all three
layers — the default sandbox, a call-depth bound, and a process wrapper
for time and memory:

```elixir
lua = Lua.new(max_call_depth: 200)

SafeLua.run(lua, untrusted_source)
```

The default sandbox blocks the OS/filesystem/loader surface, the built-in
guards turn allocation bombs into catchable errors, `:max_call_depth`
bounds recursion, and `SafeLua.run/2` bounds wall-clock time and total
memory — with the host process surviving every one of those failures.

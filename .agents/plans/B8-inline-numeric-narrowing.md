---
id: B8
title: Inline `to_signed_int64/1` for the in-range fast path
issue: null
pr: 227
branch: perf/inline-numeric-narrowing
base: main
status: merged
direction: B
unlocks:
  - small but free win on all integer-arithmetic workloads
---

## Goal

`Lua.VM.Numeric.to_signed_int64/1` is called on every integer arithmetic
result to wrap into signed 64-bit per Lua 5.3 §3.4.1. In the fib(22)
profile it accounts for **3.3%** of total time (85,968 calls).

For the overwhelming common case where the result is already in
`[-2^63, 2^63 - 1]`, the masking and conditional subtraction are
wasted work — the input passes through unchanged. Adding a guarded
fast-path clause that returns the input as-is when it's already in
range eliminates the cost on that branch entirely.

## Why now

This is a small, self-contained, mechanical change. It has minimal
risk and no architectural overlap with B4-B7. It can ship before or
after any of them. Useful to have in the trunk so subsequent
benchmarks aren't muddied by this overhead.

## Out of scope

- Bypassing `to_signed_int64/1` calls entirely (the call sites still
  call it; this plan only makes the function itself faster on the
  common path).
- Changing the Lua wrap-around semantics. Behavior is identical.
- Turning the call sites into inline arithmetic at the executor level.
  That would tangle with B5 and is not the right place to do it.

## Success criteria

- [ ] `Lua.VM.Numeric.to_signed_int64/1` has a guard-clause fast path
      for inputs already in the signed 64-bit range.
- [ ] `Lua.VM.Numeric.signed?/1` is `@compile {:inline, signed?: 1}`
      so the fast-path guard is cheap.
- [ ] `mix test` passes.
- [ ] Profile after merge: `Numeric.to_signed_int64` self-time drops
      below 1.5% on fib(22).
- [ ] Microbenchmarks: fib(25) median improves by **3%+ stretch, 1%
      floor**.
- [ ] No regression on overflow-heavy tests (the wrap-around path).

## Implementation notes

### Current implementation

```elixir
@uint64_modulus 0x10000000000000000
@uint64_mask    0xFFFFFFFFFFFFFFFF
@sign_bit       0x8000000000000000

@max_int  0x7FFFFFFFFFFFFFFF
@min_int -0x8000000000000000

def to_signed_int64(n) when is_integer(n) do
  masked = band(n, @uint64_mask)
  if masked >= @sign_bit, do: masked - @uint64_modulus, else: masked
end

def signed?(n) when is_integer(n), do: n >= @min_int and n <= @max_int
```

Every call does a `band`, a comparison, and a branch — even for `n = 7`.

### Proposed implementation

```elixir
def to_signed_int64(n) when is_integer(n) and n >= @min_int and n <= @max_int do
  n
end

def to_signed_int64(n) when is_integer(n) do
  masked = band(n, @uint64_mask)
  if masked >= @sign_bit, do: masked - @uint64_modulus, else: masked
end
```

The BEAM compiles guards into native instruction sequences; the
in-range check is essentially two compare-and-branches with no
function call overhead. The slow path stays exactly as today.

### Compile-time inlining

```elixir
@compile {:inline, signed?: 1, to_signed_int64: 1}
```

`to_signed_int64/1` is small enough to inline at call sites; the BEAM
can then see the guards and short-circuit hot callers.

This is one of the few places where `@compile {:inline, ...}` is
clearly worth it — the function is called inside the dispatch loop on
every arithmetic op.

### Files

- `lib/lua/vm/numeric.ex` — add the guard clause, add `@compile`.

### Test coverage

The existing tests in `test/lua/vm/numeric_test.exs` (and the doctests
in the module) cover both branches. Adding the guard splits the
existing `to_signed_int64/1` clause; verify the doctests still pass.

If no module test exists, the integer-overflow tests in
`test/lua/vm/integration_test.exs` (or wherever the §3.4.1 wrap-around
asserts live) are the regression net.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix test --only lua53

# Confirm overflow path is exercised
mix run -e '
lua = Lua.new()
{[result], _} = Lua.eval!(lua, "return 9223372036854775807 + 1")
IO.inspect(result, label: "max_int + 1 should wrap to min_int")
^ -9223372036854775808 = result
'

# Profile to confirm Numeric drop
mix profile.tprof -e '
fib = "function fib(n) if n < 2 then return n end return fib(n-1) + fib(n-2) end"
lua = Lua.new()
{_, lua} = Lua.eval!(lua, fib)
{chunk, _} = Lua.load_chunk!(lua, "return fib(22)")
Lua.eval!(lua, chunk)
'
```

## Risks

- **Almost none.** The behavior is bit-for-bit identical; the fast
  path is purely a guard-tested return-as-is.
- **`@compile {:inline, ...}` can cause subtle behavior with dialyzer
  type inference**, but for a function with this signature
  (integer in, integer out) it's safe. Confirm `mix dialyzer` (if the
  CI runs it) doesn't gain new warnings.

## Discoveries

- `@compile {:inline, ...}` only inlines within the same module. Cross-module
  callers in `Lua.VM.Executor` and `Lua.VM.Value` still trip a function
  boundary on every call. tprof call count stayed at 85,968 before/after,
  confirming no inlining happened at the dispatch sites. This caps the
  realized win below the plan's stretch target — the gain comes entirely
  from the guard short-circuit, not from inlining at call sites.
- Profile self-time on fib(22) moved 3.82% → 3.38%, a 12% relative drop
  on the function itself. Plan's stretch target of < 1.5% was not hit
  because it implicitly required cross-module inlining.
- Wall-clock win on fib(30) is real: lua (chunk) 873.4ms → 844.8ms
  (**-3.3%**), well outside the ±0.5% deviation band. luerl (control)
  did not move. The plan's 3% stretch floor on fib was met.

## What changed

- `lib/lua/vm/numeric.ex` — added in-range guard clause to
  `to_signed_int64/1`; added `@compile {:inline, signed?: 1,
  to_signed_int64: 1}`.

PR: #227

Suite delta: 1692 tests passing → 1692 tests passing (no regression).
lua53 suite: 29 tests, 0 failures (matches main).

Benchmarks (fib(30), 10s benchee, 2s warmup):

| benchmark    | baseline    | after        | delta  |
|--------------|-------------|--------------|--------|
| lua (chunk)  | 873.36 ms   | 844.76 ms    | -3.3%  |
| lua (eval)   | 876.74 ms   | 852.21 ms    | -2.8%  |
| luerl (ctl)  | 730.87 ms   | 731.78 ms    | noise  |

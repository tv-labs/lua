---
id: A40
title: Thread name hints into arithmetic & bitwise type errors
issue: 252
pr: 270
branch: errors/arith-bitwise-hints
base: main
status: merged
direction: A
unlocks:
  - math.lua (reason narrowed)
  - sort.lua (reason narrowed)
  - errors.lua (reason narrowed)
  - strings.lua (reason narrowed)
---

## Goal

Append PUC-Lua-style `(global 'X')` / `(local 'X')` / `(upvalue 'X')` /
`(field 'X')` hints to arithmetic and bitwise type errors and to the
"number has no integer representation" error. This closes the
remaining half of #252 — the wording already aligns; only the trailing
hint suffix is missing.

## Out of scope

- Hints on `:concatenate` errors (separate raise path, much smaller
  unlock for the suite).
- Hints on `:length`-on-non-string-table errors.
- Hints on metamethod-dispatch failures (`__add` value not callable).
- Audit of `bad argument #N to 'X' (T expected, got T)` wording —
  the templates already match PUC-Lua. If a divergence surfaces
  during testing, open a follow-up.
- Field-hint extraction across `:move` chains. We hint only when the
  failing operand is *directly* a variable/property reference in the
  AST. This matches PUC-Lua, which also tracks at the call site.

## Success criteria

- [ ] `mix test` passes with no regressions (baseline: 1955 passed,
      25 skipped).
- [ ] New pin tests in `test/lua/vm/error_format_test.exs` for each
      of `{:global, :local, :upvalue, :field}` × `{arithmetic,
      bitwise, integer-representation}`.
- [ ] At least one of `math.lua`, `sort.lua`, `errors.lua`,
      `strings.lua` either passes fully or has its `:all` skip
      narrowed to a smaller line range.
- [ ] `mix dialyzer` — no new errors.
- [ ] `mix format --check-formatted`.

## Implementation notes

### Approach: bake hints into the instruction tuple at codegen time

This mirrors how `:get_field`, `:set_field`, `:call`, and `:self`
already carry hints (`lib/lua/compiler/instruction.ex`). The codegen
has a working `name_hint/2` resolver
(`lib/lua/compiler/codegen.ex:1641-1659`) that turns an `Expr.Var` or
`Expr.Property` AST node into `{:global|:local|:upvalue|:field, name}`.
The executor has `format_target_hint/1`
(`lib/lua/vm/executor.ex:1974-1991`) that renders those tuples into
` (field 'X')` suffixes.

The work is to:

1. Resolve the operand AST → hint tuple at codegen time and store it
   in the instruction tuple alongside the register indices.
2. Match the new tuple shape in the executor; on the failure path,
   forward the hint of the *failing* operand to the raise helper.
3. Append the formatted hint to the error message.

### Files to modify

#### `lib/lua/compiler/instruction.ex`

Extend constructors with optional trailing `hint_a`/`hint_b` (or a
single `hint` for unary):

- `add/subtract/multiply/divide/floor_divide/modulo/power` (binary)
- `negate` (unary)
- `bitwise_and/bitwise_or/bitwise_xor/shift_left/shift_right` (binary)
- `bitwise_not` (unary)

All hints default to `nil`.

#### `lib/lua/compiler/codegen.ex`

At lines 910–966, the `left`/`right` AST nodes are in scope when the
binop/unop instruction is emitted. Call `name_hint(left, ctx)` /
`name_hint(right, ctx)` and pass to the `Instruction.*` constructor.
Apply only to arith/bitwise — comparison ops don't take this path.

#### `lib/lua/vm/executor.ex`

- Update each `do_execute([{:op, ...} | rest], ...)` pattern for the
  14 arith/bitwise opcodes to match the new tuple shape (binary ops
  have both a fast int-int clause and a fallback clause; unary has a
  single clause).
- Pass the operand hints through to the `safe_*` helpers. On the
  `{:error, val}` path, select the hint corresponding to `val`
  (whichever operand failed `to_number`) and forward to
  `raise_arith_type_error`.
- `raise_arith_type_error/3` → arity 4 with `hint`; append
  `format_target_hint(hint)` to the value string. Same pattern as
  `raise_index_type_error/4` at line 1961.
- `to_integer!/3` and `float_to_integer!/2`: add a `hint` parameter
  and append the formatted hint. Critical for `math.huge << 1` →
  `"number has no integer representation (field 'huge')"`. Update all
  callsites in `:bitwise_*` / `:shift_*` clauses to thread the
  matching operand hint.

#### `lib/lua/compiler/bytecode.ex`

Line ~130 encodes instructions for `.luac` serialization. The new
tuple arity will break round-trip if any on-disk bytecode exists.
Strategy: strip hints on encode (they're debug info; missing-on-disk
is acceptable degradation). Implement by destructuring the new shape
and writing the same `{@op_X, dest, a, b}` form.

#### Tests

`test/lua/vm/error_format_test.exs` — pin each rendering:

- `return foo + 1` (foo nil global) → `"attempt to perform
  arithmetic on a nil value (global 'foo')"`
- `local x; return -x` → `"... (local 'x')"`
- `local t = {}; return t.x + 1` → `"... (field 'x')"`
- `function outer() local y; return function() return y + 1 end end`
  via the returned closure → `"... (upvalue 'y')"`
- `return math.huge << 1` → `"number has no integer representation
  (field 'huge')"`
- `local s = 'x'; return s << 1` → `"... (local 's')"`

#### `test/lua53_skips.exs`

After the implementation goes green, comment out the `:all` skip for
`math.lua`, `sort.lua`, `errors.lua`, and `strings.lua` one at a time
and run the suite. Narrow each to the smallest line range that still
fails for *non-wording* reasons. Update the `reason:` to describe the
narrowed cause.

### Critical files (quick reference)

- `lib/lua/vm/executor.ex` — arith patterns at 979–1135 (`:add`
  through `:power`/`:negate`), bitwise at 1141–1216; helpers at 2269
  (arith raise), 2517–2562 (`to_integer!` / `float_to_integer!`),
  format helpers at 1961 / 1974–1991.
- `lib/lua/compiler/codegen.ex` — emit sites at 910–966;
  `name_hint/2` at 1641–1659.
- `lib/lua/compiler/instruction.ex` — constructors at 40–56.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix test test/lua/vm/error_format_test.exs
mix test test/lua/vm/arithmetic_test.exs
mix test test/lua/vm/bitwise_test.exs
mix dialyzer
```

Then, with skip ranges narrowed:

```bash
mix test --include skip
```

Expected: math.lua / sort.lua / errors.lua / strings.lua either fully
pass or fail at a *narrower* line range (with a reason other than
"checkerror format mismatch").

## Risks

- Tuple shape change ripples to every `:add`/`:subtract`/… match site.
  Easy to miss a clause — exhaustive search for `{:op,` patterns in
  the executor before declaring done.
- Bytecode round-trip: the bytecode encoder/decoder must agree on
  arity. If both sides strip the hint, behaviour is identical to
  in-memory execution minus the hint suffix on errors after a `luac`
  reload.
- The suite skips may not narrow as much as hoped if non-wording
  blockers remain (`math.huge` finite, `os.clock` missing, etc.).
  That's still an honest closure of #252 — the wording half is done.

## Discoveries

(populated during implementation)

## What changed

(populated when PR opens)

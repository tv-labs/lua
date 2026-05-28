---
id: A42
title: Adjust parenthesised call/vararg to a single value (Lua 5.3 §3.4)
issue: 254
pr: 278
branch: fix/paren-adjust-single-value
base: main
status: review
direction: A
unlocks:
  - constructs.lua
  - calls.lua (lines 207–208)
---

## Goal

Make `(f())` and `(...)` adjust to exactly one value, per Lua 5.3 §3.4
("function calls and vararg expressions, when used inside parentheses,
are adjusted to one result").

Today the parser strips parentheses at parse time, so `(f())` and `f()`
produce identical ASTs. In multi-value positions (last RHS, last arg,
`return`, last field of a table constructor) both expand to all results.
After this plan, the parenthesised form takes only the first result.

Spec repro:

```lua
local function f() return 1,2,3 end
local a, b, c = (f())
return a, b, c
-- expected: 1, nil, nil
-- actual today: 1, 2, 3
```

## Out of scope

- Any other §3.4 semantics that aren't about parens (e.g. `result_count`
  fixed-N adjustment is already correct).
- Recovering the source range of the parens for error messages — `meta`
  on `Expr.Paren` is enough; we don't need a separate close-paren span.
- Pretty-printer changes beyond what is necessary to keep round-tripping
  honest.

## Success criteria

- [ ] New unit-test file `test/lua/vm/paren_adjust_test.exs` pins all
      four multi-value positions:
      1. Last RHS of multi-assign: `local a,b,c = (f())` → `1, nil, nil`.
      2. Last `return` value: `return (f())` returns one value.
      3. Last argument to a call: `g((f()))` passes one value.
      4. Last field of `{...}` constructor: `{1, (f())}` → length 2.
      Each position is also covered for `(...)` (vararg).
- [ ] `constructs.lua` either passes or its skip range narrows from
      `:all` to a specific later line; update `test/lua53_skips.exs`
      either way.
- [ ] `calls.lua` lines 207–208 are removed from the skip list (the
      §3.4 entry).
- [ ] `mix test` passes (no regressions from current baseline).
- [ ] `mix test --only lua53` passes; capture the file delta.

## Implementation notes

Files to touch:

- `lib/lua/ast/expr.ex` — add `defmodule Paren` with `[:inner, :meta]`;
  add `Paren.t()` to the `t` union.
- `lib/lua/parser.ex` — `parse_paren_expr/1` (line 955) currently
  returns the inner expression directly. Wrap with
  `%Expr.Paren{inner: e, meta: Meta.new(pos)}` only when `inner` is
  `Expr.Call`, `Expr.MethodCall`, or `Expr.Vararg`. Other inners stay
  unwrapped (no semantic difference, keeps existing precedence tests
  unchanged).
- `lib/lua/compiler/scope.ex` — add a passthrough clause:
  `defp resolve_expr(%Expr.Paren{inner: e}, state), do: resolve_expr(e, state)`.
- `lib/lua/compiler/codegen.ex` — add a passthrough clause:
  `defp gen_expr(%Expr.Paren{inner: e}, ctx), do: gen_expr(e, ctx)`.
  This works because the multi-value detection sites all pattern-match
  on the bare `Expr.Call`/`Expr.MethodCall`/`Expr.Vararg` structs and
  will now see `Expr.Paren` instead, falling through to the
  single-result branch. No other codegen change is needed.
- `lib/lua/ast/walker.ex` — add `Paren` to both `do_map` (map `inner`)
  and `children` (return `[inner]`) so AST traversals descend through
  parens.
- `lib/lua/ast/pretty_printer.ex` — print `(` + inner + `)`.
- `test/lua53_skips.exs` — remove the `lines: 207..218` calls.lua
  entry whose 207..208 component cites issue #254 (split or drop, see
  Discoveries during impl), and re-triage `constructs.lua` (either
  remove if it now passes, or narrow `:all` to the next failure
  range).

Multi-value detection sites that this change relies on (all already
match the bare struct, so wrapping with `Paren` is enough to opt out
of expansion):

- `lib/lua/compiler/codegen.ex` Statement.Return clauses (lines 111–127
  and the multi-value branch around 145).
- Statement.Assign last-value detection (line 258).
- Statement.Local last-value detection (line 366).
- Expr.Call args last-arg detection (line 1078).
- Expr.MethodCall args last-arg detection (line 1365).
- Expr.Table last-field detection (line 1195).

`name_hint/2` falls through to `nil` for unknown shapes, so
`(f)()` (where `f` is Var) doesn't get wrapped (parser only wraps
Call/MethodCall/Vararg), and `((f()))(x)` correctly returns `nil` as
the hint for the outer call.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix test --only lua53
mix test test/lua/vm/paren_adjust_test.exs
```

Snapshot the lua53 suite pass count before and after; record the
delta in `## What changed`.

## Risks

- IR shape changes can break walker/pretty-printer consumers. Mitigate
  by updating both in the same PR and running the existing parser /
  walker / pretty-printer tests.
- Existing compiler tests may pin "parens are transparent" for
  Call/MethodCall/Vararg specifically. Grep `test/` for any AST
  pattern that asserts `Expr.Call` directly under `Statement.Return`
  via a `(f())` source — none are expected based on the precedence
  tests, but verify before pushing.
- `constructs.lua` may still fail past the §3.4 issue. If it does,
  narrow the skip rather than removing it; this plan only commits to
  fixing the §3.4 blocker, not the whole file.

## Discoveries

- The codegen multi-value detection sites all pattern-match on the
  bare `Expr.Call` / `Expr.MethodCall` / `Expr.Vararg` structs, so a
  single `gen_expr(%Expr.Paren{inner: e}, ctx) -> gen_expr(e, ctx)`
  passthrough is enough. No per-site changes (Return / Assign / Local
  / Call args / MethodCall args / Table) were needed.
- `constructs.lua` advanced past the §3.4 case but fails at line 226
  on `assert(debug.getinfo(1, "n").name == 'F')` — the `"n"` field of
  `debug.getinfo` is unimplemented for the currently-executing closure.
  Past 226 the file also exercises `os.time` (line 237) and a
  `load()`-driven short-circuit harness (lines 287–298). The skip was
  narrowed to `225..313` with a triage note rather than expanding this
  PR's scope. Worth a future plan to triage individually.

## What changed

PR: #278

Files touched:

- `lib/lua/ast/expr.ex` — new `Expr.Paren{inner, meta}` AST node.
- `lib/lua/parser.ex` — `parse_paren_expr/1` wraps only Call /
  MethodCall / Vararg inners.
- `lib/lua/compiler/scope.ex` — passthrough resolve clause.
- `lib/lua/compiler/codegen.ex` — passthrough gen_expr clause.
- `lib/lua/ast/walker.ex` — Paren in `do_map` and `children`.
- `lib/lua/ast/pretty_printer.ex` — Paren prints `(inner)`.
- `test/lua/vm/paren_adjust_test.exs` — new file pinning all four
  multi-value positions for Call and Vararg (10 tests).
- `test/lua53_skips.exs` — drop `calls.lua` 207..208 §3.4 entry;
  narrow `constructs.lua` from `:all` to `225..313` with a fresh
  reason.

Suite delta: 2008 → 2019 passing unit tests (+11), 24 → 23 skipped.
lua53 suite: 12 → 13 files passing.

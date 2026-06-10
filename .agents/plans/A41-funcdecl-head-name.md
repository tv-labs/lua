---
id: A41
title: Resolve FuncDecl head names at scope analysis (not post-block codegen)
issue: 255
pr: 274
branch: fix/funcdecl-head-name
base: main
status: merged
direction: A
unlocks:
  - calls.lua
---

## Goal

Fix the multi-name `FuncDecl` codegen path (`function a.b.c(...)` / `function
a:m(...)`) so the head name `a` resolves against the *live* scope at scope
analysis time, not against the function-scope snapshot left over after the
enclosing block has been restored. This is the blocker keeping
`calls.lua` deferred at `:all` in `test/lua53_skips.exs`.

The single-name `FuncDecl` already does the right thing — it resolves the
target during scope analysis and stashes the result under
`{:func_decl_target, decl}` (`lib/lua/compiler/scope.ex:246–287`). This plan
extends that same pattern to multi-name FuncDecl heads.

## Out of scope

- Reworking `gen_var_by_name/2` for its other (chunk-level) hypothetical
  callers — it has none today besides multi-name FuncDecl, but the helper
  can stay in place until a follow-up cleanup removes it deliberately.
- Adding hints / better error messages for the multi-name path.
- Any other `calls.lua` follow-up failures that surface after this fix —
  document them and decide in-flight whether they're in scope or split.

## Success criteria

- [ ] Repro from issue #255 passes (a `do` block with a `local a` shadowing
      a global, then `function a:m(...)`, then `a:m(...)`).
- [ ] The same fix covers `function a.b.c.f(...)` (dotted multi-name).
- [ ] `mix test` passes with no regressions (baseline: 1963 passed,
      25 skipped on main at `e8b9c4d`).
- [ ] Regression test added in `test/lua/vm/` covering both the method
      sugar (`function a:m`) and the dotted multi-name (`function a.b.c`)
      against a block-local `a`.
- [ ] `calls.lua` either passes end-to-end (drop `:all` skip) or narrows
      to a smaller, separately-tracked failure with an updated `reason:`.

## Implementation notes

### Scope analysis (`lib/lua/compiler/scope.ex`)

Today the multi-name FuncDecl clause is a one-liner at lines 289–292 that
only calls `resolve_function_scope/4` for the body. Add a new clause that
runs *before* it (more specific match) for `[first | rest]` when
`length(rest) > 0`:

1. Resolve the head name `first` exactly like `Expr.Var` is resolved
   (`scope.ex:360–382`): check `state.locals`, then `find_upvalue/3`,
   else `{:env_field, env_ref, first}`.
2. Stash the result under `var_map` key `{:func_decl_head, decl}`.
3. Then call `resolve_function_scope(decl, all_params, body, state)`.

The head resolution must happen *before* `resolve_function_scope/4` so it
reads the live scope (the surrounding block's locals are still present).
Inside `resolve_function_scope/4` the current function changes and locals
are swapped, which would shadow the lookup.

`all_params` accounts for `is_method`: prepend `"self"` when true.

### Codegen (`lib/lua/compiler/codegen.ex`)

At `codegen.ex:676–691`, the multi-name arm currently calls
`gen_var_by_name(first, ctx)` (line 678). Replace that with a `var_map`
lookup keyed on `{:func_decl_head, decl}`. The four cases mirror
`gen_expr(%Expr.Var{}, ctx)` (lines 979–1008):

- `{:register, reg}` → `{[], reg, ctx}` (already loaded).
- `{:captured_local, reg}` → emit `get_open_upvalue` into a fresh reg.
- `{:upvalue, index}` → emit `get_upvalue` into a fresh reg.
- `{:env_field, env_ref, name}` → call `gen_env_field_get(env_ref, name, ctx)`.

Everything downstream (the field-walk over `rest` and the trailing
`set_field`) stays unchanged.

Leave `gen_var_by_name/2` in place if no other caller is removed — the
private helper costs nothing while it's unreachable. Annotate it
`# Deprecated: kept temporarily; sole caller migrated to var_map.` only
if it's obviously dead, otherwise leave it untouched.

### Tests (`test/lua/vm/`)

Add regression tests in `test/lua/vm/func_decl_test.exs` (new file —
existing function-declaration coverage is scattered, this gives the
plan a dedicated home).

Required cases:

1. **Method sugar against block-local** (the issue's repro):
   ```lua
   a = {i=10}                       -- global
   local result
   do
     local a = {x=0}                -- shadows
     function a:add(x)
       self.x = self.x + x
       return self
     end
     result = a:add(10).x
   end
   return result                    -- expected 10
   ```
2. **Dotted multi-name against block-local**:
   ```lua
   local result
   do
     local a = {}
     function a.b()
       return 42
     end
     result = a.b()
   end
   return result                    -- expected 42
   ```
3. **Upvalue head name** — outer fn declares `local a = {}`, inner fn
   defines `function a.b()`. Verifies the upvalue branch of the new
   var_map entry.
4. **Free-name head (global)** — `function a.b()` at chunk top level
   with no local `a`. Verifies the `:env_field` branch still emits a
   `_ENV` field read.

### Suite skip (`test/lua53_skips.exs`)

Drop or narrow the `calls.lua` `:all` entry (`test/lua53_skips.exs:42–51`).
After the fix, run `mix test --only lua53` against `calls.lua` and either:
- Remove the entry entirely if calls.lua passes.
- Narrow `lines:` to the residual failure range and update `reason:`
  to describe the remaining cause (not the one fixed here).

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix test test/lua/vm/func_decl_test.exs
mix test --only lua53
```

Capture before/after status with `mix lua.suite --status` and include the
delta in the PR body.

## Risks

- Multi-name FuncDecl is rarer than single-name in unit tests, so a subtle
  regression here may not show up immediately. Mitigated by adding all four
  shape variants in the new test file.
- `find_upvalue/3` walks parent scopes and may create new upvalue
  descriptors. For the head name of a multi-name FuncDecl, that's exactly
  what we want (same as for an `Expr.Var` read of the same name). Verify
  that `state.functions[...].upvalue_descriptors` ends up identical to
  what the single-name path would produce for the same lookup.
- `gen_var_by_name/2` may still be on the critical path for some
  edge case we haven't enumerated. Leave it in for now; only remove if
  a deliberate cleanup PR audits all callers.

## Discoveries

1. **Body-first ordering matters.** The first draft of the multi-name
   FuncDecl scope clause resolved the head name *before* calling
   `resolve_function_scope/4`. That made the head's `captured_locals`
   check race the body, so a head that the body captured (e.g.
   `function a:add (x) ... a.y = 20 ... end`) was tagged as a plain
   `{:register, _}` instead of `{:captured_local, _}`. Single-name
   FuncDecl already resolves *after* the body for this exact reason
   (see the comment at `scope.ex:261`). Multi-name now matches.

2. **`gen_var_by_name/2` was the only chunk-level by-name caller.**
   With the multi-name FuncDecl head migrated to the var_map, the
   `gen_var_by_name/2` / `compute_env_var_ref_at_codegen/1` /
   `current_function_env_upvalue_index/1` trio in
   `lib/lua/compiler/codegen.ex` had no remaining callers and tripped
   `--warnings-as-errors`. Removed all three; the var_map approach is
   strictly more general (it walks the upvalue chain, where
   `gen_var_by_name` could only see chunk-level locals).

3. **Pre-existing open-upvalue staleness across `do` blocks.**
   `pm.lua` was lucky; `calls.lua:65–69` is not. When a `do` block
   declares a captured local (e.g. `local function fact (n) ...
   fact(n-1) ... end`), the executor's `state.open_upvalues` map
   records a cell at that register. The mapping is never closed when
   the block ends. The *next* `do` block to reuse the same register
   for a different captured local (e.g. `local a = {x=0}` followed by
   `function a:add (x) ... a.y = ... end`) inherits the stale cell —
   the closure handler at `executor.ex:707` reuses the existing cell
   ref, so reads of `a` through `get_open_upvalue` return the prior
   block's value. This is unrelated to FuncDecl head resolution and
   blocks `calls.lua:65–69`. Narrowed via skip; needs its own plan
   (likely "close open upvalues at block end").

4. **calls.lua progress is bigger than the FuncDecl head fix alone.**
   After landing this PR, `calls.lua` runs lines 1–218 cleanly (the
   first ~54% of the file). The remaining ranges are deferred for
   reasons documented inline in `test/lua53_skips.exs` — three of the
   five new skip ranges correspond to known concerns (#254
   parenthesized adjustment, parser ambiguity wart, stdlib
   extra-arg-tolerance) and one (`lines: 65..69`) is the new
   open-upvalue staleness discovery above.

## What changed

PR: [#274](https://github.com/tv-labs/lua/pull/274)

Files touched:

- `lib/lua/compiler/scope.ex` — new `Statement.FuncDecl` clause for
  multi-name (`[first | rest]` with `rest != []`). Resolves the head
  name via the new `resolve_func_decl_head/3` helper *after*
  `resolve_function_scope/4` so `captured_locals` is fully populated.
  Removed the stale `gen_var_by_name`-era comment from the
  `_ENV` upvalue preamble.

- `lib/lua/compiler/codegen.ex` — multi-name arm of the
  `Statement.FuncDecl` codegen now loads the head value via the
  new `gen_func_decl_head/2` helper (`var_map` lookup), mirroring the
  four `Expr.Var` cases. Deleted `gen_var_by_name/2`,
  `compute_env_var_ref_at_codegen/1`, and
  `current_function_env_upvalue_index/1` (no remaining callers).

- `test/lua/vm/func_decl_test.exs` — new file, six regression tests
  covering: method-sugar against block-local, dotted multi-name
  against block-local, three-deep dotted name, head-as-upvalue (inner
  function), body captures head (calls.lua:65–69 shape), and the
  no-local-in-scope `_ENV` fallback.

- `test/lua53_skips.exs` — replaced `calls.lua` `:all` skip with five
  narrowed ranges. The file now runs lines 1–218 (54% of 401 lines);
  remaining skips are categorised by underlying cause.

Suite delta: unit suite 1963 → 1970 passed (+7, no regressions, six
new tests in `func_decl_test.exs` plus one previously-skipped suite
test now running). lua53 official suite: `calls.lua` moved out of the
`:all`/`@tag :skip` bucket into the ranged-skip bucket.

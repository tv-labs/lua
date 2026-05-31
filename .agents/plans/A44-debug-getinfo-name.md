---
id: A44
title: "debug.getinfo(level, 'n') populates name/namewhat from the caller's call site"
issue: 279
pr: 290
branch: feat/debug-getinfo-name
base: main
status: review
direction: A
unlocks:
  - constructs.lua
---

## Goal

Make `debug.getinfo(level, "n")` return a non-nil `name` (and a matching
`namewhat`) for the common call forms, so the issue repro passes:

```lua
function F(a) return a end
F(1)
assert(debug.getinfo(1, "n").name == 'F')
```

## Out of scope

- The full PUC-Lua `getfuncname` caller-instruction walk for every form.
  We reuse the compile-time name hint already threaded onto `:call`/`:self`
  instructions (the same hint that powers "attempt to call a nil value
  (global 'foo')" errors). That hint covers global, local, upvalue, field,
  and method call sites.
- Naming of functions reached through forms that carry no hint at the call
  site (e.g. a call through a temporary, `(t[expr])()`, immediately-invoked
  anonymous closures). Those keep `name == nil` / `namewhat == ""`, matching
  the PUC-Lua "unknown" fallback closely enough for the suite.
- `name`/`namewhat` for the entry chunk and for native (C) functions inspected
  by value (`debug.getinfo(somefunc, "n")`): still nil. PUC-Lua also leaves
  the value-based query without a name unless it can find a global binding.

## Success criteria

- `debug.getinfo(1, "n").name == "F"` for `function F() ... end; F()`.
- `namewhat` is `"global"` / `"local"` / `"upvalue"` / `"field"` / `"method"`
  matching the call site, and `""` when no name is known.
- A regression unit test pins the issue repro.
- `constructs.lua` skip range narrows past line 226.
- `mix test` and the lua53 suite stay green.

## Implementation notes

The name is recovered from the *caller's* call instruction, PUC-Lua style,
but resolved at compile time: every `:call`/`:self` instruction already
carries a `name_hint` tagged tuple (`{:global, "F"}`, `{:local, "x"}`, ...),
and the executor already records `name: hint_name(name_hint)` on each
`call_stack` frame.

Two small changes:

1. Executor: also stash the hint *tag* on the frame as `:namewhat`
   (`"global"`, `"local"`, `"upvalue"`, `"field"`, `"method"`), alongside the
   existing `:name`. Done at both call-frame construction sites
   (`do_execute` `:call` handler and `dispatcher_call_info/3`).
2. `debug.getinfo`: for an integer `level`, read the callee frame for that
   level (`call_stack` is headed by the running function when a native
   callback is executing) and surface its `name`/`namewhat`.

No prototype/codegen change is needed: the hint already lives on the
instruction stream, which is the more faithful PUC-Lua model than capturing
the declared name on the prototype.

## Verification

- `mix format`
- `mix compile --warnings-as-errors`
- `mix test`
- `mix test test/lua53_suite_test.exs --only lua53`
- New regression test under `test/lua/vm/stdlib/`.

## Risks

- Level-to-frame mapping: a native callback does not push its own frame, so
  the running Lua function's frame is the head of `call_stack`. Verified
  empirically before relying on it.
- Frame shape is read by the error formatter via `Map.get/2`; adding a
  `:namewhat` key is additive and cannot break existing readers.

## Discoveries

(none yet)

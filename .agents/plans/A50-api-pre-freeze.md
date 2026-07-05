---
id: A50
title: "API pre-freeze fixes: struct encoding, dead guard, option consistency"
issue: null
pr: null
branch: fix/api-pre-freeze
base: main
status: in_progress
direction: A
---

## Goal
Fix the public-API sharp edges that would become breaking changes once 1.0
freezes the surface: bare-struct encoding, a dead compat guard, and option
inconsistencies.

## Out of scope
- The `Lua.Encoder` protocol itself (1.1, issue #341).
- Renaming closure tags or any tag-tuple restructuring.
- Docs-only fixes elsewhere (sibling PR A49 handles those).
- Version bump / release mechanics.

## Success criteria
- [ ] Bare struct encoding raises a helpful error; `Map.from_struct/1` path works.
- [ ] `is_mfa/1` guard and its import removed; no repo references remain.
- [ ] Closure tags documented as unstable (guard + `unwrap/1`).
- [ ] `:max_string_bytes` accepts `:infinity`, uniform with siblings; test added.
- [ ] `eval!/3` chunk clause accepts `:source`; test added.
- [ ] `call_function/3` error shape documented with an example.
- [ ] `Lua.CompilerException` `:state` field removed (was always nil).
- [ ] `Lua.VM.execute/3` moduledoc reworded as internal.
- [ ] CHANGELOG Unreleased entries added for items 1, 2, 4, 5, 7.
- [ ] `mix format`, `mix compile --warnings-as-errors`, `mix test`,
      `mix test --only lua53` (20 passed / 9 skipped), `mix docs --warnings-as-errors` all pass.

## Implementation notes
- `lib/lua/vm/value.ex`: add a `%mod{}` struct clause before the `is_map`
  clause that raises `Lua.RuntimeException`.
- `lib/lua/api.ex`: remove `is_mfa/1` guard + import entry; document closure
  tags as unstable.
- `lib/lua.ex`: `validate_max_string_bytes!` accepts `:infinity`; `eval!/3`
  chunk clause accepts `:source`; `call_function/3` error-shape doc; `unwrap/1`
  tag-stability note; `:max_string_bytes` option doc mentions `:infinity`.
- `lib/lua/vm/state.ex`: widen `max_string_bytes` typespec.
- `lib/lua/compiler_exception.ex`: drop `:state` field, update moduledoc.
- `lib/lua/vm.ex`: reword moduledoc as internal.
- `CHANGELOG.md`: Unreleased entries.

## Verification
```
mix format
mix compile --warnings-as-errors
mix test
mix test --only lua53
mix docs --warnings-as-errors
```

## Risks
- Struct encoding raise could break a caller that relied on the accidental
  `__struct__`-key behaviour. Audit found no legitimate struct encoding in
  lib/ or test/, so risk is low; it is exactly the pre-freeze fix.

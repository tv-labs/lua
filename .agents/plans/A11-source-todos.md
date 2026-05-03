---
id: A11
title: Resolve in-source TODOs (compiler error handling, stacktrace formatting, load reader chunks)
issue: null
pr: null
branch: chore/source-todos
base: main
status: ready
direction: A
---

## Goal

Clean up three in-source TODOs that have been lingering since the rewrite,
now that the prerequisite features are in place.

## Out of scope

- Other TODOs not on this list.
- Restructuring how errors flow through the compiler.

## Success criteria

- [ ] `mix test` passes (≥ 1273, no regressions)
- [ ] All three TODOs resolved or removed with a comment explaining why
      they're being intentionally deferred.
- [ ] `grep -n "TODO" lib/` shows three fewer hits in the targeted files.

## Implementation notes

### TODO #1: `lib/lua/compiler.ex:34`

```
# TODO bring back when the compiler can return errors
```

Verify that the compiler now actually returns `{:error, _}` tuples for
errors (it should after Phase 11). If yes, restore the proper error
handling. If no, document why and leave the TODO in place with a clearer
explanation.

### TODO #2: `lib/lua/compiler_exception.ex:27`

```
# TODO: Re-add stacktrace formatting once the new VM has stacktrace support.
```

The new VM has stacktrace support (Phase 1 source-line tracking + Phase 2
formatter). Wire `Lua.VM.ErrorFormatter` (or equivalent) into
`CompilerException.message/1` so compiler errors get the same rich
formatting as runtime errors. Add a test asserting the formatted output
includes source location.

### TODO #3: `lib/lua/vm/stdlib.ex:412`

```
# TODO: Support function chunks and reader functions
```

`load(_)` currently only accepts strings. Lua 5.3 also accepts a function
that returns chunk pieces. Implement: when arg is a function, call it
repeatedly until it returns `nil` or `""`, concatenate the pieces, then
proceed with normal compilation. Add unit tests in
`test/lua/vm/stdlib_load_test.exs`.

If this is bigger than ½ day, split it out as A11c.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix test --only lua53
```

## Risks

- `CompilerException` is part of the public API. The message format change
  is observable. Verify no tests rely on the old format.
- Reader-function `load` is uncommon but used in some test files.

## Discoveries

(populated during implementation)

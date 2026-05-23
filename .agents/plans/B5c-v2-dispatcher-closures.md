---
id: B5c-v2
title: Dispatcher closures, varargs, and multi-return — every opcode covered
issue: null
pr: null
branch: perf/dispatcher-closures
base: main
status: blocked
direction: B
unlocks:
  - 100% opcode coverage in the dispatcher (no more fallbacks)
  - closures and OOP benchmarks fully dispatcher-routed
parent: B5-dispatcher-and-bytecode
---

## Blocked on

- B5a-v2 (foundation), B5b-v2 (tables).

## Goal

Cover the remaining opcodes in `Lua.VM.Dispatcher`:

- `:closure` — closure construction with upvalue capture.
- `:set_upvalue`.
- `:get_open_upvalue`, `:set_open_upvalue` — open-cell access for
  captures of mutable locals.
- `:vararg`, `:return_vararg`.
- `:return` with count > 1.
- `:generic_for`, `:self`, `:tail_call`.

After this PR no prototype falls back to the list-of-tuples
interpreter for opcode-coverage reasons.

## Out of scope

- Tail-call elimination beyond what the BEAM gives us "for free"
  from tail-recursive dispatch.
- Optimised closure capture (escape analysis, capture-by-value
  promotion). Defer.

## Success criteria

(To be detailed when this plan unblocks. Mirrors original B5d
success criteria.)

## Discoveries

(Empty until implementation.)

---
id: B5d-v2
title: Dispatcher error position fidelity
issue: null
pr: null
branch: perf/dispatcher-errors
base: main
status: blocked
direction: B
unlocks:
  - parity with interpreter on every error-message test
  - removes the last semantic gap between dispatcher and interpreter
parent: B5-dispatcher-and-bytecode
---

## Blocked on

- B5a-v2 (foundation), B5b-v2 (tables), B5c-v2 (closures).

## Goal

Make dispatcher-executed prototypes raise exceptions with the same
`line:`, `source:`, and stack-trace information the interpreter
raises. After this PR no error-message test can distinguish a
dispatcher-routed prototype from an interpreted one.

## Implementation strategy

PC-to-line table per prototype, populated by the bytecode encoder
from `:source_line` opcodes. The dispatcher threads `current_line`
through every step (already in B5a-v2's signature). On raise, wrap
in try/catch and re-raise with the right position. This is
cheaper inside a single dispatcher than across a generated-module
boundary (the original B5e's plan) because no cross-module
unwinding is needed.

## Out of scope

- Stack-trace shape for compiled-to-compiled call chains. The
  per-call shape from the interpreter survives — `call_function/3`
  already carries position context.
- Source-map formats compatible with external debuggers. Not in
  scope for this rewrite.

## Success criteria

(To be detailed when this plan unblocks. Mirrors original B5e
success criteria.)

## Discoveries

(Empty until implementation.)

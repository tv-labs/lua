---
description: Run the Lua 5.3 suite, report pass/fail counts, propose ROADMAP update if changed
agent: build
---

Run the Lua 5.3 official test suite and report results:

!`mix test --only lua53 2>&1 | tail -10`

Then run a fuller per-file survey using `triage-suite-failure`'s standalone
pattern (build a small Elixir script in /tmp, iterate over every file in
test/lua53_tests/*.lua with an 8-second timeout, capture PASS/FAIL with
short error message). Don't bother instrumenting individual failures —
this command is a status check, not a triage session.

Show me:

1. Pass count: N/24
2. Files passing
3. Files failing (with short error category)
4. Files timing out
5. Delta vs ROADMAP.md's "Status" line

If the count differs from `ROADMAP.md`, propose an edit (don't make the edit
without my confirmation):

- New status line
- Updated "Done" entries if any
- Any new "Deferred" notes if a file flipped from passing → failing

If the count is unchanged, just confirm.

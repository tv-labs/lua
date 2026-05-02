---
name: triage-suite-failure
description: |
  Diagnose a failing Lua 5.3 official test suite file. Isolates the failure,
  classifies it, decides whether to fix-now or defer, and produces either a
  unit test + plan file (for fix-now) or a deferred-with-comment skip (for
  out-of-scope).

  Use this when investigating a specific suite file (`literals.lua`,
  `bitwise.lua`, etc.), when a /next-plan ship reveals downstream suite
  failures, when /suite-status shows new failures, or when the user asks
  "why is X failing".

  This skill does not ship code itself — it produces the artifacts (plan
  file, unit test, or skip tag) that other plans then ship via ship-a-plan.
---

# triage-suite-failure

A reproducible workflow for understanding why a Lua 5.3 suite test fails and
turning that understanding into a shippable plan.

## What this skill is for

- Reproducing a single suite failure deterministically.
- Classifying it (lexer / parser / codegen / executor / stdlib / unimplemented).
- Reducing it to a 5–20 line repro that lives in `test/lua/vm/`.
- Producing one of three outputs:
  1. A new plan file under `.opencode/plans/` if the fix is shippable.
  2. An `@tag :skip` annotation in `test/lua53_suite_test.exs` with a clear
     comment explaining the deferral, plus a deferred-issue label.
  3. An update to an existing plan if this failure is part of an ongoing fix.

## What this skill is NOT for

- Implementing the fix. (That's `ship-a-plan`.)
- Reasoning about whole-suite trends. (That's `/suite-status`.)
- Designing new test infrastructure.

## Workflow

### 1. Reproduce the failure standalone

The suite test runner has overhead and shared state. Always reproduce against
a freshly-constructed `Lua` value, with sandbox config matching the suite
runner.

Use this exact pattern (write to `/tmp/triage_<file>.exs`):

```elixir
path = "test/lua53_tests/<file>.lua"
source = File.read!(path)
lua = Lua.new(exclude: [[:package], [:require], [:load], [:loadstring], [:loadfile], [:dofile]])
lua = Lua.set_lua_paths(lua, [Path.join(Path.dirname(path), "?.lua")])

try do
  {_, _} = Lua.eval!(lua, source)
  IO.puts(:pass)
rescue
  e ->
    msg = case e do
      %{value: v} when is_binary(v) -> v
      %{value: v} -> inspect(v)
      _ -> Exception.message(e)
    end
    IO.puts(String.slice(msg, 0, 2000))
end
```

Run with `mix run /tmp/triage_<file>.exs`. Note: do not use `mix run -e` for
this — file scripts give clean stack traces.

### 2. Find the failing line

Suite files are large (hundreds to thousands of lines). To pinpoint the
failure:

- If the error includes a line number, jump straight to step 3.
- Otherwise, instrument with line-print probes. Walk the file in halves:
  insert `print("checkpoint A")` halfway down, run; if it prints, the
  failure is below; if not, it's above. Bisect to a single statement.

For long-running tests (10+ seconds), run with a timeout via `Task.yield`
and look at where stdout cut off — that's near the failure.

### 3. Reduce to a minimal repro

Take the failing statement and the minimum surrounding context. Goal: 5–20
lines that reproduce the same failure.

- Remove all `assert` calls except the failing one.
- Inline any helpers it depends on.
- Replace data with the smallest value that triggers the bug.

### 4. Add the repro as a unit test

Path: `test/lua/vm/<area>_<bug>_test.exs` (or extend an existing file in
the right area). Mark as a regression test:

```elixir
# Regression test for Lua 5.3 suite: <file>.lua line N
# When fixed, this file should also pass: <related suite files>
test "table index returns nil for missing keys" do
  code = """
  local t = {}
  return t[5]
  """
  {[result], _} = Lua.eval!(code)
  assert result == nil
end
```

If the test passes (i.e. the bug doesn't reproduce in isolation), the suite
failure is from interaction effects — investigate further or escalate.

### 5. Classify the failure

Use this taxonomy. Pick the most specific one.

| Category | Symptom | Where to look |
|---|---|---|
| **Lexer** | `Failed to compile`, parse error, "no case clause matching {:comment, ...}" | `lib/lua/lexer.ex` |
| **Parser** | `Failed to compile`, "Expression statement must be a function call", "expected ..." | `lib/lua/parser.ex` |
| **Codegen** | Compiles but wrong instructions emitted (inspect with `Lua.Compiler.compile/1`) | `lib/lua/compiler/codegen.ex` |
| **Executor** | Runs but wrong value, `key N not found`, type errors on valid code | `lib/lua/vm/executor.ex` |
| **Stdlib** | "function 'X' not implemented", string/math/table edge case | `lib/lua/vm/stdlib*` |
| **Unimplemented** | Whole feature missing (coroutines, full debug, files) | N/A — defer |
| **Semantic** | Implementation correct per spec, but suite expects a Lua-5.3-specific behavior we don't match | depends — check the Lua 5.3 reference manual |

### 6. Decide: fix-now, plan-it, or defer

Three outcomes:

#### A. Trivial fix in scope

If the fix is < 50 lines in one file and isolated, AND it's part of an
in-progress plan: include it in that plan's branch with a note in
`## Discoveries`.

#### B. Multi-file impact OR new concern

Write a new plan file under `.opencode/plans/<id>-<slug>.md`. Use the
template in `.opencode/plans/README.md`. Frontmatter:

- `id`: next available in the current direction (A or B).
- `unlocks`: list of suite files this plan should fix. Run them all
  beforehand to confirm; list only ones you expect to flip.
- `status`: `ready` if independent, `blocked` if waiting on another plan.

Required sections:
- **Goal**: one sentence.
- **Out of scope**: the things this plan is NOT doing.
- **Success criteria**: include the unit test path, the suite count delta,
  and the unit-test stability requirement.
- **Implementation notes**: hypothesis, files to touch, what to look for.
- **Verification**: `mix test`, `mix test --only lua53`.
- **Risks**: known unknowns.

Then open a corresponding GitHub issue and link them via `issue:` frontmatter
field.

#### C. Defer (out of scope for current direction)

The bug is real but fixing it is weeks of work (coroutines, GC, full goto
CFG, file I/O, etc.).

In `test/lua53_suite_test.exs`:

```elixir
# Deferred: backward goto requires CFG pass in compiler.
# See .opencode/plans/A-goto-cfg.md (when written) or ROADMAP.md "Deferred".
@tag :skip
test "goto.lua" do ... end
```

Leave the unit test from step 4 in place — even if the suite file is
skipped, the unit test documents the bug and will catch a regression if a
future change accidentally fixes it.

If there's no deferred-tracking issue yet, open one with label `defer` and
reference it from the comment.

### 7. Output a triage report

Whatever the outcome, end with a short summary the user can paste into a
PR or issue:

```
Triage: <suite-file>

Symptom: <one line>
Failing line: <file>.lua:<N>
Repro: test/lua/vm/<area>_test.exs:<N>
Classification: <category>
Decision: fix-in-plan | defer | follow-up

If fix-in-plan: created .opencode/plans/<id>-<slug>.md
If defer: tagged @skip in test/lua53_suite_test.exs with reason
```

## Conventions

- Always leave a unit test, even when deferring. The unit test outlives the
  triage session.
- Always cite the suite file and line in test comments so future readers can
  trace back to the official test.
- Never silence a failing test without a comment naming what would unblock it.
- When in doubt about the Lua 5.3 spec, check the reference manual:
  https://www.lua.org/manual/5.3/

## When you're not sure

Ask the user. Specifically: when classifying a "semantic" failure (where
both interpretations are defensible), surface the Lua 5.3 manual section
and let the user decide whether to match it.

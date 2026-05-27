# Lua 5.3 official suite skip list.
#
# Loaded by `test/lua53_suite_test.exs` via `Code.eval_file/1`. Each
# key is a suite filename in `test/lua53_tests/`; each value is a list
# of skip entries. A file absent from this map runs unmodified.
#
# Entry shape:
#
#     %{
#       lines: 12..58,            # a Range, or the atom :all
#       category: :parser,        # :lexer | :parser | :codegen | :executor
#                                 # | :stdlib | :unimplemented | :semantic
#       reason: "one-line cause", # stands alone, no plan-id references
#       issue: 287                # optional GitHub issue number, or nil
#     }
#
# Use `lines: :all` for files awaiting initial triage. The test driver
# tags those `@tag :skip`. Files with specific ranges run with those
# lines commented out (line numbers preserved for error reporting).
#
# Run `mix lua.suite --status` for a quick conformance snapshot, or
# `mix lua.suite --audit` to find stale entries that no longer need
# to exist.
#
# The four permanently-deferred files (main.lua, files.lua,
# attrib.lua, verybig.lua) do NOT appear here — they live in
# `@deferred_permanent` in `test/lua53_suite_test.exs` because they
# exercise filesystem I/O and subprocess invocation that we will
# never support in an embedded sandboxed VM.

%{
  "all.lua" => [
    %{lines: :all, category: :unimplemented, reason: "upstream harness file, pending initial triage", issue: nil}
  ],
  "big.lua" => [
    %{
      lines: :all,
      category: :unimplemented,
      reason: "pending initial triage (suspected timeout per ROADMAP A10)",
      issue: nil
    }
  ],
  "calls.lua" => [
    %{lines: :all, category: :unimplemented, reason: "pending initial triage", issue: nil}
  ],
  "closure.lua" => [
    %{
      lines: :all,
      category: :unimplemented,
      reason: "pending initial triage (suspected timeout per ROADMAP A10)",
      issue: nil
    }
  ],
  "constructs.lua" => [
    %{lines: :all, category: :unimplemented, reason: "pending initial triage", issue: nil}
  ],
  "coroutine.lua" => [
    %{lines: :all, category: :unimplemented, reason: "coroutines not implemented", issue: nil}
  ],
  "db.lua" => [
    %{lines: :all, category: :unimplemented, reason: "full debug library not implemented", issue: nil}
  ],
  "errors.lua" => [
    %{lines: :all, category: :unimplemented, reason: "pending initial triage", issue: nil}
  ],
  "events.lua" => [
    %{lines: :all, category: :unimplemented, reason: "pending initial triage", issue: nil}
  ],
  "gc.lua" => [
    %{lines: :all, category: :unimplemented, reason: "garbage collection / weak tables not implemented", issue: nil}
  ],
  "goto.lua" => [
    %{
      lines: :all,
      category: :unimplemented,
      reason: "backward goto / goto-out-of-conditional not implemented",
      issue: nil
    }
  ],
  "literals.lua" => [
    %{lines: :all, category: :unimplemented, reason: "pending initial triage", issue: nil}
  ],
  "locals.lua" => [
    %{lines: :all, category: :unimplemented, reason: "pending initial triage", issue: nil}
  ],
  "math.lua" => [
    %{lines: :all, category: :unimplemented, reason: "pending initial triage", issue: nil}
  ],
  "nextvar.lua" => [
    %{lines: :all, category: :unimplemented, reason: "pending initial triage", issue: nil}
  ],
  "pm.lua" => [
    %{lines: :all, category: :unimplemented, reason: "pending initial triage (pattern engine work in A9)", issue: nil}
  ],
  "sort.lua" => [
    %{lines: :all, category: :unimplemented, reason: "pending initial triage", issue: nil}
  ],
  "strings.lua" => [
    %{lines: :all, category: :unimplemented, reason: "pending initial triage", issue: nil}
  ],
  "utf8.lua" => [
    %{
      lines: :all,
      category: :unimplemented,
      reason: "pending initial triage (suspected timeout per ROADMAP A10)",
      issue: nil
    }
  ]
}

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
    %{
      lines: :all,
      category: :semantic,
      reason:
        "FuncDecl target name resolved at codegen against post-block scope; print does not call user-overridden tostring",
      issue: nil
    }
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
    %{
      lines: :all,
      category: :semantic,
      reason: "parenthesized call/vararg does not adjust to a single value (Lua 5.3 §3.4)",
      issue: nil
    }
  ],
  "coroutine.lua" => [
    %{lines: :all, category: :unimplemented, reason: "coroutines not implemented", issue: nil}
  ],
  "db.lua" => [
    %{lines: :all, category: :unimplemented, reason: "full debug library not implemented", issue: nil}
  ],
  "errors.lua" => [
    %{
      lines: :all,
      category: :stdlib,
      reason:
        "checkmessage/checksyntax expect PUC-Lua [string \"...\"]:N: prefixes on load() errors; many parse-error templates still differ",
      issue: nil
    }
  ],
  "events.lua" => [
    %{
      lines: 403..432,
      category: :unimplemented,
      reason: "debug.setmetatable on primitive types (number, boolean, nil) not supported",
      issue: nil
    }
  ],
  "gc.lua" => [
    %{lines: :all, category: :unimplemented, reason: "garbage collection / weak tables not implemented", issue: nil}
  ],
  "goto.lua" => [
    %{
      lines: 12..40,
      category: :stdlib,
      reason: "load() parse-error messages do not match PUC-Lua 'label/local' format",
      issue: nil
    }
  ],
  "literals.lua" => [
    %{
      lines: 40..47,
      category: :semantic,
      reason: "debug.getinfo(1).currentline reports per-statement line, not per-call-site",
      issue: nil
    },
    %{
      lines: 72..112,
      category: :stdlib,
      reason: "load() parse-error messages do not match PUC-Lua 'near ...' format",
      issue: nil
    },
    %{
      lines: 219..223,
      category: :semantic,
      reason: "debug.getinfo(1).currentline reports per-statement line, not per-call-site",
      issue: nil
    },
    %{
      lines: 247..261,
      category: :unimplemented,
      reason: "coroutine.wrap / yield not implemented",
      issue: nil
    },
    %{
      lines: 264..288,
      category: :unimplemented,
      reason: "os.setlocale not implemented; locale-dependent number parsing",
      issue: nil
    },
    %{
      lines: 297..302,
      category: :stdlib,
      reason: "load() parse-error format for unterminated strings differs from PUC-Lua",
      issue: nil
    }
  ],
  "locals.lua" => [
    %{
      lines: :all,
      category: :unimplemented,
      reason: "debug.getupvalue not implemented; _ENV introspection via debug library missing",
      issue: nil
    }
  ],
  "math.lua" => [
    %{
      lines: :all,
      category: :stdlib,
      reason:
        "math.huge is a finite 1.0e308 stand-in so identities like math.huge + 1 == math.huge fail; not a wording issue",
      issue: nil
    }
  ],
  "pm.lua" => [
    %{lines: :all, category: :unimplemented, reason: "pending initial triage (pattern engine work in A9)", issue: nil}
  ],
  "sort.lua" => [
    %{
      lines: :all,
      category: :stdlib,
      reason: "times out (>30s) on the comparison-heavy section; os.clock not implemented",
      issue: nil
    }
  ],
  "strings.lua" => [
    %{
      lines: :all,
      category: :stdlib,
      reason: "times out (>30s) on string.rep with large counts; pending finer triage",
      issue: nil
    }
  ]
}

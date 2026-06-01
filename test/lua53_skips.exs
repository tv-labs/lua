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
    %{
      lines: 137..208,
      category: :unimplemented,
      reason:
        "harness drives every other suite file via dofile/loadfile/string.dump/coroutine.wrap, none supported in the sandbox",
      issue: 259
    },
    %{
      lines: 211..263,
      category: :unimplemented,
      reason: "post-run summary uses io.open and timing files unavailable in the sandbox",
      issue: 259
    }
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
      lines: 24..36,
      category: :stdlib,
      reason: "print does not call user-overridden _ENV.tostring at each invocation",
      issue: nil
    },
    %{
      lines: 135..137,
      category: :parser,
      reason:
        "parser treats `(fn)(args)` on a new line as a call on the previous expression (Lua 5.3 §3.3.1 ambiguity wart); test expects two statements",
      issue: nil
    },
    %{
      lines: 217..218,
      category: :stdlib,
      reason: "math.sin / table.sort reject extra args; PUC-Lua silently ignores them",
      issue: nil
    },
    %{
      lines: 219..401,
      category: :unimplemented,
      reason:
        "load() / string.dump / debug.getupvalue / coroutine.wrap and tail-call counting all exercised below this line; needs its own triage pass",
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
      lines: 284..299,
      category: :executor,
      reason:
        "short-circuit harness builds combinations up to level=4 (line 281); createcases(4) plus the load()/exec loop over every case exceeds the test timeout. The harness logic itself is verified green up to level 4 by test/lua/vm/short_circuit_test.exs",
      issue: 281
    },
    %{
      lines: 302..311,
      category: :stdlib,
      reason:
        "checkload asserts the load() error message contains 'expected'/'too long'; the suite-runner load() returns 'parse error: ...' for syntax errors and the compiler has no control-structure-too-long check",
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
    %{
      lines: 167..622,
      category: :unimplemented,
      reason:
        "collectgarbage is a no-op stub: step/stop/restart pacing, count shrinkage, weak tables and __gc finalizers not implemented",
      issue: 260
    }
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
  "locals.lua" => [],
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
    %{
      lines: 236..237,
      category: :unimplemented,
      reason:
        "pattern backreferences %0 and %1 inside a capture body should raise 'invalid capture index' (pattern-engine gap, not gsub replacement validation)",
      issue: 257
    },
    %{
      lines: 250..250,
      category: :unimplemented,
      reason: "'pattern too complex' recursion-depth limit not yet implemented",
      issue: 257
    },
    %{
      lines: 277..277,
      category: :unimplemented,
      reason: "gsub table replacement keyed on a multi-char capture not yet implemented",
      issue: 257
    },
    %{
      lines: 280..280,
      category: :unimplemented,
      reason: "gsub position-capture index into a replacement table not yet implemented",
      issue: 257
    },
    %{
      lines: 283..283,
      category: :unimplemented,
      reason: "gsub replacement via a table __index metamethod not yet implemented",
      issue: 257
    },
    %{
      lines: 312..339,
      category: :unimplemented,
      reason: "%f frontier pattern not yet implemented",
      issue: 257
    },
    %{
      lines: 341..358,
      category: :unimplemented,
      reason: "malformed-pattern error reporting (unfinished capture, %b, %f, trailing %) not yet implemented",
      issue: 257
    }
  ],
  "sort.lua" => [
    %{
      lines: :all,
      category: :stdlib,
      reason:
        "times out: the 2000-element unpack loop and O(n^2) table.sort over the perm/timesort sections run for minutes; the os.clock timing harness is also unimplemented",
      issue: 262
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

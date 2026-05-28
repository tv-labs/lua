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
      lines: 24..36,
      category: :stdlib,
      reason: "print does not call user-overridden _ENV.tostring at each invocation",
      issue: nil
    },
    %{
      lines: 65..69,
      category: :executor,
      reason:
        "stale upvalue cell across do blocks: register reused for a new local still resolves through the previous block's open_upvalues entry",
      issue: 276
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
      lines: 225..231,
      category: :stdlib,
      reason: "debug.getinfo(level, 'n') returns nil for name/namewhat",
      issue: 279
    },
    %{
      lines: 237..237,
      category: :stdlib,
      reason: "os.time missing; assignment to _ENV.GLOB1 fails",
      issue: 280
    },
    %{
      lines: 248..248,
      category: :stdlib,
      reason: "concatenates _ENV.GLOB1 (nil because os.time is missing)",
      issue: 280
    },
    %{
      lines: 284..299,
      category: :executor,
      reason:
        "short-circuit harness fails at level=4 deep composition; createcases(4) also exceeds the 60s test timeout (load() itself works)",
      issue: 281
    },
    %{
      lines: 302..311,
      category: :stdlib,
      reason:
        "checkload helper expects lowercase 'expected' and 'too long' in load() error messages; suite-runner load() uses title-cased parser errors and the compiler has no control-structure-too-long check",
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

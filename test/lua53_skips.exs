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
#                                 # | :performance
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
      category: :performance,
      reason:
        "1.0 exclusion (perf): runs >90s in isolation. Perf-bound on the BEAM tuple-copy ceiling; revisit in 1.0.x alongside B5 / the recursion-cost work (#324).",
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
      category: :performance,
      reason:
        "1.0 exclusion (perf): runs >90s in isolation. Perf-bound; revisit in 1.0.x alongside B5 / the recursion-cost work (#324).",
      issue: nil
    }
  ],
  "constructs.lua" => [
    %{
      lines: 284..299,
      category: :performance,
      reason:
        "createcases(4) plus the load()/exec loop over all 204105 combinations exceeds the 60s ExUnit default timeout; the VM result is correct (verified green up to level 4 by test/lua/vm/short_circuit_test.exs --include slow)",
      issue: nil
    },
    %{
      lines: 303..304,
      category: :stdlib,
      reason:
        "checkload asserts the load() error message contains 'expected'; the suite-runner load() returns 'parse error: ...' for syntax errors",
      issue: nil
    },
    %{
      lines: 306..311,
      category: :stdlib,
      reason:
        "checkload asserts the load() error message contains 'too long'; the compiler has no control-structure-too-long check",
      issue: nil
    }
  ],
  "coroutine.lua" => [
    %{
      lines: :all,
      category: :unimplemented,
      reason: "1.0 exclusion (capability non-goal): coroutines not implemented",
      issue: nil
    }
  ],
  "db.lua" => [
    %{
      lines: :all,
      category: :unimplemented,
      reason: "1.0 exclusion (capability non-goal): full debug library not implemented",
      issue: nil
    }
  ],
  "errors.lua" => [
    %{
      lines: :all,
      category: :stdlib,
      reason:
        "1.0 exclusion: checkmessage/checksyntax assert PUC-Lua `[string \"...\"]:N:` parse-error wording, but the suite-harness load() returns `parse error: ...`. Matching PUC error wording verbatim is out of scope for 1.0.",
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
      lines: 163..195,
      category: :stdlib,
      reason:
        "asserts upvalue cell identity via debug.upvalueid, which is a stub returning nil " <>
          "(upvalue-cell introspection not implemented). The goto control flow these closures " <>
          "exercise is still covered: the preceding `assert(#a == 6)` runs.",
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
      lines: 409..422,
      category: :unimplemented,
      reason:
        "very-long hex/decimal numerals (2^1200, 16^301) exceed the BEAM IEEE-754 float range (~2^1023), so tonumber and 2.0^exp overflow where PUC-Lua produces a finite or inf result",
      issue: nil
    },
    %{
      lines: 550..553,
      category: :unimplemented,
      reason:
        "`math.huge % x` should be NaN, but math.huge is the finite 1.0e308 stand-in so the modulo returns a real remainder (no true IEEE infinity on the BEAM)",
      issue: nil
    },
    %{
      lines: 695..695,
      category: :unimplemented,
      reason:
        "signed-zero division `1/-0.0` should yield -inf; the BEAM does not preserve the sign of zero through division and the inf stand-in is always positive",
      issue: nil
    },
    %{
      lines: 700..718,
      category: :unimplemented,
      reason:
        "true-infinity arithmetic (math.huge*2+1, inf-inf=NaN) and NaN-keyed table rawset depend on IEEE infinity/NaN the BEAM lacks; math.huge is a finite 1.0e308 stand-in",
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
      lines: 201..209,
      category: :semantic,
      reason:
        "table.sort with a deliberately-inconsistent comparator should raise 'invalid order function'; our insertion sort never detects it (PUC's quicksort-specific bounds check)",
      issue: 262
    },
    %{
      lines: 260..308,
      category: :performance,
      reason:
        "50000-element table.sort timing block: the comparator path is O(n^2) and one comparator calls load() (excluded in the sandbox). The perm block above (lines 240-249) and test/lua/vm/stdlib/table_test.exs cover plain `<` ordering on numbers/strings and explicit-comparator dispatch (including a comparator that drives a __lt metamethod). The trailing `setmetatable(.., {__lt=..}); table.sort(a)` case is NOT covered: our default (no-comparator) sort compares only numbers and strings and never dispatches __lt, so a default sort over table elements raises 'attempt to compare table with table' instead of ordering through __lt.",
      issue: 262
    }
  ],
  "strings.lua" => [
    %{
      lines: 199..206,
      category: :stdlib,
      reason:
        "string.format %s/%q does not dispatch the __tostring/__name metamethods (no per-arg tostring), so a table argument cannot be coerced to its literal form.",
      issue: nil
    },
    %{
      lines: 275..280,
      category: :semantic,
      reason:
        "%a/%A of 1/0 and 0/0 expect 'inf'/'nan', but the VM clamps division by zero to a finite 1.0e308 instead of an IEEE infinity.",
      issue: nil
    },
    %{
      lines: 371..376,
      category: :unimplemented,
      reason: "coroutine library is not implemented (coroutine.wrap).",
      issue: nil
    }
  ]
}

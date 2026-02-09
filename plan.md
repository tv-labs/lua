Completing the Lua 5.3 VM                                                     

 Context

 Phases 0-10 built the new VM (parser, compiler, executor, stdlib, value encoding/decoding). Phase 11+13 removed Luerl and integrated the new VM into the public Lua API. We now have
 900 passing tests with 25 pending and 0 failures.

 The VM works for core features but lacks: stack traces, pcall, string/math/table stdlib, metatables, userdata, require/package, and polished error messages. This plan completes the
 VM by implementing these features in dependency order, integrating the official Lua 5.3 test suite, and delivering beautiful error reporting.

 Phase 1: Source Line Tracking & Call Stack

 Goal: Compiler emits debug info, executor tracks it at runtime. Foundation for all error reporting.

 1A. Compiler: Emit source_line Instructions

 File: lib/lua/compiler/codegen.ex

 Every AST statement node has meta.start.line. Prepend a source_line(line, source) instruction before each statement in gen_block/2:

 defp emit_source_line(%{meta: %{start: %{line: line}}}, ctx) when is_integer(line) do
   [Instruction.source_line(line, ctx.source)]
 end
 defp emit_source_line(_, _), do: []

 Update the Prototype lines field to track {first_line, last_line} from the block's statements instead of hardcoding {1, 1}.

 1B. Executor: Handle source_line & Track Current Line

 File: lib/lua/vm/executor.ex

 Add handler clause:
 defp do_execute([{:source_line, line, _file} | rest], regs, upvalues, proto, state) do
   state = %{state | current_line: line}
   do_execute(rest, regs, upvalues, proto, state)
 end

 1C. Call Stack Push/Pop on Function Calls

 File: lib/lua/vm/executor.ex (:call handler at line 328)

 Before executing a callee, push a frame. After, pop it:
 frame = %{source: proto.source, line: state.current_line, name: func_name}
 state = %{state | call_stack: [frame | state.call_stack]}
 # ... execute callee ...
 state = %{state | call_stack: tl(state.call_stack)}

 1D. State Struct Updates

 File: lib/lua/vm/state.ex

 Add fields: current_line: 0, current_source: nil to the struct and typespec.

 Files Modified

 - lib/lua/compiler/codegen.ex — emit source_line before statements, compute line ranges
 - lib/lua/vm/executor.ex — handle source_line instruction, push/pop call stack frames
 - lib/lua/vm/state.ex — add current_line, current_source fields

 ---
 Phase 2: Beautiful Stack Traces & Error Messages

 Goal: Rich, ANSI-colored error output following the pattern in lib/lua/parser/error.ex.

 2A. Implement format_stacktrace in Lua.Util

 File: lib/lua/util.ex

 Replace the stub (def format_stacktrace(_, _, _), do: "") with real formatting. The call stack is a list of %{source: str, line: int, name: str | nil} maps. Output format:

 stack traceback:
     -no-source-:3: in function 'bar'
     -no-source-:7: in function 'foo'
     -no-source-:10: in main chunk

 This matches Lua 5.3's native debug.traceback() format.

 2B. Create Runtime Error Formatter

 File: NEW lib/lua/vm/error_formatter.ex

 Module Lua.VM.ErrorFormatter following the Lua.Parser.Error pattern:
 - ANSI-colored error type header
 - Clear error message
 - Source context with line numbers and ^ pointer
 - Stack trace
 - Suggestions for common mistakes (calling nil, arithmetic on strings, indexing non-tables)

 2C. Attach Call Stack to VM Errors

 Files: lib/lua/vm/type_error.ex, lib/lua/vm/runtime_error.ex, lib/lua/vm/assertion_error.ex

 Add optional call_stack: [] and line: nil fields. When executor raises, include the current state's call stack.

 2D. Enhance RuntimeException & CompilerException

 Files: lib/lua/runtime_exception.ex, lib/lua/compiler_exception.ex

 Include formatted stack traces in exception messages. Restore the TODO at compiler_exception.ex:26.

 2E. Comprehensive Error Test Suite

 File: NEW test/lua/error_messages_test.exs

 Test every error case for beautiful output:
 - Calling nil / non-function values
 - Arithmetic on non-numbers ("string" + 5)
 - Indexing non-tables (local x = 5; x.foo)
 - String concat with non-strings
 - Division by zero
 - Stack overflow (deep recursion)
 - Undefined global access (calling undefined function)
 - Comparison of incompatible types
 - Wrong number of arguments
 - Each test asserts the error message contains source location, stack trace, and clear description

 Tests Unblocked (10)

 - util_test.exs:60 — "it pretty prints a stacktrace"
 - util_test.exs:77 — "it can show function arities"
 - lua_test.exs:122 — "loading files with illegal tokens returns an error"
 - lua_test.exs:157 — "loading files with syntax errors returns an error"
 - lua_test.exs:179 — "loading files with undefined functions returns an error"
 - lua_test.exs:339 — "invalid functions raise"
 - lua_test.exs:690 — "calling non-functions raises"
 - lua_test.exs:748 — "function doesn't exist"
 - lua_test.exs:847 — "function doesn't exist in nested function"
 - lua_test.exs:876 — "api function that doesn't exist"

 ---
 Phase 3: pcall/xpcall

 Goal: Protected calls for error recovery, essential for robust Lua programs.

 3A. Add pcall/xpcall to Stdlib

 File: lib/lua/vm/stdlib.ex

 pcall(f, ...) — call f in protected mode. Returns true, results... on success, false, error_msg on failure.

 Implementation: native function that calls the closure through Lua.VM.Executor.execute/5 wrapped in try/rescue:

 defp lua_pcall([{:lua_closure, proto, upvalues} | args], state) do
   try do
     {results, _regs, state} = call_closure(proto, upvalues, args, state)
     {[true | results], state}
   rescue
     e in [RuntimeError, TypeError, AssertionError] ->
       {[false, extract_error_value(e)], state}
   end
 end

 Also handle {:native_func, fun} callees. xpcall(f, handler, ...) calls handler(msg) on error.

 3B. Extract Call Helper

 Refactor the :call instruction's function dispatch into a reusable call_value/3 public function so both the executor and pcall can share the call logic.

 Tests Unblocked (5)

 - lua_test.exs:283 — "it can register functions that take callbacks that modify state"
 - lua_test.exs:411 — "functions that raise errors still update state"
 - lua_test.exs:429 — "functions that raise errors from Elixir still update state"
 - lua_test.exs:595 — "api functions can return errors"
 - lua_test.exs:958 — "arithmetic exceptions are handled"

 ---
 Phase 4: Type-Safe Arithmetic & Comparisons

 Goal: Proper Lua 5.3 arithmetic semantics with clear error messages.

 File: lib/lua/vm/executor.ex

 4A. Arithmetic Type Checking

 Currently arithmetic operators use raw Elixir operators, which crash on non-numbers. Wrap each in type-checking helpers:
 - Check operands are numbers (or coerce strings to numbers per Lua 5.3 rules)
 - Raise TypeError with "attempt to perform arithmetic on a <type> value" on failure

 4B. Division by Zero

 - Integer // by zero → error
 - Float / by zero → inf / -inf / nan (Lua 5.3 behavior)
 - Integer % by zero → error

 4C. Comparison Safety

 - == and ~= work on any types (return false for different types)
 - <, <=, >, >= only work on numbers or strings (same type), raise TypeError otherwise
 - String comparison is lexicographic

 Tests Unblocked (1)

 - lua_test.exs:958 — "arithmetic exceptions are handled" (also benefits from Phase 3)

 ---
 Phase 5: String Standard Library

 Goal: Implement string.* functions enabling string manipulation.

 5A. Create String Stdlib

 File: NEW lib/lua/vm/stdlib/string.ex

 Priority functions:
 ┌──────────────────────────────────┬──────────────────────────────────┐
 │             Function             │            Complexity            │
 ├──────────────────────────────────┼──────────────────────────────────┤
 │ string.lower(s)                  │ Simple                           │
 ├──────────────────────────────────┼──────────────────────────────────┤
 │ string.upper(s)                  │ Simple                           │
 ├──────────────────────────────────┼──────────────────────────────────┤
 │ string.len(s)                    │ Simple                           │
 ├──────────────────────────────────┼──────────────────────────────────┤
 │ string.sub(s, i, j)              │ Simple                           │
 ├──────────────────────────────────┼──────────────────────────────────┤
 │ string.rep(s, n, sep)            │ Simple                           │
 ├──────────────────────────────────┼──────────────────────────────────┤
 │ string.reverse(s)                │ Simple                           │
 ├──────────────────────────────────┼──────────────────────────────────┤
 │ string.byte(s, i, j)             │ Simple                           │
 ├──────────────────────────────────┼──────────────────────────────────┤
 │ string.char(...)                 │ Simple                           │
 ├──────────────────────────────────┼──────────────────────────────────┤
 │ string.format(fmt, ...)          │ Medium — C-style format strings  │
 ├──────────────────────────────────┼──────────────────────────────────┤
 │ string.find(s, pat, init, plain) │ Medium-Hard — Lua pattern engine │
 ├──────────────────────────────────┼──────────────────────────────────┤
 │ string.match(s, pat, init)       │ Hard — Lua pattern engine        │
 ├──────────────────────────────────┼──────────────────────────────────┤
 │ string.gmatch(s, pat)            │ Hard — returns iterator          │
 ├──────────────────────────────────┼──────────────────────────────────┤
 │ string.gsub(s, pat, repl, n)     │ Hard — Lua pattern engine        │
 └──────────────────────────────────┴──────────────────────────────────┘
 Start with the simple functions. Implement string.format with common specifiers (%s, %d, %f, %i, %x, %%). Defer full Lua pattern matching to Phase 7 or later.

 5B. Register in Stdlib

 File: lib/lua/vm/stdlib.ex

 Create a string table, populate with native functions, set as global.

 5C. Restore Doctests

 File: lib/lua.ex

 Uncomment the string.lower doctests at lines 575, 586, and 667.

 Tests Unblocked (3+)

 - lua_test.exs:511 — "can call standard library functions"
 - lua_test.exs:530 — "can call references to functions"
 - lua_test.exs:539 — "it plays nicely with elixir function callbacks"
 - Plus 3 #iex> doctests in lib/lua.ex

 ---
 Phase 6: Math & Table Standard Libraries

 Goal: Complete the core stdlib trio (string + math + table).

 6A. Math Library

 File: NEW lib/lua/vm/stdlib/math.ex

 Functions: abs, ceil, floor, sqrt, sin, cos, tan, asin, acos, atan, exp, log, min, max, random, randomseed, huge, maxinteger, mininteger, pi, tointeger, type.

 Most delegate directly to Erlang :math module.

 6B. Table Library

 File: NEW lib/lua/vm/stdlib/table.ex

 Functions: insert, remove, concat, sort, pack, unpack, move.

 These operate on {:tref, id} values through State.get_table/update_table.

 6C. OS Library (minimal)

 File: NEW lib/lua/vm/stdlib/os.ex

 Minimal: os.clock(), os.time(), os.date(). The rest can be sandboxed.

 ---
 Phase 7: Metatables & Metamethods

 Goal: Core Lua OOP mechanism enabling __index, __newindex, __call, operator overloading.

 7A. Stdlib: setmetatable/getmetatable

 File: lib/lua/vm/stdlib.ex

 Add setmetatable(table, metatable) and getmetatable(table). The Table struct already has metatable: nil.

 7B. Executor: Metamethod Dispatch

 File: lib/lua/vm/executor.ex

 Modify these instruction handlers to check metamethods:
 - get_field / get_table — if key not found, check __index (can be table or function)
 - set_field / set_table — check __newindex
 - Arithmetic ops — check __add, __sub, __mul, __div, __mod, __pow, __unm
 - Comparisons — check __eq, __lt, __le
 - :call — check __call for non-function values
 - :length — check __len
 - :concat — check __concat
 - tostring — check __tostring

 The metamethod chain: table → metatable.__index → (if table) that table's metatable.__index → ...

 Tests Unblocked (1)

 - lua_test.exs:809 — "method that references property" (setmetatable + __index)

 ---
 Phase 8: Userdata & require/package

 8A. Userdata Support

 Files:
 - lib/lua/vm/state.ex — add userdata: %{}, userdata_next_id: 0
 - lib/lua/vm/value.ex — encode/decode {:userdata, value}
 - lib/lua/util.ex — add encoded?({:usdref, _}) clause
 - lib/lua/api.ex — fix is_userdata guard

 8B. require/package System

 Files:
 - lib/lua/vm/stdlib.ex — add require function and package table
 - lib/lua.ex — restore set_lua_paths/2 implementation (currently commented out at line 151)

 require(modname):
 1. Check package.loaded[modname]
 2. Search package.path templates (replace ? with modname)
 3. Load + execute found file
 4. Cache in package.loaded

 Tests Unblocked (6)

 - lua_test.exs:1256 — "it can return userdata"
 - lua_test.exs:1264 — "userdata must be encoded"
 - api_test.exs:342 — "can use in functions" (guards)
 - lua_test.exs:1330 — "it can find lua code when modifying package.path"
 - lua_test.exs:1344 — "we can use set_lua_paths/2 to add the paths"
 - lua_test.exs:1358 — "set_lua_paths/2 raises if package is sandboxed"

 ---
 Phase 9: Lua 5.3 Test Suite Integration

 Goal: Run the official Lua 5.3 test suite against our VM.

 9A. Download Test Suite

 Download from https://www.lua.org/tests/ into test/lua53_tests/.

 9B. Create Lua.TestCase ExUnit Module

 File: NEW test/support/lua_test_case.ex

 defmodule Lua.TestCase do
   use ExUnit.CaseTemplate

   @doc "Runs a .lua file, treating Lua assert() failures as ExUnit failures"
   def run_lua_file(path, opts \\ []) do
     source = File.read!(path)
     lua = Lua.new() |> install_test_helpers()
     Lua.eval!(lua, source)
   end
 end

 Install test helpers: override print for capture, ensure assert raises on failure, provide checkerr helper.

 9C. Create Test Wrappers

 File: NEW test/lua53_suite_test.exs

 One test per .lua file. Tag by readiness:
 - Ready now (after Phases 1-6): literals.lua, locals.lua, constructs.lua, bitwise.lua, vararg.lua
 - Ready after Phase 5-6: math.lua, strings.lua, sort.lua
 - Ready after Phase 7: events.lua (metatables), closure.lua, calls.lua
 - Deferred: coroutine.lua, goto.lua, db.lua, files.lua, gc.lua, cstack.lua

 9D. Iterative Gap-Filling

 Run each test file, triage failures:
 - Missing stdlib function → add to appropriate stdlib module
 - Missing language feature → implement or tag as pending
 - Semantic difference → fix VM behavior

 ---
 Phase 10: Remaining TODOs & Polish

 Source Code TODOs
 ┌──────────────────────────────────┬─────────────────────────────────┬─────────────┐
 │             Location             │              TODO               │ Resolved By │
 ├──────────────────────────────────┼─────────────────────────────────┼─────────────┤
 │ lib/lua/compiler.ex:34           │ Restore compiler error handling │ Phase 2     │
 ├──────────────────────────────────┼─────────────────────────────────┼─────────────┤
 │ lib/lua/compiler_exception.ex:26 │ Re-add stacktrace formatting    │ Phase 2     │
 ├──────────────────────────────────┼─────────────────────────────────┼─────────────┤
 │ lib/lua.ex:151                   │ Restore set_lua_paths           │ Phase 8     │
 ├──────────────────────────────────┼─────────────────────────────────┼─────────────┤
 │ lib/lua.ex:575,586,667           │ Restore string.lower doctests   │ Phase 5     │
 └──────────────────────────────────┴─────────────────────────────────┴─────────────┘
 Compiler Gaps (discovered during exploration)

 - Statement.LocalFunc — not compiled (catch-all returns {[], ctx})
 - Statement.Do — do...end blocks not compiled
 - tail_call — instruction exists but never emitted
 - Multi-assignment (a, b = 1, 2) — partially supported

 Deferred Features (future work)

 - Coroutines (coroutine.create/resume/yield)
 - goto / labels
 - Full debug library
 - Full io library
 - Weak tables (__mode)
 - Finalizers (__gc)
 - Full Lua pattern matching engine (complex; start with string.find plain mode)

 ---
 Phase Dependency Graph

 Phase 1 (Source Lines + Call Stack)
     │
     ▼
 Phase 2 (Stack Traces + Error Messages) ──────┐
     │                                          │
     ├──────────────┐                           │
     ▼              ▼                           │
 Phase 3          Phase 4                       │
 (pcall)          (Arithmetic Safety)           │
     │              │                           │
     ▼              ▼                           │
 Phase 5 (String Stdlib)                        │
     │                                          │
     ▼                                          │
 Phase 6 (Math + Table Stdlib)                  │
     │                                          │
     ▼                                          │
 Phase 7 (Metatables)                           │
     │                                          │
     ▼                                          │
 Phase 8 (Userdata + require)                   │
     │                                          │
     ▼                                          ▼
 Phase 9 (Lua 5.3 Test Suite) ◄────────────────┘
     │
     ▼
 Phase 10 (Polish + Remaining TODOs)

 Phases 3 & 4 can run in parallel. Phase 9 can start partially after Phase 2 (for basic test files) and expand as features land.

 Verification (per phase)

 mix compile --warnings-as-errors
 mix test --exclude pending    # all pass, no new failures
 mix test                      # check pending count decreases
 mix dialyzer                  # 0 errors

 After Phase 9: mix test --only lua53 to run the Lua 5.3 suite.

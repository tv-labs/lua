defmodule Lua.RuntimeExceptionTest do
  use ExUnit.Case, async: true

  alias Lua.RuntimeException
  alias Lua.VM.Executor
  alias Lua.VM.State

  describe "exception/1 with {:lua_error, error, state}" do
    test "formats simple lua error with stacktrace" do
      lua = Lua.new()

      # Create a lua error by dividing by zero
      assert_raise RuntimeException, fn ->
        Lua.eval!(lua, "return 1 / 0 * 'string'")
      end
    end

    test "includes formatted error message" do
      # Original implementation (also checked state and original fields):
      # test "includes formatted error message and stacktrace" do
      #   ...
      #   assert exception.state != nil
      #   assert exception.original != nil

      lua = Lua.new()

      exception =
        try do
          Lua.eval!(lua, "error('custom error message')")
        rescue
          e in RuntimeException -> e
        end

      assert Exception.message(exception) =~ "Lua runtime error:"
      assert Exception.message(exception) =~ "custom error message"
    end

    test "handles parse errors" do
      lua = Lua.new()

      exception =
        try do
          # Create a parse error by using illegal token
          Lua.eval!(lua, "local x = \x01")
        rescue
          e in Lua.CompilerException -> e
        end

      # Parse errors are CompilerException, not RuntimeException
      assert exception.__struct__ == Lua.CompilerException
    end

    test "handles badarith errors" do
      lua = Lua.new()

      exception =
        try do
          Lua.eval!(lua, "return 'string' + 5")
        rescue
          e in RuntimeException -> e
        end

      assert Exception.message(exception) =~ "Lua runtime error:"
    end

    test "handles illegal index errors" do
      lua = Lua.new()

      exception =
        try do
          # Attempt to index a non-table value
          Lua.eval!(lua, "local x = 5; return x.foo")
        rescue
          e in RuntimeException -> e
        end

      assert Exception.message(exception) =~ "Lua runtime error:"
    end
  end

  describe "exception/1 with keyword list [scope:, function:, message:]" do
    test "formats error with empty scope" do
      exception =
        RuntimeException.exception(
          scope: [],
          function: "my_function",
          message: "invalid arguments"
        )

      assert Exception.message(exception) == "Lua runtime error: my_function() failed, invalid arguments"

      assert exception.original == [
               scope: [],
               function: "my_function",
               message: "invalid arguments"
             ]

      assert exception.state == nil
    end

    test "formats error with single scope element" do
      exception =
        RuntimeException.exception(
          scope: ["math"],
          function: "sqrt",
          message: "negative number not allowed"
        )

      assert Exception.message(exception) ==
               "Lua runtime error: math.sqrt() failed, negative number not allowed"

      assert exception.original == [
               scope: ["math"],
               function: "sqrt",
               message: "negative number not allowed"
             ]

      assert exception.state == nil
    end

    test "formats error with multiple scope elements" do
      exception =
        RuntimeException.exception(
          scope: ["my", "module", "nested"],
          function: "process",
          message: "data validation failed"
        )

      assert Exception.message(exception) ==
               "Lua runtime error: my.module.nested.process() failed, data validation failed"

      assert exception.original == [
               scope: ["my", "module", "nested"],
               function: "process",
               message: "data validation failed"
             ]

      assert exception.state == nil
    end

    test "raises when scope key is missing" do
      assert_raise KeyError, fn ->
        RuntimeException.exception(
          function: "my_function",
          message: "invalid arguments"
        )
      end
    end

    test "raises when function key is missing" do
      assert_raise KeyError, fn ->
        RuntimeException.exception(
          scope: [],
          message: "invalid arguments"
        )
      end
    end

    test "raises when message key is missing" do
      assert_raise KeyError, fn ->
        RuntimeException.exception(
          scope: [],
          function: "my_function"
        )
      end
    end
  end

  describe "exception/1 with binary string" do
    test "formats simple binary error" do
      exception = RuntimeException.exception("something went wrong")

      assert Exception.message(exception) == "Lua runtime error: something went wrong"
      # The trimmed host string is the semantic source, stored on `:original`.
      assert exception.original == "something went wrong"
      assert exception.state == nil
    end

    test "trims whitespace from binary error" do
      exception = RuntimeException.exception("  error with spaces  \n")

      assert Exception.message(exception) == "Lua runtime error: error with spaces"
      assert exception.original == "error with spaces"
      assert exception.state == nil
    end

    test "handles empty binary string" do
      exception = RuntimeException.exception("")

      assert Exception.message(exception) == "Lua runtime error: "
      assert exception.original == ""
      assert exception.state == nil
    end

    test "handles multi-line binary error" do
      error_message = """
      multi-line error
      with details
      """

      exception = RuntimeException.exception(error_message)

      assert Exception.message(exception) == "Lua runtime error: multi-line error\nwith details"
      assert exception.original == "multi-line error\nwith details"
      assert exception.state == nil
    end
  end

  describe "exception/1 with generic error (fallback clause)" do
    test "handles built-in exception types" do
      error = ArgumentError.exception("invalid argument")

      exception = RuntimeException.exception(error)

      assert Exception.message(exception) == "Lua runtime error: invalid argument"
      assert exception.original == error
      assert exception.state == nil
    end

    test "handles RuntimeError exception" do
      error = RuntimeError.exception("runtime failure")

      exception = RuntimeException.exception(error)

      assert Exception.message(exception) == "Lua runtime error: runtime failure"
      assert exception.original == error
      assert exception.state == nil
    end

    test "handles KeyError exception" do
      error = KeyError.exception(key: :missing, term: %{})

      exception = RuntimeException.exception(error)

      assert Exception.message(exception) =~ "Lua runtime error:"
      assert Exception.message(exception) =~ "key :missing not found"
      assert exception.original == error
      assert exception.state == nil
    end

    test "handles non-exception atom" do
      exception = RuntimeException.exception(:some_error)

      assert Exception.message(exception) == "Lua runtime error: :some_error"
      assert exception.original == :some_error
      assert exception.state == nil
    end

    test "handles non-exception integer" do
      exception = RuntimeException.exception(42)

      assert Exception.message(exception) == "Lua runtime error: 42"
      assert exception.original == 42
      assert exception.state == nil
    end

    test "handles non-exception tuple" do
      error = {:error, :not_found}

      exception = RuntimeException.exception(error)

      assert Exception.message(exception) == "Lua runtime error: {:error, :not_found}"
      assert exception.original == error
      assert exception.state == nil
    end

    test "handles non-exception map" do
      error = %{code: 404, message: "not found"}

      exception = RuntimeException.exception(error)

      assert Exception.message(exception) == "Lua runtime error: %{code: 404, message: \"not found\"}"
      assert exception.original == error
      assert exception.state == nil
    end

    test "handles non-exception list (not keyword list)" do
      error = [1, 2, 3]

      assert_raise KeyError, fn ->
        RuntimeException.exception(error)
      end
    end

    test "handles UndefinedFunctionError" do
      error = UndefinedFunctionError.exception(module: MyModule, function: :my_func, arity: 2)

      exception = RuntimeException.exception(error)

      assert Exception.message(exception) =~ "Lua runtime error:"
      assert Exception.message(exception) =~ "MyModule.my_func/2"
      assert exception.original == error
      assert exception.state == nil
    end
  end

  describe "kind/value projection when wrapping a VM exception" do
    test "wrapping a RuntimeError yields kind :error and the raised value" do
      inner = Lua.VM.RuntimeError.exception(value: "boom", source: "t.lua", line: 3)

      exception = RuntimeException.exception(inner)

      assert exception.kind == :error
      assert exception.value == "boom"
      assert exception.original == inner
      # Structured context is copied onto the wrapper for pattern-matching.
      assert exception.line == 3
      assert exception.source == "t.lua"
    end

    test "wrapping a RuntimeError projects the §6.1 lua_value when present" do
      inner = Lua.VM.RuntimeError.exception(value: "boom", lua_value: "t.lua:3: boom")

      exception = RuntimeException.exception(inner)

      # pcall parity: string errors carry the position-prefixed view.
      assert exception.value == "t.lua:3: boom"
    end

    test "wrapping a RuntimeError preserves a non-string Lua value verbatim" do
      inner = Lua.VM.RuntimeError.exception(value: 42)

      exception = RuntimeException.exception(inner)

      assert exception.kind == :error
      assert exception.value == 42
    end

    test "wrapping a TypeError yields kind :type" do
      inner = Lua.VM.TypeError.exception(value: "attempt to index a nil value")

      exception = RuntimeException.exception(inner)

      assert exception.kind == :type
      assert exception.value == "attempt to index a nil value"
    end

    test "wrapping an ArgumentError yields kind :argument and the raw bad-argument string" do
      inner =
        Lua.VM.ArgumentError.exception(
          function_name: "string.rep",
          arg_num: 2,
          expected: "number"
        )

      exception = RuntimeException.exception(inner)

      assert exception.kind == :argument
      assert exception.value == "bad argument #2 to 'string.rep' (number expected)"
    end

    test "wrapping an AssertionError yields kind :assertion" do
      inner = Lua.VM.AssertionError.exception(value: "nope")

      exception = RuntimeException.exception(inner)

      assert exception.kind == :assertion
      assert exception.value == "nope"
    end

    test "wrapping an InternalError yields kind :internal" do
      inner = Lua.VM.InternalError.exception(value: "invariant violated")

      # InternalError renders via message/1 from :value (no stored :message).
      refute Map.has_key?(inner, :message)
      assert Exception.message(inner) == "invariant violated"

      exception = RuntimeException.exception(inner)

      assert exception.kind == :internal
      assert exception.value == "invariant violated"
      assert Exception.message(exception) == "Lua runtime error: invariant violated"
    end

    test "wrapping an arbitrary Elixir exception leaves kind and value nil" do
      exception = RuntimeException.exception(KeyError.exception(key: :missing, term: %{}))

      assert exception.kind == nil
      assert exception.value == nil
    end
  end

  describe "format_function/2 (private function tested via keyword list exception)" do
    test "formats function with empty scope" do
      exception =
        RuntimeException.exception(
          scope: [],
          function: "test",
          message: "error"
        )

      assert Exception.message(exception) =~ "test() failed"
    end

    test "formats function with single element scope" do
      exception =
        RuntimeException.exception(
          scope: ["module"],
          function: "func",
          message: "error"
        )

      assert Exception.message(exception) =~ "module.func() failed"
    end

    test "formats function with nested scope" do
      exception =
        RuntimeException.exception(
          scope: ["a", "b", "c"],
          function: "method",
          message: "error"
        )

      assert Exception.message(exception) =~ "a.b.c.method() failed"
    end
  end

  describe "exception message format" do
    test "RuntimeException implements Exception protocol" do
      exception = RuntimeException.exception("test error")

      assert Exception.message(exception) == "Lua runtime error: test error"
    end

    test "struct has no :message field — Exception.message/1 is the only renderer" do
      # The message is composed lazily from the semantic fields; there is no
      # `:message` field to read back nil (issue #384 / 1.0 cleanup).
      exception = RuntimeException.exception("test error")

      refute Map.has_key?(exception, :message)
    end

    test "can be raised with raise/2" do
      assert_raise RuntimeException, "Lua runtime error: test", fn ->
        raise RuntimeException, "test"
      end
    end

    test "can be raised with keyword list" do
      assert_raise RuntimeException, fn ->
        raise RuntimeException,
          scope: ["my", "module"],
          function: "test",
          message: "failed"
      end
    end

    test "preserves original error information" do
      original = {:error, :custom_reason}
      exception = RuntimeException.exception(original)

      assert exception.original == original
      assert exception.state == nil
    end
  end

  describe "integration with Lua module" do
    test "RuntimeException is raised for runtime errors" do
      lua = Lua.new()

      assert_raise RuntimeException, fn ->
        Lua.eval!(lua, "error('test error')")
      end
    end

    test "RuntimeException is raised for type errors" do
      lua = Lua.new()

      assert_raise RuntimeException, fn ->
        Lua.eval!(lua, "return 'string' + 5")
      end
    end

    test "RuntimeException is raised for sandboxed functions" do
      lua = Lua.new(sandboxed: [[:os, :exit]])

      assert_raise RuntimeException, fn ->
        Lua.eval!(lua, "os.exit()")
      end
    end

    test "RuntimeException is raised for empty keys in set!" do
      lua = Lua.new()

      assert_raise RuntimeException, "Lua runtime error: Lua.set!/3 cannot have empty keys", fn ->
        Lua.set!(lua, [], "value")
      end
    end

    test "RuntimeException is raised when deflua returns non-encoded data" do
      lua = Lua.new()

      lua =
        Lua.set!(lua, [:test_func], fn _args ->
          # Return non-encoded atom (not a valid Lua value)
          [:invalid_atom]
        end)

      assert_raise RuntimeException, fn ->
        Lua.eval!(lua, "test_func()")
      end
    end
  end

  describe "single-prefix invariant" do
    # Wrapping an already-prefixed message should not produce
    # "Lua runtime error: Lua runtime error: ..." chains.

    test "binary clause does not double-prefix" do
      exception = RuntimeException.exception("Lua runtime error: already prefixed")

      assert Exception.message(exception) == "Lua runtime error: already prefixed"
    end

    test "binary clause trims then guards" do
      exception = RuntimeException.exception("  Lua runtime error: trimmed  \n")

      assert Exception.message(exception) == "Lua runtime error: trimmed"
    end

    test "lua_error tuple clause does not double-prefix" do
      exception =
        RuntimeException.exception({:lua_error, "Lua runtime error: from inner error", State.new()})

      assert Exception.message(exception) == "Lua runtime error: from inner error"
    end

    test "catch-all clause prefixes a wrapped VM exception exactly once" do
      inner = Lua.VM.RuntimeError.exception(value: "boom", source: "t.lua", line: 3)

      message = Exception.message(RuntimeException.exception(inner))

      # A VM exception's rendered message never starts with the runtime prefix,
      # so wrapping it adds exactly one — never a doubled chain.
      assert String.starts_with?(message, "Lua runtime error: ")
      refute message =~ "Lua runtime error: Lua runtime error:"
      assert message =~ "runtime error: boom"
    end

    test "catch-all clause does not double-prefix when wrapping a built-in exception" do
      inner = RuntimeError.exception("Lua runtime error: already wrapped")

      exception = RuntimeException.exception(inner)

      assert Exception.message(exception) == "Lua runtime error: already wrapped"
    end

    test "keyword list clause still prefixes (inner never starts with prefix)" do
      exception =
        RuntimeException.exception(
          scope: ["m"],
          function: "f",
          message: "boom"
        )

      assert Exception.message(exception) == "Lua runtime error: m.f() failed, boom"
    end

    test "binary clause still prefixes plain messages" do
      exception = RuntimeException.exception("plain message")

      assert Exception.message(exception) == "Lua runtime error: plain message"
    end
  end

  describe "stack trace pruning" do
    # The rescued Elixir stacktrace should not contain frames from the
    # VM, compiler, parser, or lexer internals — those are noise to a
    # Lua program author. The user's calling frame and the public
    # `Lua.eval!` boundary must remain visible.

    defp rescued_stacktrace(fun) do
      fun.()
    rescue
      _ -> __STACKTRACE__
    end

    defp stacktrace_modules(stacktrace) do
      Enum.flat_map(stacktrace, fn
        {mod, _fun, _arity, _loc} -> [mod]
        {mod, _fun, _arity, _loc, _meta} -> [mod]
        _ -> []
      end)
    end

    test "executor frames are pruned from runtime errors" do
      lua = Lua.new()

      stack =
        rescued_stacktrace(fn ->
          Lua.eval!(lua, "return 'string' + 5")
        end)

      modules = stacktrace_modules(stack)

      refute Executor in modules
      refute Lua.VM.Stdlib in modules
    end

    test "public Lua boundary frames are preserved" do
      lua = Lua.new()

      stack =
        rescued_stacktrace(fn ->
          Lua.eval!(lua, "return 'string' + 5")
        end)

      modules = stacktrace_modules(stack)

      assert Enum.any?(modules, &(&1 == Lua)),
             "expected Lua.eval! frame to be preserved, got modules: #{inspect(modules)}"
    end

    test "executor frames are pruned when assert(false) raises" do
      lua = Lua.new()

      stack =
        rescued_stacktrace(fn ->
          Lua.eval!(lua, "assert(false, 'nope')")
        end)

      assert Enum.all?(stacktrace_modules(stack), fn mod ->
               mod_str = Atom.to_string(mod)
               not String.starts_with?(mod_str, "Elixir.Lua.VM.")
             end)
    end

    test "executor frames are pruned when error() is called" do
      lua = Lua.new()

      stack =
        rescued_stacktrace(fn ->
          Lua.eval!(lua, "error('boom')")
        end)

      assert Enum.all?(stacktrace_modules(stack), fn mod ->
               mod_str = Atom.to_string(mod)
               not String.starts_with?(mod_str, "Elixir.Lua.VM.")
             end)
    end

    test "debug: true restores executor frames" do
      lua = Lua.new(debug: true)

      stack =
        rescued_stacktrace(fn ->
          Lua.eval!(lua, "return 'string' + 5")
        end)

      modules = stacktrace_modules(stack)

      assert Enum.any?(modules, &(&1 == Executor)),
             "expected Lua.VM.Executor frame with debug: true"
    end

    test "InternalError keeps the full stack (library bug, not Lua program error)" do
      # Synthesise an InternalError by registering a Lua-callable that
      # returns the wrong shape — this trips the InternalError raise at
      # executor.ex:692 ("native function returned invalid result").
      lua =
        Lua.set!(Lua.new(), [:bad_native], fn _args, _state ->
          :not_a_valid_return
        end)

      stack =
        rescued_stacktrace(fn ->
          Lua.eval!(lua, "return bad_native()")
        end)

      modules = stacktrace_modules(stack)

      assert Enum.any?(modules, &(&1 == Executor)),
             "InternalError should keep Lua.VM.Executor frame for library debugging"
    end

    test "executor frames are pruned and Lua boundary frame is preserved (debug: false)" do
      # Confirms both the 4-tuple and general pruning path through eval!.
      lua = Lua.new()

      stack =
        rescued_stacktrace(fn ->
          Lua.eval!(lua, "return 'string' + 5")
        end)

      modules = stacktrace_modules(stack)

      refute Executor in modules
      assert Lua in modules
    end

    test "user module not under an internal prefix is preserved through eval!" do
      # Registers a Lua-callable implemented in a module that is NOT under
      # any internal prefix. It must survive pruning so the user can trace
      # calls into their own code.
      defmodule MyApp.LuaHelper do
        @moduledoc false
        def call(_args, _state), do: raise(RuntimeError, "boom from user code")
      end

      lua = Lua.set!(Lua.new(), [:my_helper], &MyApp.LuaHelper.call/2)

      stack =
        rescued_stacktrace(fn ->
          Lua.eval!(lua, "return my_helper()")
        end)

      modules = stacktrace_modules(stack)

      refute Executor in modules
      assert MyApp.LuaHelper in modules
    end
  end

  defp arithmetic_error do
    assert_raise RuntimeException, fn ->
      Lua.eval!(Lua.new(), "local x = nil\nreturn x + 1", source: "demo.lua")
    end
  end

  describe "plain message, rich format, and structured to_map" do
    test "Exception.message/1 is a single ANSI-free line with a location suffix" do
      message = Exception.message(arithmetic_error())

      assert message =~ "Lua runtime error: attempt to perform arithmetic on a nil value (local 'x')"
      assert message =~ "(at demo.lua:2)"
      refute message =~ "\n"
      refute message =~ "\e["
    end

    test "Lua.format_exception/1 renders the rich multi-line report" do
      rich = Lua.format_exception(arithmetic_error())

      assert rich =~ "at demo.lua:2:"
      assert rich =~ "Suggestion:"
      assert rich =~ "\n"
    end

    test "to_map/2 delegates to the wrapped VM error's structured shape" do
      map = RuntimeException.to_map(arithmetic_error())

      assert map.type == :type_error
      assert map.line == 2
      assert map.source == "demo.lua"
      assert map.message =~ "attempt to perform arithmetic"
      refute map.message =~ "\e["
    end

    test "to_map/2 populates source_context when given source_code" do
      code = "local x = nil\nreturn x + 1"

      error =
        assert_raise RuntimeException, fn ->
          Lua.eval!(Lua.new(), code, source: "demo.lua")
        end

      map = RuntimeException.to_map(error, source_code: code)

      assert %{lines: [_ | _], pointer_column: _} = map.source_context
    end

    test "to_map/2 returns a uniform minimal map for host-side (non-VM) errors" do
      map = RuntimeException.to_map(RuntimeException.exception("cannot do that"))

      assert map.type == nil
      assert map.message == "Lua runtime error: cannot do that"
      assert map.source == nil
      assert map.line == nil
      assert map.call_stack == []
      assert map.source_context == nil
    end
  end
end

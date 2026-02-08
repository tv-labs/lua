defmodule Lua.RuntimeExceptionTest do
  use ExUnit.Case, async: true
  alias Lua.RuntimeException

  describe "exception/1 with {:lua_error, error, state}" do
    test "formats simple lua error with stacktrace" do
      lua = Lua.new()

      # Create a lua error by dividing by zero
      assert_raise RuntimeException, fn ->
        Lua.eval!(lua, "return 1 / 0 * 'string'")
      end
    end

    test "includes formatted error message" do
      lua = Lua.new()

      exception =
        try do
          Lua.eval!(lua, "error('custom error message')")
        rescue
          e in RuntimeException -> e
        end

      assert exception.message =~ "Lua runtime error:"
      assert exception.message =~ "custom error message"
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

      assert exception.message =~ "Lua runtime error:"
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

      assert exception.message =~ "Lua runtime error:"
    end
  end

  describe "exception/1 with {:api_error, details, state}" do
    test "creates exception with api error message" do
      state = Lua.VM.State.new()
      details = "invalid function call"

      exception = RuntimeException.exception({:api_error, details, state})

      assert exception.message == "Lua API error: invalid function call"
      assert exception.original == details
      assert exception.state == state
    end

    test "handles complex api error details" do
      state = Lua.VM.State.new()
      details = "function returned invalid type: expected table, got nil"

      exception = RuntimeException.exception({:api_error, details, state})

      assert exception.message ==
               "Lua API error: function returned invalid type: expected table, got nil"

      assert exception.original == details
      assert exception.state == state
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

      assert exception.message == "Lua runtime error: my_function() failed, invalid arguments"

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

      assert exception.message ==
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

      assert exception.message ==
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

      assert exception.message == "Lua runtime error: something went wrong"
      assert exception.original == nil
      assert exception.state == nil
    end

    test "trims whitespace from binary error" do
      exception = RuntimeException.exception("  error with spaces  \n")

      assert exception.message == "Lua runtime error: error with spaces"
      assert exception.original == nil
      assert exception.state == nil
    end

    test "handles empty binary string" do
      exception = RuntimeException.exception("")

      assert exception.message == "Lua runtime error: "
      assert exception.original == nil
      assert exception.state == nil
    end

    test "handles multi-line binary error" do
      error_message = """
      multi-line error
      with details
      """

      exception = RuntimeException.exception(error_message)

      assert exception.message == "Lua runtime error: multi-line error\nwith details"
      assert exception.original == nil
      assert exception.state == nil
    end
  end

  describe "exception/1 with generic error (fallback clause)" do
    test "handles built-in exception types" do
      error = ArgumentError.exception("invalid argument")

      exception = RuntimeException.exception(error)

      assert exception.message == "Lua runtime error: invalid argument"
      assert exception.original == error
      assert exception.state == nil
    end

    test "handles RuntimeError exception" do
      error = RuntimeError.exception("runtime failure")

      exception = RuntimeException.exception(error)

      assert exception.message == "Lua runtime error: runtime failure"
      assert exception.original == error
      assert exception.state == nil
    end

    test "handles KeyError exception" do
      error = KeyError.exception(key: :missing, term: %{})

      exception = RuntimeException.exception(error)

      assert exception.message =~ "Lua runtime error:"
      assert exception.message =~ "key :missing not found"
      assert exception.original == error
      assert exception.state == nil
    end

    test "handles non-exception atom" do
      exception = RuntimeException.exception(:some_error)

      assert exception.message == "Lua runtime error: :some_error"
      assert exception.original == :some_error
      assert exception.state == nil
    end

    test "handles non-exception integer" do
      exception = RuntimeException.exception(42)

      assert exception.message == "Lua runtime error: 42"
      assert exception.original == 42
      assert exception.state == nil
    end

    test "handles non-exception tuple" do
      error = {:error, :not_found}

      exception = RuntimeException.exception(error)

      assert exception.message == "Lua runtime error: {:error, :not_found}"
      assert exception.original == error
      assert exception.state == nil
    end

    test "handles non-exception map" do
      error = %{code: 404, message: "not found"}

      exception = RuntimeException.exception(error)

      assert exception.message == "Lua runtime error: %{code: 404, message: \"not found\"}"
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

      assert exception.message =~ "Lua runtime error:"
      assert exception.message =~ "MyModule.my_func/2"
      assert exception.original == error
      assert exception.state == nil
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

      assert exception.message =~ "test() failed"
    end

    test "formats function with single element scope" do
      exception =
        RuntimeException.exception(
          scope: ["module"],
          function: "func",
          message: "error"
        )

      assert exception.message =~ "module.func() failed"
    end

    test "formats function with nested scope" do
      exception =
        RuntimeException.exception(
          scope: ["a", "b", "c"],
          function: "method",
          message: "error"
        )

      assert exception.message =~ "a.b.c.method() failed"
    end
  end

  describe "exception message format" do
    test "RuntimeException implements Exception protocol" do
      exception = RuntimeException.exception("test error")

      assert Exception.message(exception) == "Lua runtime error: test error"
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
end

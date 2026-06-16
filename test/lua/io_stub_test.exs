defmodule Lua.IoStubTest do
  @moduledoc """
  Regression tests pinning the shape of the sandboxed `io` library.

  Reference Lua 5.3 exposes `io` as a table whose keys are functions
  (and the `stdin`/`stdout`/`stderr` file handles). In a sandboxed VM
  every entry is a stub that raises on call, but the surrounding
  table-of-functions shape is preserved so that user code lifting
  patterns from the wider Lua ecosystem (and our own Lua 5.3 test
  suite, e.g. `events.lua` line 188 `pcall(rawlen, io.stdin)`) doesn't
  trip on `attempt to index a function value`.
  """

  use ExUnit.Case, async: true

  describe "io shape" do
    test "io is a table, not a function" do
      assert {["table"], _} = Lua.eval!(Lua.new(), "return type(io)")
    end

    test "io.stdin, io.stdout, io.stderr are accessible without raising" do
      # The exact type these resolve to is an implementation detail of
      # how we sandbox; we only require that indexing them does not
      # itself raise.
      assert {[type], _} = Lua.eval!(Lua.new(), "return type(io.stdin)")
      assert is_binary(type)

      assert {[type], _} = Lua.eval!(Lua.new(), "return type(io.stdout)")
      assert is_binary(type)

      assert {[type], _} = Lua.eval!(Lua.new(), "return type(io.stderr)")
      assert is_binary(type)
    end
  end

  describe "sandboxed io functions" do
    test "io.write raises with a sandboxed message mirroring os.execute" do
      assert_raise Lua.RuntimeException,
                   "Lua runtime error: io.write(_) is sandboxed",
                   fn ->
                     Lua.eval!(Lua.new(), ~S[io.write("x")])
                   end
    end

    test "io.read raises with a sandboxed message" do
      assert_raise Lua.RuntimeException,
                   "Lua runtime error: io.read() is sandboxed",
                   fn ->
                     Lua.eval!(Lua.new(), "io.read()")
                   end
    end

    for fn_name <- ~w(open close lines popen tmpfile output input flush type) do
      test "io.#{fn_name} raises with a sandboxed message" do
        code = "io.#{unquote(fn_name)}()"
        message = "Lua runtime error: io.#{unquote(fn_name)}() is sandboxed"

        assert_raise Lua.RuntimeException, message, fn ->
          Lua.eval!(Lua.new(), code)
        end
      end
    end

    test "pcall(io.write, 'x') returns false plus the sandbox message" do
      assert {[false, "Lua runtime error: io.write(_) is sandboxed"], _} =
               Lua.eval!(Lua.new(), ~S[return pcall(io.write, "x")])
    end
  end

  describe "rawlen on non-table, non-string values" do
    # The `events.lua` test suite at line 188 asserts
    # `not pcall(rawlen, io.stdin)`. For that to evaluate to `true`,
    # rawlen has to *raise* on a non-table/non-string argument so the
    # surrounding pcall returns `false, <error>`. Reference Lua 5.3
    # raises "table or string expected"; the previous implementation
    # silently returned 0.
    test "pcall(rawlen, io.stdin) returns false with a type error" do
      assert {[false, message], _} =
               Lua.eval!(Lua.new(), "return pcall(rawlen, io.stdin)")

      assert message =~ "rawlen"
      assert message =~ "table or string expected"
    end

    test "rawlen on a number raises" do
      assert {[false, message], _} =
               Lua.eval!(Lua.new(sandbox: false), "return pcall(rawlen, 34)")

      assert message =~ "rawlen"
      assert message =~ "number"
    end

    test "rawlen with no arguments raises" do
      assert {[false, message], _} =
               Lua.eval!(Lua.new(sandbox: false), "return pcall(rawlen)")

      assert message =~ "rawlen"
      assert message =~ "value expected"
    end

    test "rawlen on a function raises" do
      code = """
      local f = function() end
      return pcall(rawlen, f)
      """

      assert {[false, message], _} = Lua.eval!(Lua.new(sandbox: false), code)
      assert message =~ "function"
    end

    test "rawlen on a table still returns its sequence length" do
      assert {[3], _} =
               Lua.eval!(Lua.new(sandbox: false), "return rawlen({10, 20, 30})")
    end

    test "rawlen on a string still returns its byte size" do
      assert {[5], _} =
               Lua.eval!(Lua.new(sandbox: false), ~S[return rawlen("hello")])
    end
  end
end

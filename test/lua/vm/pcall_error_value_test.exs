defmodule Lua.VM.PcallErrorValueTest do
  @moduledoc """
  Pins Lua 5.3 §6.1 `error` / `pcall` / `xpcall` error-value semantics:
  `error(value)` raises an arbitrary Lua value and `pcall` returns that
  value AS-IS as its second result — never a stringification. For string
  messages (and `level ~= 0`), `error` prepends a `source:line:` position
  prefix; `level == 0` suppresses it. Non-string values are never
  prefixed.

  Reference behavior (PUC Lua 5.3):

      $ lua -e 'local ok, err = pcall(function() error({code = 1}) end); print(ok, type(err), err.code)'
      false   table   1
      $ lua -e 'local ok, err = pcall(function() error(42) end); print(ok, type(err), err)'
      false   number  42
      $ lua -e 'local ok, err = pcall(function() error("boom") end); print(ok, type(err), err)'
      false   string  (command line):1: boom

  Each case runs under both execution engines: the default compile path
  (closures carry bytecode and run on the dispatcher) and with bytecode
  recursively stripped (closures run on the instruction interpreter).
  The position prefix is asserted with the correct source and line under
  the interpreter; under the dispatcher the per-call line is not yet
  plumbed, so the prefix is suppressed rather than attributed to a stale
  line.
  """
  use ExUnit.Case, async: true

  alias Lua.Compiler
  alias Lua.Compiler.Prototype
  alias Lua.Parser
  alias Lua.VM
  alias Lua.VM.State
  alias Lua.VM.Stdlib

  defp run(code, engine) do
    {:ok, ast} = Parser.parse(code)
    {:ok, proto} = Compiler.compile(ast, source: "test.lua")

    proto =
      case engine do
        :compiled -> proto
        :interpreted -> strip_bytecode(proto)
      end

    state = Stdlib.install(State.new())
    {:ok, results, state} = VM.execute(proto, state)
    {results, state}
  end

  # Forces every closure onto the instruction interpreter — the closure
  # tag flips on `proto.bytecode`, so stripping it recursively keeps the
  # whole program off the dispatcher.
  defp strip_bytecode(%Prototype{} = proto) do
    %{proto | bytecode: nil, prototypes: Enum.map(proto.prototypes, &strip_bytecode/1)}
  end

  for engine <- [:compiled, :interpreted] do
    @engine engine

    describe "pcall returns the raw error value (#{engine} engine)" do
      test "error with a table object passes the table through" do
        {results, _state} =
          run(
            """
            local ok, err = pcall(function()
              error({code = 1})
            end)
            return ok, type(err), err and err.code
            """,
            @engine
          )

        assert results == [false, "table", 1]
      end

      test "error with a number passes the number through" do
        {results, _state} =
          run(
            """
            local ok, err = pcall(function()
              error(42)
            end)
            return ok, type(err), err
            """,
            @engine
          )

        assert results == [false, "number", 42]
      end

      test "error with true passes the boolean through" do
        {results, _state} =
          run(
            """
            local ok, err = pcall(function()
              error(true)
            end)
            return ok, type(err), err
            """,
            @engine
          )

        assert results == [false, "boolean", true]
      end

      test "error with false passes false through (falsy-but-present value)" do
        {results, _state} =
          run(
            """
            local ok, err = pcall(function()
              error(false)
            end)
            return ok, type(err), err
            """,
            @engine
          )

        assert results == [false, "boolean", false]
      end

      test "error with no argument returns nil" do
        {results, _state} =
          run(
            """
            local ok, err = pcall(function()
              error()
            end)
            return ok, err == nil
            """,
            @engine
          )

        assert results == [false, true]
      end

      test "error with explicit nil returns nil" do
        {results, _state} =
          run(
            """
            local ok, err = pcall(function()
              error(nil)
            end)
            return ok, err == nil
            """,
            @engine
          )

        assert results == [false, true]
      end
    end

    describe "error() position prefix on string messages (#{engine} engine)" do
      test "string error carries the §6.1 source:line: prefix" do
        {results, _state} =
          run(
            """
            local ok, err = pcall(function()
              error("boom")
            end)
            return ok, type(err), err
            """,
            @engine
          )

        assert [false, "string", err] = results

        case @engine do
          :interpreted ->
            # Source-first shape: a swapped `{line, source}` destructure
            # (emitting `2:test.lua: boom`) must fail this, not just the
            # loose `:\d+:` shape.
            assert err =~ ~r/^test\.lua:\d+: boom$/

          :compiled ->
            # The dispatcher does not yet plumb a per-call line for native
            # calls inside compiled closures, so the prefix is suppressed
            # rather than attributed to a stale outer line.
            assert err == "boom"
        end
      end

      test "level 0 suppresses the prefix" do
        {results, _state} =
          run(
            """
            local ok, err = pcall(function()
              error("hi", 0)
            end)
            return ok, err
            """,
            @engine
          )

        assert results == [false, "hi"]
      end
    end

    describe "xpcall hands the raw value to the handler (#{engine} engine)" do
      test "handler receives the untouched table" do
        {results, _state} =
          run(
            """
            local ok, err = xpcall(function()
              error({code = 2})
            end, function(e)
              return e
            end)
            return ok, type(err), err and err.code
            """,
            @engine
          )

        assert results == [false, "table", 2]
      end

      test "an erroring handler falls back to the original raw value" do
        {results, _state} =
          run(
            """
            local ok, err = xpcall(function()
              error({code = 2})
            end, function(_)
              error("handler boom")
            end)
            return ok, type(err), err and err.code
            """,
            @engine
          )

        assert results == [false, "table", 2]
      end
    end

    describe "internal errors keep their string messages (#{engine} engine)" do
      test "a call-nil TypeError stays a string and is not prefixed by error()" do
        {results, _state} =
          run(
            """
            local ok, err = pcall(function()
              local f = nil
              f()
            end)
            return ok, type(err), err
            """,
            @engine
          )

        assert [false, "string", err] = results
        assert err =~ "attempt to call a nil value"
      end

      test "an arithmetic TypeError stays a string" do
        {results, _state} =
          run(
            """
            local ok, err = pcall(function()
              return nil + 1
            end)
            return ok, type(err), err
            """,
            @engine
          )

        assert [false, "string", err] = results
        assert err =~ "attempt to perform arithmetic"
      end

      test "a stdlib bad-argument error stays a string" do
        {results, _state} =
          run(
            """
            local ok, err = pcall(function()
              return string.rep()
            end)
            return ok, type(err), err
            """,
            @engine
          )

        assert [false, "string", _err] = results
      end
    end
  end
end

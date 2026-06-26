defmodule Lua.DbgTest do
  @moduledoc """
  `Lua.dbg/2` — iex-only debug helper. Captures `print()` output via a
  group-leader swap and emits a structured summary alongside the
  return tuple from `Lua.eval!/2`.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  describe "dbg/2 happy path" do
    test "returns the same tuple as Lua.eval!/2" do
      capture_io(fn ->
        {result, lua} = Lua.dbg(Lua.new(), "return 1 + 2")
        assert result == [3]
        assert match?(%Lua{}, lua)
      end)
    end

    test "summary lists return values" do
      output = capture_io(fn -> Lua.dbg(Lua.new(), "return 1 + 2") end)

      assert output =~ "--- Lua.dbg ---"
      assert output =~ "return:  [3]"
      assert output =~ "---------------"
    end

    test "summary previews single-line source verbatim" do
      output = capture_io(fn -> Lua.dbg(Lua.new(), "return 42") end)

      assert output =~ "source:  return 42"
    end

    test "summary previews multi-line source with the line-break marker" do
      output =
        capture_io(fn ->
          Lua.dbg(Lua.new(), """
          local x = 10
          return x
          """)
        end)

      assert output =~ ~r/source:\s+local x = 10\s+\x{23CE}/u
    end

    test "summary truncates source previews longer than ~100 chars" do
      long = String.duplicate("a", 200)
      output = capture_io(fn -> Lua.dbg(Lua.new(), "return \"#{long}\"") end)

      [source_line] = Regex.run(~r/source:\s+(.*)/u, output, capture: :all_but_first)
      # Truncated to ≤ 80 visible chars + ellipsis on a single-line preview.
      assert String.length(source_line) <= 81
      assert String.ends_with?(source_line, "…")
    end
  end

  describe "dbg/2 captures stdout" do
    test "captures Lua's print output and shows it under `prints:`" do
      # Use a marker string that doesn't appear in the source preview
      # so the captured-print assertion isn't satisfied by the source line.
      output =
        capture_io(fn ->
          lua = Lua.set!(Lua.new(), [:msg], "captured-marker")
          Lua.dbg(lua, "print(msg); return 1")
        end)

      # The print output is captured by the group-leader swap and
      # routed into the prints: block, not leaked to the test's
      # captured stdout outside of the dbg summary.
      assert output =~ ~r/prints:\s*\n  captured-marker/

      # And it appears only once — once under the prints: heading,
      # never duplicated elsewhere in the captured stdout.
      assert output |> String.split("captured-marker") |> length() == 2
    end

    test "shows `(none)` when the script writes nothing to stdout" do
      output = capture_io(fn -> Lua.dbg(Lua.new(), "return 1") end)

      assert output =~ "prints:  (none)"
    end

    test "captures multiple print calls" do
      output =
        capture_io(fn ->
          Lua.dbg(
            Lua.new(),
            ~S"""
            print("first")
            print("second")
            return nil
            """
          )
        end)

      assert output =~ "first"
      assert output =~ "second"
    end
  end

  describe "dbg/2 elapsed time" do
    test "summary line includes an integer millisecond count" do
      output = capture_io(fn -> Lua.dbg(Lua.new(), "return 1") end)

      assert output =~ ~r/elapsed:\s+\d+\s+ms/
    end
  end

  describe "dbg/2 error path" do
    test "re-raises the original Lua.RuntimeException" do
      assert_raise Lua.RuntimeException, fn ->
        capture_io(fn ->
          Lua.dbg(Lua.new(), "error(\"boom\")")
        end)
      end
    end

    test "summary shows `raised:` for the original exception" do
      output =
        capture_io(fn ->
          assert_raise Lua.RuntimeException, fn ->
            Lua.dbg(Lua.new(), "error(\"boom\")")
          end
        end)

      assert output =~ "raised:"
      assert output =~ "Lua.RuntimeException"
    end

    test "restores the calling process's group leader on error" do
      original_gl = Process.group_leader()

      capture_io(fn ->
        assert_raise Lua.RuntimeException, fn ->
          Lua.dbg(Lua.new(), "error(\"boom\")")
        end
      end)

      assert Process.group_leader() == original_gl
    end
  end

  describe "dbg/1 — default state" do
    test "uses Lua.new() when called with only source" do
      output = capture_io(fn -> Lua.dbg("return 7") end)

      assert output =~ "return:  [7]"
    end
  end

  describe "dbg/2 round-trips state" do
    test "the returned state reflects assignments inside the script" do
      lua = Lua.new()

      {[], lua} = capture_io_with_result(fn -> Lua.dbg(lua, "x = 99") end)

      assert {[99], _} = Lua.eval!(lua, "return x")
    end
  end

  # Helper: capture stdout but also surface the function's return value.
  defp capture_io_with_result(fun) do
    parent = self()

    capture_io(fn ->
      send(parent, {:result, fun.()})
    end)

    receive do
      {:result, value} -> value
    after
      0 -> raise "fun did not return"
    end
  end
end

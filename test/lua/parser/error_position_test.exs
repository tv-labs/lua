defmodule Lua.Parser.ErrorPositionTest do
  @moduledoc """
  Pins the *position* of syntax errors, not just their detection.

  A recursive-descent parser can detect a syntax error correctly yet report
  it at the wrong place: when a deeply-nested sub-parse fails, a shallower
  recovery point may swallow the real error and substitute a generic
  "expected <terminator>" pinned to the list boundary. These tests lock the
  reported line to the actual offending token.

  The golden corpus is CI-deterministic. The differential test cross-checks
  our reported line against reference Lua (`luac -p`) and is skipped when no
  `luac` is on PATH.
  """
  use ExUnit.Case, async: true

  alias Lua.Parser

  # {name, source, expected_line, message_substring, reference}
  #
  # `reference` says how our line relates to PUC-Lua's:
  #   :match  -> there is a concrete offending token; we agree with luac.
  #   :opener -> the construct runs off the end of input; we deliberately
  #              point at the *opening* delimiter (luac points at <eof>).
  @corpus [
    # The reported regression: a deep error inside the 5th argument (a
    # function literal) of a method call. Before the fix this blamed the
    # `function` keyword on the call line; it must now point at the `end`
    # where an expression was expected.
    {"deep error in 5th call argument", ~s|w:step("a", "b", "c", {x = 1}, function()\n  bar(\nend)\n|, 3,
     "Expected expression", :match},

    # Deep error inside an argument fails immediately on a bad token.
    {"deep error in a table field value", "t = {\n  a = 1,\n  b = foo(,\n}\n", 3, "Expected expression", :match},

    # Deep error inside a return expression list.
    {"deep error in a return list", "function f()\n  return 1, 2, g(\nend\n", 3, "Expected expression", :match},

    # Stray statement after closed nested calls — error at the garbage line.
    {"stray statement after nested calls", "outer(mid(inner(\n)))\n.. bad\n", 3, "bare", :match},

    # We must NOT over-propagate: a clean list end followed by a stray token
    # still reports the stray token at the boundary, not a deeper error.
    {"stray token after complete arg list", "print(1, 2 3)\n", 1, "Expected", :match},

    # Genuinely-unclosed constructs at EOF point at the opener line.
    {"unclosed call across lines", "print(1, 2, 3\n", 1, "Unclosed", :opener},
    {"unclosed index across lines", "y = t[\n  1\n", 1, "Unclosed", :opener},
    {"unclosed paren across lines", "z = (\n  1 + 2\n", 1, "Unclosed", :opener}
  ]

  describe "golden error positions" do
    for {name, source, expected_line, substring, _ref} <- @corpus do
      test name do
        assert {:error, msg} = Parser.parse(unquote(source))
        clean = strip_ansi(msg)

        assert clean =~ "at line #{unquote(expected_line)},",
               "expected error at line #{unquote(expected_line)}, got:\n#{clean}"

        assert clean =~ unquote(substring)
      end
    end
  end

  describe "differential vs. reference Lua (luac -p)" do
    @describetag :differential

    setup do
      case System.find_executable("luac") do
        nil -> {:skip, "luac not found on PATH"}
        path -> {:ok, luac: path}
      end
    end

    for {name, source, _expected_line, _substring, :match} <- @corpus do
      test "agrees with luac on: #{name}", %{luac: luac} do
        assert {:error, msg} = Parser.parse(unquote(source))
        ours = error_line(strip_ansi(msg))

        assert is_integer(ours)
        assert reference_line(luac, unquote(source)) == ours
      end
    end
  end

  defp strip_ansi(string), do: String.replace(string, ~r/\e\[[0-9;]*m/, "")

  defp error_line(clean) do
    case Regex.run(~r/at line (\d+)/, clean) do
      [_, n] -> String.to_integer(n)
      _ -> nil
    end
  end

  defp reference_line(luac, source) do
    path = Path.join(System.tmp_dir!(), "lua_error_position_#{:erlang.unique_integer([:positive])}.lua")
    File.write!(path, source)

    try do
      {out, _status} = System.cmd(luac, ["-p", path], stderr_to_stdout: true)

      case Regex.run(~r/:(\d+):/, out) do
        [_, n] -> String.to_integer(n)
        _ -> nil
      end
    after
      File.rm(path)
    end
  end
end

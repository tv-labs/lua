defmodule Lua.Parser.ErrorAnsiTest do
  @moduledoc """
  Locks the ANSI gating on parser error output.

  Parse errors color their output only when `IO.ANSI.enabled?/0` is true,
  matching the runtime `Lua.VM.ErrorFormatter` path. The suite otherwise runs
  with ANSI disabled (see test/test_helper.exs), so these tests flip it on
  locally and restore it. That toggle mutates global application env, so this
  module is `async: false` to keep it from racing concurrent tests that assert
  on plain-text output.
  """
  use ExUnit.Case, async: false

  alias Lua.Parser

  setup do
    Application.put_env(:elixir, :ansi_enabled, true)
    on_exit(fn -> Application.put_env(:elixir, :ansi_enabled, false) end)
  end

  describe "with ANSI enabled" do
    test "uses ANSI colors for better readability" do
      assert {:error, msg} = Parser.parse("if x then")
      # Red for errors
      assert msg =~ "\e[31m"
      # Bold
      assert msg =~ "\e[1m"
      # Reset
      assert msg =~ "\e[0m"
      # Cyan for suggestions
      assert msg =~ "\e[36m"
    end

    test "parse_chunk/1 carries colored errors when ANSI is on" do
      assert {:error, %Lua.CompilerException{errors: errors}} = Lua.parse_chunk("asdf")
      assert Enum.any?(errors, &(&1 =~ "\e["))
    end
  end
end

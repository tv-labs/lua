defmodule Lua.UnicodeTest do
  use ExUnit.Case, async: true

  import Lua, only: [sigil_LUA: 2]

  test "it can contain unicode" do
    assert {["é"], _} = Lua.eval!("return 'é'")
  end

  test "chunks can contain unicode" do
    {:ok, chunk} = Lua.parse_chunk("return 'é'")
    assert {["é"], _} = Lua.eval!(chunk)
  end

  test "sigil lua can contain unicode" do
    assert {["é"], _} = Lua.eval!(~LUA"return 'é'"c)
  end

  test "a chunk can be loaded with unicode" do
    assert {chunk, lua} = Lua.load_chunk!(Lua.new(), "return 'é'")
    assert {["é"], _} = Lua.eval!(lua, chunk)
  end
end

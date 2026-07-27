defmodule Lua.AST.IdsTest do
  @moduledoc """
  Pins the uniqueness contract compiler passes rely on when they key
  per-node tables by `meta.id`.
  """

  use ExUnit.Case, async: true

  alias Lua.AST.Ids
  alias Lua.AST.Walker

  describe "assign/1" do
    test "gives every node of a parsed chunk an id" do
      ids = ids_for("local x = 1\nprint(x + 2)\n")

      assert Enum.all?(ids, &is_integer/1)
    end

    test "ids are unique across nested function bodies" do
      source = """
      local function outer(a)
        local inner = function(b)
          return function(c) return a + b + c end
        end

        return inner
      end

      return outer(1)(2)(3)
      """

      ids = ids_for(source)

      assert length(ids) == length(Enum.uniq(ids))
    end

    test "ids are unique across structurally identical siblings" do
      # The two branches parse to equal terms, so keying by the node itself
      # would collapse them onto one entry.
      source = """
      if flag then
        local x = 1
        return x
      else
        local x = 1
        return x
      end
      """

      ids = ids_for(source)

      assert length(ids) == length(Enum.uniq(ids))
    end

    test "keeps positions and comments already on a node" do
      {:ok, chunk} = Lua.Parser.parse_raw("-- leading\nlocal x = 1\n")
      [local_stmt] = chunk.block.stmts

      assert %{line: 2} = local_stmt.meta.start
      assert [%{text: " leading"}] = local_stmt.meta.metadata.leading_comments
      assert is_integer(local_stmt.meta.id)
    end

    test "is idempotent in shape: re-assigning yields the same chunk" do
      {:ok, chunk} = Lua.Parser.parse_raw("local t = {1, 2, x = 3}\nreturn t.x\n")

      assert Ids.assign(chunk) == chunk
    end
  end

  defp ids_for(source) do
    {:ok, chunk} = Lua.Parser.parse_raw(source)

    chunk
    |> Walker.reduce([], fn node, acc -> [node.meta.id | acc] end)
    |> Enum.reject(&is_nil/1)
  end
end

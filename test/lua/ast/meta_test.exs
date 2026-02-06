defmodule Lua.AST.MetaTest do
  use ExUnit.Case, async: true

  alias Lua.AST.Meta

  describe "new/0" do
    test "creates empty meta" do
      meta = Meta.new()
      assert %Meta{start: nil, end: nil, metadata: %{}} = meta
    end
  end

  describe "new/2" do
    test "creates meta with start and end positions" do
      start = %{line: 1, column: 1, byte_offset: 0}
      finish = %{line: 1, column: 10, byte_offset: 9}

      meta = Meta.new(start, finish)

      assert meta.start == start
      assert meta.end == finish
      assert meta.metadata == %{}
    end

    test "accepts nil positions" do
      meta = Meta.new(nil, nil)
      assert meta.start == nil
      assert meta.end == nil
    end
  end

  describe "new/3" do
    test "creates meta with metadata" do
      start = %{line: 1, column: 1, byte_offset: 0}
      finish = %{line: 1, column: 10, byte_offset: 9}
      metadata = %{type: :test, custom: "value"}

      meta = Meta.new(start, finish, metadata)

      assert meta.start == start
      assert meta.end == finish
      assert meta.metadata == metadata
    end

    test "accepts empty metadata map" do
      start = %{line: 1, column: 1, byte_offset: 0}
      finish = %{line: 1, column: 10, byte_offset: 9}

      meta = Meta.new(start, finish, %{})

      assert meta.metadata == %{}
    end
  end

  describe "add_metadata/3" do
    test "adds metadata to existing meta" do
      meta = Meta.new()
      meta = Meta.add_metadata(meta, :test, "value")

      assert meta.metadata == %{test: "value"}
    end

    test "adds multiple metadata fields" do
      meta = Meta.new(nil, nil, %{a: 1})
      meta = Meta.add_metadata(meta, :b, 2)

      assert meta.metadata == %{a: 1, b: 2}
    end

    test "overwrites existing keys" do
      meta = Meta.new(nil, nil, %{a: 1})
      meta = Meta.add_metadata(meta, :a, 2)

      assert meta.metadata == %{a: 2}
    end
  end

  describe "merge/2" do
    test "merges two metas taking earliest start" do
      meta1 =
        Meta.new(%{line: 1, column: 5, byte_offset: 10}, %{line: 1, column: 10, byte_offset: 20})

      meta2 =
        Meta.new(%{line: 1, column: 1, byte_offset: 5}, %{line: 1, column: 8, byte_offset: 15})

      merged = Meta.merge(meta1, meta2)

      assert merged.start == %{line: 1, column: 1, byte_offset: 5}
    end

    test "merges two metas taking latest end" do
      meta1 =
        Meta.new(%{line: 1, column: 1, byte_offset: 0}, %{line: 1, column: 10, byte_offset: 9})

      meta2 =
        Meta.new(%{line: 1, column: 5, byte_offset: 4}, %{line: 1, column: 20, byte_offset: 19})

      merged = Meta.merge(meta1, meta2)

      assert merged.end == %{line: 1, column: 20, byte_offset: 19}
    end

    test "handles nil start positions" do
      meta1 = Meta.new(nil, %{line: 1, column: 10, byte_offset: 9})
      meta2 = Meta.new(%{line: 1, column: 1, byte_offset: 0}, nil)

      merged = Meta.merge(meta1, meta2)

      assert merged.start == %{line: 1, column: 1, byte_offset: 0}
      assert merged.end == %{line: 1, column: 10, byte_offset: 9}
    end

    test "handles nil end positions" do
      meta1 = Meta.new(%{line: 1, column: 1, byte_offset: 0}, nil)
      meta2 = Meta.new(nil, %{line: 1, column: 10, byte_offset: 9})

      merged = Meta.merge(meta1, meta2)

      assert merged.start == %{line: 1, column: 1, byte_offset: 0}
      assert merged.end == %{line: 1, column: 10, byte_offset: 9}
    end

    test "handles both positions nil on first meta" do
      meta1 = Meta.new(nil, nil)

      meta2 =
        Meta.new(%{line: 1, column: 1, byte_offset: 0}, %{line: 1, column: 10, byte_offset: 9})

      merged = Meta.merge(meta1, meta2)

      assert merged.start == %{line: 1, column: 1, byte_offset: 0}
      assert merged.end == %{line: 1, column: 10, byte_offset: 9}
    end

    test "handles both positions nil on second meta" do
      meta1 =
        Meta.new(%{line: 1, column: 1, byte_offset: 0}, %{line: 1, column: 10, byte_offset: 9})

      meta2 = Meta.new(nil, nil)

      merged = Meta.merge(meta1, meta2)

      assert merged.start == %{line: 1, column: 1, byte_offset: 0}
      assert merged.end == %{line: 1, column: 10, byte_offset: 9}
    end

    test "chooses earlier position when first has earlier byte offset" do
      meta1 =
        Meta.new(%{line: 1, column: 1, byte_offset: 0}, %{line: 1, column: 5, byte_offset: 4})

      meta2 =
        Meta.new(%{line: 1, column: 6, byte_offset: 5}, %{line: 1, column: 10, byte_offset: 9})

      merged = Meta.merge(meta1, meta2)

      assert merged.start == %{line: 1, column: 1, byte_offset: 0}
      assert merged.end == %{line: 1, column: 10, byte_offset: 9}
    end

    test "chooses later position when second has later byte offset" do
      meta1 =
        Meta.new(%{line: 1, column: 1, byte_offset: 0}, %{line: 1, column: 5, byte_offset: 4})

      meta2 =
        Meta.new(%{line: 1, column: 2, byte_offset: 1}, %{line: 1, column: 10, byte_offset: 9})

      merged = Meta.merge(meta1, meta2)

      assert merged.start == %{line: 1, column: 1, byte_offset: 0}
      assert merged.end == %{line: 1, column: 10, byte_offset: 9}
    end
  end

  describe "position tracking" do
    test "stores line numbers" do
      meta =
        Meta.new(%{line: 5, column: 10, byte_offset: 50}, %{line: 5, column: 20, byte_offset: 60})

      assert meta.start.line == 5
      assert meta.end.line == 5
    end

    test "stores column numbers" do
      meta =
        Meta.new(%{line: 1, column: 5, byte_offset: 4}, %{line: 1, column: 15, byte_offset: 14})

      assert meta.start.column == 5
      assert meta.end.column == 15
    end

    test "stores byte offsets" do
      meta =
        Meta.new(%{line: 1, column: 1, byte_offset: 100}, %{line: 1, column: 10, byte_offset: 200})

      assert meta.start.byte_offset == 100
      assert meta.end.byte_offset == 200
    end

    test "handles multiline spans" do
      meta =
        Meta.new(%{line: 1, column: 1, byte_offset: 0}, %{line: 10, column: 5, byte_offset: 150})

      assert meta.start.line == 1
      assert meta.end.line == 10
    end
  end

  describe "metadata storage" do
    test "stores arbitrary data" do
      meta =
        Meta.new(nil, nil, %{
          node_type: :function,
          name: "test",
          params: ["a", "b"],
          is_async: false
        })

      assert meta.metadata.node_type == :function
      assert meta.metadata.name == "test"
      assert meta.metadata.params == ["a", "b"]
      assert meta.metadata.is_async == false
    end

    test "stores nested data structures" do
      meta =
        Meta.new(nil, nil, %{
          scope: %{
            variables: ["x", "y"],
            functions: ["f", "g"]
          }
        })

      assert meta.metadata.scope.variables == ["x", "y"]
      assert meta.metadata.scope.functions == ["f", "g"]
    end
  end

  describe "struct validation" do
    test "has correct struct fields" do
      meta = %Meta{}
      assert Map.has_key?(meta, :start)
      assert Map.has_key?(meta, :end)
      assert Map.has_key?(meta, :metadata)
    end

    test "is a proper struct" do
      meta = %Meta{}
      assert meta.__struct__ == Lua.AST.Meta
    end
  end
end

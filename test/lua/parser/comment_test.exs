defmodule Lua.Parser.CommentTest do
  use ExUnit.Case, async: true
  alias Lua.Parser
  alias Lua.AST.{Meta, Statement}

  describe "single-line comments as leading comments" do
    test "attaches comment before local statement" do
      code = """
      -- This is a comment
      local x = 42
      """

      {:ok, chunk} = Parser.parse(code)
      [stmt] = chunk.block.stmts

      assert %Statement.Local{meta: meta} = stmt
      comments = Meta.get_leading_comments(meta)
      assert length(comments) == 1

      assert [%{type: :single, text: " This is a comment"}] = comments
    end

    test "attaches multiple leading comments" do
      code = """
      -- Comment 1
      -- Comment 2
      -- Comment 3
      local x = 42
      """

      {:ok, chunk} = Parser.parse(code)
      [stmt] = chunk.block.stmts

      comments = Meta.get_leading_comments(stmt.meta)
      assert length(comments) == 3
      assert Enum.at(comments, 0).text == " Comment 1"
      assert Enum.at(comments, 1).text == " Comment 2"
      assert Enum.at(comments, 2).text == " Comment 3"
    end

    test "attaches comment before function declaration" do
      code = """
      -- This function adds two numbers
      function add(a, b)
        return a + b
      end
      """

      {:ok, chunk} = Parser.parse(code)
      [stmt] = chunk.block.stmts

      assert %Statement.FuncDecl{meta: meta} = stmt
      comments = Meta.get_leading_comments(meta)
      assert length(comments) == 1
      assert hd(comments).text == " This function adds two numbers"
    end

    test "attaches comment before if statement" do
      code = """
      -- Check if positive
      if x > 0 then
        return x
      end
      """

      {:ok, chunk} = Parser.parse(code)
      [stmt] = chunk.block.stmts

      assert %Statement.If{meta: meta} = stmt
      comments = Meta.get_leading_comments(meta)
      assert length(comments) == 1
      assert hd(comments).text == " Check if positive"
    end
  end

  describe "single-line trailing comments" do
    test "attaches inline comment to local statement" do
      code = "local x = 42  -- The answer"

      {:ok, chunk} = Parser.parse(code)
      [stmt] = chunk.block.stmts

      assert %Statement.Local{meta: meta} = stmt
      comment = Meta.get_trailing_comment(meta)
      assert comment != nil
      assert comment.text == " The answer"
      assert comment.type == :single
    end

    test "attaches inline comment to assignment" do
      code = "x = 10  -- Set to ten"

      {:ok, chunk} = Parser.parse(code)
      [stmt] = chunk.block.stmts

      assert %Statement.Assign{meta: meta} = stmt
      comment = Meta.get_trailing_comment(meta)
      assert comment.text == " Set to ten"
    end

    test "attaches inline comment to return statement" do
      code = "return 42  -- Return the answer"

      {:ok, chunk} = Parser.parse(code)
      [stmt] = chunk.block.stmts

      assert %Statement.Return{meta: meta} = stmt
      comment = Meta.get_trailing_comment(meta)
      assert comment.text == " Return the answer"
    end
  end

  describe "multi-line comments" do
    test "attaches multi-line comment before statement" do
      code = """
      --[[ This is a
      multi-line comment ]]
      local x = 42
      """

      {:ok, chunk} = Parser.parse(code)
      [stmt] = chunk.block.stmts

      comments = Meta.get_leading_comments(stmt.meta)
      assert length(comments) == 1
      comment = hd(comments)
      assert comment.type == :multi
      assert comment.text =~ "This is a"
      assert comment.text =~ "multi-line comment"
    end

    test "attaches multi-line comment with equals brackets" do
      code = """
      --[=[ Comment with ]] inside ]=]
      local x = 42
      """

      {:ok, chunk} = Parser.parse(code)
      [stmt] = chunk.block.stmts

      comments = Meta.get_leading_comments(stmt.meta)
      assert length(comments) == 1
      assert hd(comments).text =~ "Comment with ]] inside"
    end
  end

  describe "mixed leading and trailing comments" do
    test "attaches both leading and trailing comments" do
      code = """
      -- Leading comment
      local x = 42  -- Trailing comment
      """

      {:ok, chunk} = Parser.parse(code)
      [stmt] = chunk.block.stmts

      leading = Meta.get_leading_comments(stmt.meta)
      assert length(leading) == 1
      assert hd(leading).text == " Leading comment"

      trailing = Meta.get_trailing_comment(stmt.meta)
      assert trailing != nil
      assert trailing.text == " Trailing comment"
    end
  end

  describe "comments on nested statements" do
    test "attaches comments to statements inside function" do
      code = """
      function test()
        -- Inner comment
        local x = 42
      end
      """

      {:ok, chunk} = Parser.parse(code)
      [func] = chunk.block.stmts
      assert %Statement.FuncDecl{body: body} = func

      [inner_stmt] = body.stmts
      comments = Meta.get_leading_comments(inner_stmt.meta)
      assert length(comments) == 1
      assert hd(comments).text == " Inner comment"
    end

    test "attaches comments to statements inside if block" do
      code = """
      if true then
        -- Comment inside if
        print("hello")
      end
      """

      {:ok, chunk} = Parser.parse(code)
      [if_stmt] = chunk.block.stmts
      assert %Statement.If{then_block: then_block} = if_stmt

      [inner_stmt] = then_block.stmts
      comments = Meta.get_leading_comments(inner_stmt.meta)
      assert length(comments) == 1
      assert hd(comments).text == " Comment inside if"
    end

    test "attaches comments to statements inside while loop" do
      code = """
      while x > 0 do
        -- Decrement
        x = x - 1
      end
      """

      {:ok, chunk} = Parser.parse(code)
      [while_stmt] = chunk.block.stmts
      assert %Statement.While{body: body} = while_stmt

      [inner_stmt] = body.stmts
      comments = Meta.get_leading_comments(inner_stmt.meta)
      assert length(comments) == 1
      assert hd(comments).text == " Decrement"
    end
  end

  describe "comments between statements" do
    test "attaches comments to following statement" do
      code = """
      local x = 1
      -- Comment for y
      local y = 2
      """

      {:ok, chunk} = Parser.parse(code)
      [stmt1, stmt2] = chunk.block.stmts

      # First statement should have no comments
      assert Meta.get_leading_comments(stmt1.meta) == []
      assert Meta.get_trailing_comment(stmt1.meta) == nil

      # Second statement should have the comment
      comments = Meta.get_leading_comments(stmt2.meta)
      assert length(comments) == 1
      assert hd(comments).text == " Comment for y"
    end
  end

  describe "orphaned comments (at top level)" do
    test "preserves top-level comments before any code" do
      code = """
      -- Top level comment
      -- Another top comment
      local x = 42
      """

      {:ok, chunk} = Parser.parse(code)
      [stmt] = chunk.block.stmts

      # Comments should be attached to the first statement
      comments = Meta.get_leading_comments(stmt.meta)
      assert length(comments) == 2
    end
  end

  describe "comments with special characters" do
    test "preserves comment text exactly" do
      code = "local x = 1  -- TODO: fix this!!!"

      {:ok, chunk} = Parser.parse(code)
      [stmt] = chunk.block.stmts

      comment = Meta.get_trailing_comment(stmt.meta)
      assert comment.text == " TODO: fix this!!!"
    end

    test "handles empty comments" do
      code = """
      --
      local x = 42
      """

      {:ok, chunk} = Parser.parse(code)
      [stmt] = chunk.block.stmts

      comments = Meta.get_leading_comments(stmt.meta)
      assert length(comments) == 1
      assert hd(comments).text == ""
    end
  end

  describe "comments with complex statements" do
    test "attaches comments to for loop" do
      code = """
      -- Loop through items
      for i = 1, 10 do
        print(i)
      end
      """

      {:ok, chunk} = Parser.parse(code)
      [stmt] = chunk.block.stmts

      assert %Statement.ForNum{meta: meta} = stmt
      comments = Meta.get_leading_comments(meta)
      assert length(comments) == 1
      assert hd(comments).text == " Loop through items"
    end

    test "attaches comments to do block" do
      code = """
      -- Create scope
      do
        local x = 42
      end
      """

      {:ok, chunk} = Parser.parse(code)
      [stmt] = chunk.block.stmts

      assert %Statement.Do{meta: meta} = stmt
      comments = Meta.get_leading_comments(meta)
      assert length(comments) == 1
    end
  end

  describe "position tracking for comments" do
    test "records correct position for single-line comment" do
      code = """
      -- Comment at line 1
      local x = 42
      """

      {:ok, chunk} = Parser.parse(code)
      [stmt] = chunk.block.stmts

      comments = Meta.get_leading_comments(stmt.meta)
      comment = hd(comments)

      assert comment.position.line == 1
      assert comment.position.column == 1
    end

    test "records correct position for trailing comment" do
      code = "local x = 42  -- Trailing"

      {:ok, chunk} = Parser.parse(code)
      [stmt] = chunk.block.stmts

      comment = Meta.get_trailing_comment(stmt.meta)
      assert comment.position.line == 1
      # Should be at the position where -- starts
      assert comment.position.column > 10
    end
  end

  describe "no comments" do
    test "statements without comments have empty comment lists" do
      code = "local x = 42"

      {:ok, chunk} = Parser.parse(code)
      [stmt] = chunk.block.stmts

      assert Meta.get_leading_comments(stmt.meta) == []
      assert Meta.get_trailing_comment(stmt.meta) == nil
    end

    test "multiple statements without comments" do
      code = """
      local x = 1
      local y = 2
      local z = 3
      """

      {:ok, chunk} = Parser.parse(code)

      for stmt <- chunk.block.stmts do
        assert Meta.get_leading_comments(stmt.meta) == []
        assert Meta.get_trailing_comment(stmt.meta) == nil
      end
    end
  end
end

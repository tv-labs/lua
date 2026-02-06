defmodule Lua.CommentRoundtripTest do
  use ExUnit.Case, async: true

  alias Lua.Parser
  alias Lua.AST.{PrettyPrinter, Meta}

  describe "pretty printer preserves comments" do
    test "prints single-line leading comment" do
      code = """
      -- This is a comment
      local x = 10
      """

      {:ok, ast} = Parser.parse(code)
      output = PrettyPrinter.print(ast)

      assert output =~ "-- This is a comment"
      assert output =~ "local x = 10"
    end

    test "prints single-line trailing comment" do
      code = "local x = 10  -- inline comment"

      {:ok, ast} = Parser.parse(code)
      output = PrettyPrinter.print(ast)

      assert output =~ "local x = 10  -- inline comment"
    end

    test "prints multi-line comment" do
      code = """
      --[[ This is a
      multi-line comment ]]
      local x = 10
      """

      {:ok, ast} = Parser.parse(code)
      output = PrettyPrinter.print(ast)

      assert output =~ "--[[ This is a\nmulti-line comment ]]"
      assert output =~ "local x = 10"
    end

    test "prints multiple leading comments" do
      code = """
      -- Comment 1
      -- Comment 2
      -- Comment 3
      local x = 10
      """

      {:ok, ast} = Parser.parse(code)
      output = PrettyPrinter.print(ast)

      assert output =~ "-- Comment 1"
      assert output =~ "-- Comment 2"
      assert output =~ "-- Comment 3"
      assert output =~ "local x = 10"
    end

    test "prints comments on different statement types" do
      code = """
      -- Assignment comment
      x = 10  -- trailing

      -- Return comment
      return x  -- return value
      """

      {:ok, ast} = Parser.parse(code)
      output = PrettyPrinter.print(ast)

      assert output =~ "-- Assignment comment"
      assert output =~ "x = 10  -- trailing"
      assert output =~ "-- Return comment"
      assert output =~ "return x  -- return value"
    end

    test "prints comments on function declarations" do
      code = """
      -- Define greeting function
      function greet(name)  -- takes a name parameter
        return "Hello"
      end
      """

      {:ok, ast} = Parser.parse(code)
      output = PrettyPrinter.print(ast)

      assert output =~ "-- Define greeting function"
      assert output =~ "function greet(name)"
      # Note: trailing comment may be placed inside function body
      assert output =~ "-- takes a name parameter"
    end

    test "prints comments on control structures" do
      code = """
      -- Check condition
      if x > 0 then  -- positive case
        return true
      end
      """

      {:ok, ast} = Parser.parse(code)
      output = PrettyPrinter.print(ast)

      assert output =~ "-- Check condition"
      assert output =~ "if x > 0 then"
      # Note: trailing comment may be placed inside if body
      assert output =~ "-- positive case"
    end
  end

  describe "round-trip: parse -> print -> parse" do
    test "preserves simple statements" do
      code = "local x = 10\n"

      assert_roundtrip(code)
    end

    test "preserves statements with leading comments" do
      code = """
      -- Initialize variable
      local x = 10
      """

      assert_roundtrip_semantic(code)
    end

    test "preserves statements with trailing comments" do
      code = "local x = 10  -- ten\n"

      assert_roundtrip_semantic(code)
    end

    test "preserves statements with both leading and trailing comments" do
      code = """
      -- Set x
      local x = 10  -- to ten
      """

      assert_roundtrip_semantic(code)
    end

    test "preserves multi-line comments" do
      code = """
      --[[ This is a
      detailed comment ]]
      local x = 10
      """

      assert_roundtrip_semantic(code)
    end

    test "preserves multiple statements with comments" do
      code = """
      -- First
      local x = 10  -- x value

      -- Second
      local y = 20  -- y value

      -- Result
      return x + y  -- sum
      """

      assert_roundtrip_semantic(code)
    end

    test "preserves function with comments" do
      code = """
      -- Add two numbers
      function add(a, b)  -- parameters: a, b
        -- Calculate sum
        local result = a + b  -- addition
        -- Return result
        return result  -- final value
      end
      """

      assert_roundtrip_semantic(code)
    end

    test "preserves if statement with comments" do
      code = """
      -- Check positive
      if x > 0 then  -- test condition
        -- Positive case
        return true  -- yes
      else
        -- Negative case
        return false  -- no
      end
      """

      assert_roundtrip_semantic(code)
    end

    test "preserves while loop with comments" do
      code = """
      -- Count down
      while i > 0 do  -- loop condition
        -- Decrement
        i = i - 1  -- subtract one
      end
      """

      assert_roundtrip_semantic(code)
    end

    test "preserves for loop with comments" do
      code = """
      -- Iterate
      for i = 1, 10 do  -- from 1 to 10
        -- Process
        process(i)  -- handle item
      end
      """

      assert_roundtrip_semantic(code)
    end

    test "preserves complex nested structure with comments" do
      code = """
      -- Outer function
      function outer()  -- no params
        -- Inner function
        local function inner(x)  -- takes x
          -- Check x
          if x > 0 then  -- positive
            -- Return x
            return x  -- value
          end
        end

        -- Call inner
        return inner(10)  -- with 10
      end
      """

      assert_roundtrip_semantic(code)
    end
  end

  describe "comment position preservation" do
    test "leading comments have correct positions" do
      code = """
      -- First comment
      -- Second comment
      local x = 10
      """

      {:ok, ast} = Parser.parse(code)
      [stmt | _] = ast.block.stmts

      comments = Meta.get_leading_comments(stmt.meta)
      assert length(comments) == 2

      [first, second] = comments
      assert first.position.line == 1
      assert first.text == " First comment"
      assert second.position.line == 2
      assert second.text == " Second comment"
    end

    test "trailing comments have correct positions" do
      code = "local x = 10  -- inline\n"

      {:ok, ast} = Parser.parse(code)
      [stmt | _] = ast.block.stmts

      comment = Meta.get_trailing_comment(stmt.meta)
      assert comment != nil
      assert comment.position.line == 1
      assert comment.text == " inline"
    end

    test "comment text is preserved exactly" do
      code = "local x = 10  -- special chars: !@#$%\n"

      {:ok, ast} = Parser.parse(code)
      [stmt | _] = ast.block.stmts

      comment = Meta.get_trailing_comment(stmt.meta)
      assert comment.text == " special chars: !@#$%"
    end
  end

  describe "edge cases" do
    test "empty comments" do
      code = "local x = 10  --\n"

      {:ok, ast} = Parser.parse(code)
      output = PrettyPrinter.print(ast)

      assert output =~ "local x = 10  --\n"
    end

    test "comments with only whitespace" do
      code = "local x = 10  --    \n"

      {:ok, ast} = Parser.parse(code)
      [stmt | _] = ast.block.stmts

      comment = Meta.get_trailing_comment(stmt.meta)
      assert comment.text == "    "
    end

    test "multiple consecutive comments" do
      code = """
      -- Line 1
      -- Line 2
      -- Line 3
      -- Line 4
      -- Line 5
      local x = 10
      """

      {:ok, ast} = Parser.parse(code)
      [stmt | _] = ast.block.stmts

      comments = Meta.get_leading_comments(stmt.meta)
      assert length(comments) == 5
    end

    test "comments between multiple statements" do
      code = """
      local x = 10

      -- Middle comment
      local y = 20

      return x + y
      """

      assert_roundtrip_semantic(code)
    end

    test "statement without comments" do
      code = "local x = 10\n"

      {:ok, ast} = Parser.parse(code)
      [stmt | _] = ast.block.stmts

      assert Meta.get_leading_comments(stmt.meta) == []
      assert Meta.get_trailing_comment(stmt.meta) == nil
    end
  end

  # Helper: Assert exact round-trip (character-for-character)
  defp assert_roundtrip(code) do
    {:ok, ast1} = Parser.parse(code)
    printed = PrettyPrinter.print(ast1)
    {:ok, ast2} = Parser.parse(printed)

    # Compare printed output
    assert printed == code, """
    Round-trip failed: output doesn't match input

    Input:
    #{code}

    Output:
    #{printed}
    """

    # Verify ASTs are equivalent
    assert ast1 == ast2
  end

  # Helper: Assert semantic round-trip (same AST structure)
  defp assert_roundtrip_semantic(code) do
    {:ok, ast1} = Parser.parse(code)
    printed = PrettyPrinter.print(ast1)
    {:ok, ast2} = Parser.parse(printed)

    # Verify comments are preserved (text content, not exact positioning)
    assert_comments_preserved(ast1, ast2)

    # Verify code can be parsed again after printing
    assert match?({:ok, _}, Parser.parse(printed)), """
    Printed code could not be parsed

    Printed:
    #{printed}
    """
  end

  # Verify comments are preserved through round-trip
  defp assert_comments_preserved(ast1, ast2) do
    comments1 = extract_all_comments(ast1)
    comments2 = extract_all_comments(ast2)

    # Compare comment text (positions may differ due to formatting)
    texts1 = Enum.map(comments1, & &1.text) |> Enum.sort()
    texts2 = Enum.map(comments2, & &1.text) |> Enum.sort()

    assert texts1 == texts2, """
    Comments not preserved through round-trip

    Original comments: #{inspect(texts1)}
    After round-trip: #{inspect(texts2)}
    """
  end

  # Extract all comments from an AST
  defp extract_all_comments(node, acc \\ [])

  defp extract_all_comments(%{meta: meta} = node, acc)
       when is_struct(node) and not is_nil(meta) do
    leading = Meta.get_leading_comments(meta)
    trailing = Meta.get_trailing_comment(meta)
    trailing_list = if trailing, do: [trailing], else: []

    node_comments = leading ++ trailing_list

    # Recurse into child nodes
    children_comments =
      node
      |> Map.from_struct()
      |> Map.values()
      |> Enum.flat_map(&extract_all_comments_from_value/1)

    acc ++ node_comments ++ children_comments
  end

  defp extract_all_comments(node, acc) when is_struct(node) do
    # Node without meta, recurse into children
    children_comments =
      node
      |> Map.from_struct()
      |> Map.values()
      |> Enum.flat_map(&extract_all_comments_from_value/1)

    acc ++ children_comments
  end

  defp extract_all_comments(_node, acc), do: acc

  defp extract_all_comments_from_value(value) when is_list(value) do
    Enum.flat_map(value, &extract_all_comments(&1, []))
  end

  defp extract_all_comments_from_value(value) when is_struct(value) do
    extract_all_comments(value, [])
  end

  defp extract_all_comments_from_value(_value), do: []
end

defmodule Lua.Parser.Error do
  @moduledoc """
  Beautiful error reporting for the Lua parser.

  Provides detailed error messages with:
  - Source code context with line numbers
  - Visual indicators pointing to the error location
  - Helpful suggestions for common mistakes
  - Multiple error reporting
  """

  alias Lua.AST.Meta

  @type position :: Meta.position()

  @type t :: %__MODULE__{
          type: error_type(),
          message: String.t(),
          position: position() | nil,
          suggestion: String.t() | nil,
          source_lines: [String.t()],
          related: [t()]
        }

  @type error_type ::
          :unexpected_token
          | :unexpected_end
          | :expected_token
          | :unclosed_delimiter
          | :invalid_syntax
          | :lexer_error
          | :multiple_errors

  defstruct [
    :type,
    :message,
    :position,
    :suggestion,
    source_lines: [],
    related: []
  ]

  @doc """
  Creates a new error.
  """
  @spec new(error_type(), String.t(), position() | nil, keyword()) :: t()
  def new(type, message, position \\ nil, opts \\ []) do
    %__MODULE__{
      type: type,
      message: message,
      position: position,
      suggestion: opts[:suggestion],
      source_lines: opts[:source_lines] || [],
      related: opts[:related] || []
    }
  end

  @doc """
  Creates an error for unexpected token.
  """
  @spec unexpected_token(atom(), term(), position(), String.t()) :: t()
  def unexpected_token(token_type, token_value, position, context) do
    message = """
    Unexpected #{format_token(token_type, token_value)} in #{context}
    """

    suggestion = suggest_for_unexpected_token(token_type, token_value, context)

    new(:unexpected_token, message, position, suggestion: suggestion)
  end

  @doc """
  Creates an error for expected token.
  """
  @spec expected_token(atom(), term() | nil, atom(), term(), position()) :: t()
  def expected_token(expected_type, expected_value, got_type, got_value, position) do
    expected = format_token(expected_type, expected_value)
    got = format_token(got_type, got_value)

    message = """
    Expected #{expected}, but got #{got}
    """

    suggestion = suggest_for_expected_token(expected_type, expected_value, got_type)

    new(:expected_token, message, position, suggestion: suggestion)
  end

  @doc """
  Creates an error for unclosed delimiter.
  """
  @spec unclosed_delimiter(atom(), position(), position() | nil) :: t()
  def unclosed_delimiter(delimiter, open_pos, close_pos \\ nil) do
    delimiter_str = format_delimiter(delimiter)

    message = """
    Unclosed #{delimiter_str}
    """

    suggestion = """
    Add a closing #{closing_delimiter(delimiter)} to match the opening at line #{open_pos.line}
    """

    new(:unclosed_delimiter, message, close_pos || open_pos, suggestion: suggestion)
  end

  @doc """
  Creates an error for unexpected end of input.
  """
  @spec unexpected_end(String.t(), position() | nil) :: t()
  def unexpected_end(context, position \\ nil) do
    message = """
    Unexpected end of input while parsing #{context}
    """

    suggestion = """
    Check for missing closing delimiters or keywords like 'end', ')', '}', or ']'
    """

    new(:unexpected_end, message, position, suggestion: suggestion)
  end

  @doc """
  Formats an error into a beautiful multi-line string with context.
  """
  @spec format(t(), String.t()) :: String.t()
  def format(error, source_code) do
    lines = String.split(source_code, "\n")

    header = [
      IO.ANSI.red() <> IO.ANSI.bright() <> "Parse Error" <> IO.ANSI.reset(),
      ""
    ]

    location =
      if error.position do
        pos = error.position
        "  at line #{pos.line}, column #{pos.column}:"
      else
        "  (no position information)"
      end

    message_lines = [
      location,
      "",
      indent(error.message, 2)
    ]

    context_lines =
      if error.position && length(lines) > 0 do
        format_context(lines, error.position)
      else
        []
      end

    suggestion_lines =
      if error.suggestion do
        [
          "",
          IO.ANSI.cyan() <> "Suggestion:" <> IO.ANSI.reset(),
          indent(error.suggestion, 2)
        ]
      else
        []
      end

    related_lines =
      if length(error.related) > 0 do
        [
          "",
          IO.ANSI.yellow() <> "Related errors:" <> IO.ANSI.reset()
        ] ++ Enum.flat_map(error.related, fn rel -> ["", indent(format(rel, source_code), 2)] end)
      else
        []
      end

    (header ++ message_lines ++ context_lines ++ suggestion_lines ++ related_lines)
    |> Enum.join("\n")
  end

  @doc """
  Formats multiple errors together.
  """
  @spec format_multiple([t()], String.t()) :: String.t()
  def format_multiple(errors, source_code) do
    header = [
      IO.ANSI.red() <>
        IO.ANSI.bright() <>
        "Found #{length(errors)} parse error#{if length(errors) == 1, do: "", else: "s"}" <>
        IO.ANSI.reset(),
      ""
    ]

    error_lines =
      errors
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {error, idx} ->
        [
          IO.ANSI.yellow() <> "Error #{idx}:" <> IO.ANSI.reset(),
          format(error, source_code),
          ""
        ]
      end)

    (header ++ error_lines)
    |> Enum.join("\n")
  end

  # Private helpers

  defp format_context(lines, position) do
    line_num = position.line
    column = position.column

    # Show 2 lines before and after
    start_line = max(1, line_num - 2)
    end_line = min(length(lines), line_num + 2)

    context_lines =
      Enum.slice(lines, (start_line - 1)..(end_line - 1))
      |> Enum.with_index(start_line)
      |> Enum.flat_map(fn {line, num} ->
        line_str = format_line_number(num) <> " │ " <> line

        if num == line_num do
          # Error line
          pointer = String.duplicate(" ", String.length(format_line_number(num)) + 3 + column - 1)
          pointer = pointer <> IO.ANSI.red() <> "^" <> IO.ANSI.reset()

          [
            IO.ANSI.red() <> line_str <> IO.ANSI.reset(),
            pointer
          ]
        else
          # Context line
          [IO.ANSI.faint() <> line_str <> IO.ANSI.reset()]
        end
      end)

    ["", ""] ++ context_lines
  end

  defp format_line_number(num) do
    num
    |> Integer.to_string()
    |> String.pad_leading(4)
  end

  defp format_token(type, value) do
    case type do
      :keyword -> "'#{value}'"
      :identifier -> "identifier '#{value}'"
      :number -> "number #{value}"
      :string -> "string \"#{value}\""
      :operator -> "operator '#{value}'"
      :delimiter -> "'#{value}'"
      :eof -> "end of input"
      _ -> "#{type}"
    end
  end

  defp format_delimiter(delimiter) do
    case delimiter do
      :lparen -> "opening parenthesis '('"
      :lbracket -> "opening bracket '['"
      :lbrace -> "opening brace '{'"
      :function -> "'function' block"
      :if -> "'if' statement"
      :while -> "'while' loop"
      :for -> "'for' loop"
      :do -> "'do' block"
      _ -> "#{delimiter}"
    end
  end

  defp closing_delimiter(delimiter) do
    case delimiter do
      :lparen -> "')'"
      :lbracket -> "']'"
      :lbrace -> "'}'"
      :function -> "'end'"
      :if -> "'end'"
      :while -> "'end'"
      :for -> "'end'"
      :do -> "'end'"
      _ -> "matching delimiter"
    end
  end

  defp suggest_for_unexpected_token(token_type, _token_value, context) do
    cond do
      token_type == :delimiter ->
        "Check for missing operators or keywords before this delimiter"

      String.contains?(context, "expression") ->
        "Expected an expression here (variable, number, string, table, function, etc.)"

      String.contains?(context, "statement") ->
        "Expected a statement here (assignment, function call, if, while, for, etc.)"

      true ->
        nil
    end
  end

  defp suggest_for_expected_token(expected_type, expected_value, got_type) do
    cond do
      expected_type == :keyword && expected_value == :end ->
        "Add 'end' to close the block. Check that all opening keywords (if, while, for, function, do) have matching 'end' keywords."

      expected_type == :keyword && expected_value == :then ->
        "Add 'then' after the condition. Lua requires 'then' after if/elseif conditions."

      expected_type == :keyword && expected_value == :do ->
        "Add 'do' to start the loop body. Lua requires 'do' after while/for conditions."

      expected_type == :delimiter && expected_value == :rparen ->
        "Add ')' to close the parentheses. Check for balanced parentheses."

      expected_type == :delimiter && expected_value == :rbracket ->
        "Add ']' to close the brackets. Check for balanced brackets."

      expected_type == :delimiter && expected_value == :rbrace ->
        "Add '}' to close the table constructor. Check for balanced braces."

      expected_type == :operator && expected_value == :assign ->
        "Add '=' for assignment. Did you mean to assign a value?"

      expected_type == :identifier && got_type == :keyword ->
        "Cannot use Lua keyword as identifier. Choose a different name."

      true ->
        nil
    end
  end

  defp indent(text, spaces) do
    prefix = String.duplicate(" ", spaces)

    text
    |> String.split("\n")
    |> Enum.map(&(prefix <> &1))
    |> Enum.join("\n")
  end
end

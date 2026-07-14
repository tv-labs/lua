defmodule Lua.Parser.Error do
  @moduledoc """
  Structured, wire-safe error reporting for the Lua parser.

  Each error carries:
  - Source code context with line numbers
  - Position information pointing to the error location
  - A human-readable message and, where possible, a suggested fix
  - Related errors, for multi-error reporting

  Produced when parsing fails: the parser's parse_structured/1 entry point
  returns `{:error, [t()]}`. Call `to_map/2` for a JSON-serializable shape
  suitable for editors, LSPs, and web frontends.
  """

  @type position :: %{
          line: pos_integer(),
          column: pos_integer(),
          byte_offset: non_neg_integer()
        }

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

  @type source_context :: %{
          lines: [%{number: pos_integer(), text: String.t(), highlight?: boolean()}],
          pointer_column: pos_integer()
        }

  @typedoc """
  Wire-safe representation produced by `to_map/2`. Mirrors the shape used
  for runtime errors so runtime and parse errors render through one path.
  `source`, `call_stack`, and `error_kind` are constant
  for parse errors (no file name, stack, or error kind) and exist only for
  shape parity.
  """
  @type wire_error :: %{
          type: error_type(),
          message: String.t() | nil,
          source: nil,
          line: pos_integer() | nil,
          call_stack: [],
          source_context: source_context() | nil,
          suggestion: String.t() | nil,
          error_kind: nil
        }

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
  Returns a wire-safe structured representation of a parse error.

  The shape is identical to the map produced for runtime errors, so runtime
  and parse errors can flow through a single renderer (HTML, JSON, structured
  logs). No ANSI escapes appear in any string field, and leading/trailing
  whitespace from the internal message/suggestion templates is trimmed.

      %{
        type: atom(),
        message: String.t(),
        source: String.t() | nil,
        line: pos_integer() | nil,
        call_stack: [],
        source_context: %{
          lines: [%{number: pos_integer(), text: String.t(), highlight?: boolean()}],
          pointer_column: pos_integer()
        } | nil,
        suggestion: String.t() | nil,
        error_kind: nil
      }

  Parse errors carry no call stack or error kind, so `call_stack` is always
  `[]` and `error_kind` is always `nil`; they are present for shape parity.
  `source` is `nil` because the parser does not track a file name.

  Pass the original source code as the second argument to populate
  `source_context`. The `pointer_column` is taken from the error's real
  column when a position is known, so the `^` marker lands on the offending
  token instead of always pointing at column 1.

      iex> {:error, [error]} = Lua.Parser.parse_structured("if x then")
      iex> map = Lua.Parser.Error.to_map(error, "if x then")
      iex> {map.type, map.source_context.pointer_column}
      {:unexpected_token, 10}
  """
  @spec to_map(t(), String.t() | nil) :: wire_error()
  def to_map(%__MODULE__{} = error, source_code \\ nil) do
    %{
      type: error.type,
      message: clean(error.message),
      source: nil,
      line: error.position && error.position.line,
      call_stack: [],
      source_context: build_source_context(source_code, error.position),
      suggestion: clean(error.suggestion),
      error_kind: nil
    }
  end

  defp clean(nil), do: nil
  defp clean(text) when is_binary(text), do: String.trim(text)

  # Deliberately mirrors `Lua.VM.ErrorFormatter`'s private source-context
  # windowing (same 2-before/2-after math) to keep the wire shapes in lockstep.
  # Duplicated rather than shared so the parser stays decoupled from the VM;
  # the parity test in error_to_map_test.exs guards against the two drifting.
  defp build_source_context(nil, _position), do: nil
  defp build_source_context(_source_code, nil), do: nil

  defp build_source_context(source_code, %{line: line} = position) when is_binary(source_code) and is_integer(line) do
    lines = String.split(source_code, "\n")
    total = length(lines)

    if line > 0 and line <= total do
      start_line = max(1, line - 2)
      end_line = min(total, line + 2)

      rendered_lines =
        lines
        |> Enum.slice((start_line - 1)..(end_line - 1))
        |> Enum.with_index(start_line)
        |> Enum.map(fn {text, num} ->
          %{number: num, text: text, highlight?: num == line}
        end)

      %{lines: rendered_lines, pointer_column: position.column}
    end
  end

  defp build_source_context(_source_code, _position), do: nil

  @doc """
  Formats an error into a beautiful multi-line string with context.
  """
  @spec format(t(), String.t()) :: String.t()
  def format(error, source_code) do
    lines = String.split(source_code, "\n")

    header = [
      color("Parse Error", IO.ANSI.red() <> IO.ANSI.bright()),
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
          color("Suggestion:", IO.ANSI.cyan()),
          indent(error.suggestion, 2)
        ]
      else
        []
      end

    related_lines =
      if length(error.related) > 0 do
        [
          "",
          color("Related errors:", IO.ANSI.yellow())
        ] ++ Enum.flat_map(error.related, fn rel -> ["", indent(format(rel, source_code), 2)] end)
      else
        []
      end

    Enum.join(header ++ message_lines ++ context_lines ++ suggestion_lines ++ related_lines, "\n")
  end

  @doc """
  Formats multiple errors together.
  """
  @spec format_multiple([t()], String.t()) :: String.t()
  def format_multiple(errors, source_code) do
    header = [
      color(
        "Found #{length(errors)} parse error#{if length(errors) == 1, do: "", else: "s"}",
        IO.ANSI.red() <> IO.ANSI.bright()
      ),
      ""
    ]

    error_lines =
      errors
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {error, idx} ->
        [
          color("Error #{idx}:", IO.ANSI.yellow()),
          format(error, source_code),
          ""
        ]
      end)

    Enum.join(header ++ error_lines, "\n")
  end

  # Private helpers

  # ANSI helpers — no-ops unless the terminal actually supports color, so
  # piping to a file or a non-TTY never embeds raw escape codes. Mirrors
  # `Lua.VM.ErrorFormatter.color/2` so parse and runtime errors gate the same
  # way (see issue #382).
  defp color(text, ansi) do
    if IO.ANSI.enabled?() do
      ansi <> text <> IO.ANSI.reset()
    else
      text
    end
  end

  defp format_context(lines, position) do
    line_num = position.line
    column = position.column

    # Show 2 lines before and after
    start_line = max(1, line_num - 2)
    end_line = min(length(lines), line_num + 2)

    context_lines =
      lines
      |> Enum.slice((start_line - 1)..(end_line - 1))
      |> Enum.with_index(start_line)
      |> Enum.flat_map(fn {line, num} ->
        line_str = format_line_number(num) <> " │ " <> line

        if num == line_num do
          # Error line
          pointer = String.duplicate(" ", String.length(format_line_number(num)) + 3 + column - 1)
          pointer = pointer <> color("^", IO.ANSI.red())

          [
            color(line_str, IO.ANSI.red()),
            pointer
          ]
        else
          # Context line
          [color(line_str, IO.ANSI.faint())]
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
    |> Enum.map_join("\n", &(prefix <> &1))
  end
end

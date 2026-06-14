defmodule Lua.VM.ErrorFormatter do
  @moduledoc """
  Error formatting for Lua runtime errors.

  Two entry points share the same underlying data:

    * `format/3` renders a multi-line string for terminal output (location,
      message body, source context with pointer, stack trace, suggestion).
      ANSI color is applied only when `IO.ANSI.enabled?/0` is true, so the
      same render path is safe whether the output goes to a TTY or is piped
      to a file.
    * `to_map/3` returns a wire-safe structured map for non-terminal consumers
      (HTML rendering, JSON payloads, structured logs). No ANSI escapes appear
      in any string field.

  The rendered layout leads with the source location so the reader sees
  *where* before *what*:

      at demo.lua:3:

        attempt to perform arithmetic on a nil value
        ...

  There is deliberately no separate "Runtime Type Error" header line — the
  public `Lua.RuntimeException` already prefixes `Lua runtime error: `, and
  the message body itself ("attempt to ...", "assertion failed: ...") names
  the category. Stacking a second header would be redundant.
  """

  alias Lua.VM.Executor

  @doc """
  Formats a runtime error into a multi-line string.

  ANSI color is applied only when `IO.ANSI.enabled?/0` returns true.

  ## Options

    * `:source` - Source file name
    * `:line` - Line number where error occurred
    * `:call_stack` - List of stack frames
    * `:source_code` - Full source code for context display
    * `:error_kind` - Structured error kind atom for suggestions (e.g., `:call_nil`, `:call_non_function`, `:index_non_table`)
    * `:value_type` - Type of the problematic value (e.g., `:number`, `:string`, `:table`)

  """
  def format(error_type, message, opts \\ []) do
    source = Keyword.get(opts, :source)
    line = Keyword.get(opts, :line)
    call_stack = Keyword.get(opts, :call_stack, [])
    source_code = Keyword.get(opts, :source_code)
    error_kind = Keyword.get(opts, :error_kind)
    value_type = Keyword.get(opts, :value_type)

    location = format_location(source, line)
    message_section = format_message(message)
    context = format_source_context(source_code, line)
    stack_trace = format_stack_trace(call_stack)
    suggestion = format_suggestion(error_type, error_kind, value_type)

    [location, message_section, context, stack_trace, suggestion]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("")
    |> String.trim_leading()
  end

  @doc """
  Returns a wire-safe structured representation of an error.

  The shape:

      %{
        type: atom(),
        message: String.t(),
        source: String.t() | nil,
        line: pos_integer() | nil,
        call_stack: [%{source: String.t() | nil, line: pos_integer() | nil, name: String.t() | nil}],
        source_context: %{
          lines: [%{number: pos_integer(), text: String.t(), highlight?: boolean()}],
          pointer_column: pos_integer() | nil
        } | nil,
        suggestion: String.t() | nil,
        error_kind: atom() | nil
      }

  `source_context` is only populated when both `:source_code` and `:line` are
  provided. `pointer_column` reflects the column where the `^` marker points;
  the formatter does not currently track real column positions, so it is `1`
  when a highlighted line is present and `nil` otherwise.

  ## Options

  Accepts the same options as `format/3`.
  """
  def to_map(error_type, message, opts \\ []) do
    source = Keyword.get(opts, :source)
    line = Keyword.get(opts, :line)
    call_stack = Keyword.get(opts, :call_stack, [])
    source_code = Keyword.get(opts, :source_code)
    error_kind = Keyword.get(opts, :error_kind)
    value_type = Keyword.get(opts, :value_type)

    %{
      type: error_type,
      message: message,
      source: source,
      line: line,
      call_stack: build_call_stack(call_stack),
      source_context: build_source_context(source_code, line),
      suggestion: build_suggestion(error_type, error_kind, value_type),
      error_kind: error_kind
    }
  end

  # ANSI helpers — no-ops unless the terminal actually supports color, so
  # piping to a file or a non-TTY never embeds raw escape codes.
  defp color(text, ansi) do
    if IO.ANSI.enabled?() do
      ansi <> text <> IO.ANSI.reset()
    else
      text
    end
  end

  defp format_location(nil, nil), do: nil
  defp format_location(source, nil), do: color("at #{source}:", IO.ANSI.faint()) <> "\n\n"
  defp format_location(nil, line), do: color("at line #{line}:", IO.ANSI.faint()) <> "\n\n"

  defp format_location(source, line), do: color("at #{source}:#{line}:", IO.ANSI.faint()) <> "\n\n"

  defp format_message(message), do: "  #{message}"

  defp format_source_context(source_code, line) do
    case build_source_context(source_code, line) do
      nil -> nil
      %{lines: lines} -> render_source_context(lines)
    end
  end

  defp render_source_context(lines) do
    context_lines =
      Enum.flat_map(lines, fn %{number: num, text: text, highlight?: highlight?} ->
        line_str = format_line_number(num) <> " │ " <> text

        if highlight? do
          pointer_offset = String.length(format_line_number(num)) + 3

          pointer =
            String.duplicate(" ", pointer_offset) <> color("^", IO.ANSI.red())

          [
            "\n" <> color(line_str, IO.ANSI.red()),
            "\n" <> pointer
          ]
        else
          ["\n" <> color(line_str, IO.ANSI.faint())]
        end
      end)

    "\n" <> Enum.join(context_lines)
  end

  defp build_source_context(nil, _line), do: nil
  defp build_source_context(_source_code, nil), do: nil

  defp build_source_context(source_code, line) when is_binary(source_code) and is_integer(line) do
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

      %{lines: rendered_lines, pointer_column: 1}
    end
  end

  defp build_source_context(_source_code, _line), do: nil

  defp format_line_number(num) do
    num
    |> Integer.to_string()
    |> String.pad_leading(4)
  end

  # A deep recursion (see `:max_call_depth`) can push hundreds of frames
  # onto the stack. Rendering all of them produces an unreadable wall of
  # near-identical lines, so we keep the innermost frames (where the error
  # fired) and the outermost frames (down to the main chunk), collapsing
  # the middle into a single count. Only kicks in when the gap line
  # replaces at least two frames.
  @trace_head 7
  @trace_tail 3

  defp format_stack_trace([]), do: nil

  defp format_stack_trace(call_stack) when is_list(call_stack) do
    frames =
      call_stack
      |> build_call_stack()
      |> truncate_frames()
      |> Enum.map_join("\n", &format_frame/1)

    "\n\n" <> color("Stack trace:", IO.ANSI.cyan()) <> "\n" <> frames
  end

  defp truncate_frames(frames) do
    count = length(frames)

    if count > @trace_head + @trace_tail + 1 do
      omitted = count - @trace_head - @trace_tail
      Enum.take(frames, @trace_head) ++ [{:omitted, omitted}] ++ Enum.take(frames, -@trace_tail)
    else
      frames
    end
  end

  defp build_call_stack(call_stack) when is_list(call_stack) do
    Enum.map(call_stack, fn frame ->
      %{
        source: Executor.frame_source(frame),
        line: Executor.frame_line(frame),
        name: Executor.frame_name(frame)
      }
    end)
  end

  defp build_call_stack(_), do: []

  defp format_frame({:omitted, count}) do
    color("  ... #{count} more frames ...", IO.ANSI.faint())
  end

  defp format_frame(%{source: source, line: line, name: name}) do
    location = "  #{source || "-no-source-"}:#{line}:"

    context =
      case name do
        nil -> " in main chunk"
        func_name -> " in function '#{func_name}'"
      end

    location <> context
  end

  defp format_suggestion(error_type, error_kind, value_type) do
    case build_suggestion(error_type, error_kind, value_type) do
      nil -> nil
      text -> suggestion(text)
    end
  end

  defp build_suggestion(:type_error, :call_nil, _value_type) do
    "The value you're trying to call as a function is nil. Check that the function exists and is defined before this point."
  end

  defp build_suggestion(:type_error, :call_non_function, value_type) do
    "You can only call function values. Check that you're calling a function, not a #{format_type_name(value_type)}."
  end

  defp build_suggestion(:type_error, :index_non_table, value_type) do
    "You can only index tables. Make sure the value you're indexing is a table, not a #{format_type_name(value_type)}."
  end

  defp build_suggestion(:type_error, :arithmetic_on_non_number, _value_type) do
    "Arithmetic requires numbers. Make sure both operands are numbers (or strings that can be coerced to numbers)."
  end

  defp build_suggestion(:type_error, :concatenate_type_error, _value_type) do
    "Concatenation (..) requires strings or numbers. Convert other values with tostring() first."
  end

  defp build_suggestion(:type_error, :compare_incompatible_types, _value_type) do
    "Relational operators (< <= > >=) only compare two numbers or two strings. Convert one operand so both sides share a type."
  end

  defp build_suggestion(:type_error, :length_not_integer, _value_type) do
    "The length operation returned a non-integer value. If you defined a __len metamethod, make sure it returns an integer."
  end

  defp build_suggestion(:type_error, :bitwise_on_non_integer, _value_type) do
    "Bitwise operators require integers. Floats with no fractional part are accepted; everything else must be converted first."
  end

  defp build_suggestion(:type_error, :for_loop_non_number, _value_type) do
    "Numeric for loops need number values for the start, limit, and step. Check the loop bounds."
  end

  defp build_suggestion(_, _, _), do: nil

  defp suggestion(text) do
    "\n\n" <> color("Suggestion:", IO.ANSI.cyan()) <> "\n  " <> text
  end

  defp format_type_name(:number), do: "number"
  defp format_type_name(:string), do: "string"
  defp format_type_name(:boolean), do: "boolean"
  defp format_type_name(:table), do: "table"
  defp format_type_name(nil), do: "nil"
  defp format_type_name(_), do: "value"
end

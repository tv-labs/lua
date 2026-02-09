defmodule Lua.VM.ErrorFormatter do
  @moduledoc """
  Beautiful error formatting for Lua runtime errors.

  Provides detailed error messages with:
  - ANSI-colored error type headers
  - Clear error messages
  - Source context with line numbers and pointer
  - Stack traces
  - Suggestions for common mistakes
  """

  @doc """
  Formats a runtime error into a beautiful multi-line string.
  """
  def format(error_type, message, opts \\ []) do
    source = Keyword.get(opts, :source)
    line = Keyword.get(opts, :line)
    call_stack = Keyword.get(opts, :call_stack, [])
    source_code = Keyword.get(opts, :source_code)

    header = format_header(error_type)
    location = format_location(source, line)
    message_section = format_message(message)
    context = format_source_context(source_code, line)
    stack_trace = format_stack_trace(call_stack)
    suggestion = format_suggestion(error_type, message)

    [header, location, message_section, context, stack_trace, suggestion]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp format_header(:type_error) do
    IO.ANSI.red() <> IO.ANSI.bright() <> "Runtime Type Error" <> IO.ANSI.reset()
  end

  defp format_header(:runtime_error) do
    IO.ANSI.red() <> IO.ANSI.bright() <> "Runtime Error" <> IO.ANSI.reset()
  end

  defp format_header(:assertion_error) do
    IO.ANSI.red() <> IO.ANSI.bright() <> "Assertion Failed" <> IO.ANSI.reset()
  end

  defp format_header(_), do: IO.ANSI.red() <> IO.ANSI.bright() <> "Error" <> IO.ANSI.reset()

  defp format_location(nil, nil), do: nil
  defp format_location(source, nil), do: "\n  at #{source}:"
  defp format_location(nil, line), do: "\n  at line #{line}:"
  defp format_location(source, line), do: "\n  at #{source}:#{line}:"

  defp format_message(message) do
    "\n  #{message}"
  end

  defp format_source_context(nil, _line), do: nil
  defp format_source_context(_source_code, nil), do: nil

  defp format_source_context(source_code, line) when is_binary(source_code) do
    lines = String.split(source_code, "\n")

    if line > 0 and line <= length(lines) do
      # Show 2 lines before and after
      start_line = max(1, line - 2)
      end_line = min(length(lines), line + 2)

      context_lines =
        Enum.slice(lines, (start_line - 1)..(end_line - 1))
        |> Enum.with_index(start_line)
        |> Enum.flat_map(fn {line_text, num} ->
          line_str = format_line_number(num) <> " │ " <> line_text

          if num == line do
            # Error line - add pointer
            pointer_offset = String.length(format_line_number(num)) + 3

            pointer =
              String.duplicate(" ", pointer_offset) <> IO.ANSI.red() <> "^" <> IO.ANSI.reset()

            [
              "\n" <> IO.ANSI.red() <> line_str <> IO.ANSI.reset(),
              pointer
            ]
          else
            # Context line
            ["\n" <> IO.ANSI.faint() <> line_str <> IO.ANSI.reset()]
          end
        end)

      "\n" <> Enum.join(context_lines)
    else
      nil
    end
  end

  defp format_line_number(num) do
    num
    |> Integer.to_string()
    |> String.pad_leading(4)
  end

  defp format_stack_trace([]), do: nil

  defp format_stack_trace(call_stack) when is_list(call_stack) do
    frames =
      call_stack
      |> Enum.map(&format_frame/1)
      |> Enum.join("\n")

    "\n\n" <> IO.ANSI.cyan() <> "Stack trace:" <> IO.ANSI.reset() <> "\n" <> frames
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

  defp format_suggestion(:type_error, message) do
    cond do
      String.contains?(message, "call a nil value") ->
        suggestion(
          "The value you're trying to call as a function is nil. Check that the function exists and is defined before this point."
        )

      String.contains?(message, "call a") ->
        suggestion(
          "You can only call function values. Check that you're calling a function, not a #{extract_type(message)}."
        )

      String.contains?(message, "index") ->
        suggestion(
          "You can only index tables. Make sure the value you're indexing is a table, not a #{extract_type(message)}."
        )

      String.contains?(message, "arithmetic") ->
        suggestion(
          "Arithmetic operations require numbers. Make sure both operands are numbers or strings that can be converted to numbers."
        )

      String.contains?(message, "concatenate") ->
        suggestion("String concatenation (..) requires strings or numbers, not other types.")

      true ->
        nil
    end
  end

  defp format_suggestion(:assertion_error, _message) do
    suggestion("The assertion condition evaluated to false or nil. Check your logic.")
  end

  defp format_suggestion(_, _), do: nil

  defp suggestion(text) do
    "\n\n" <> IO.ANSI.cyan() <> "Suggestion:" <> IO.ANSI.reset() <> "\n  " <> text
  end

  defp extract_type(message) do
    cond do
      String.contains?(message, "string value") -> "string"
      String.contains?(message, "number value") -> "number"
      String.contains?(message, "boolean value") -> "boolean"
      String.contains?(message, "table value") -> "table"
      true -> "value"
    end
  end
end

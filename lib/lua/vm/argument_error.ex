defmodule Lua.VM.ArgumentError do
  @moduledoc """
  Raised when a function is called with invalid arguments.

  This exception provides standardized error messages for bad arguments across
  all Lua standard library functions.

  ## Fields

    - `:function_name` - The fully qualified function name (e.g., "string.rep")
    - `:arg_num` - The argument number (1-based)
    - `:expected` - What type or value was expected (e.g., "number", "string")
    - `:got` - What was actually received (optional, e.g., "nil", "boolean")
    - `:details` - Additional details about the error (optional)
    - `:line` - Source line where the call originated (auto-populated from
      `Lua.VM.Executor.current_position/0` when not given explicitly)
    - `:source` - Source name where the call originated (auto-populated)
    - `:call_stack` - Call stack frames at the raise site (default `[]`)

  ## Examples

      # Basic type error — line/source filled in automatically when raised
      # from inside a Lua execution.
      raise ArgumentError,
        function_name: "string.rep",
        arg_num: 2,
        expected: "number"

      # With actual type received
      raise ArgumentError,
        function_name: "string.sub",
        arg_num: 2,
        expected: "number",
        got: "string"

      # With additional details
      raise ArgumentError,
        function_name: "string.char",
        arg_num: 1,
        expected: "number",
        details: "value out of range"
  """

  defexception [
    :function_name,
    :arg_num,
    :expected,
    :got,
    :details,
    :line,
    :source,
    :call_stack
  ]

  @impl true
  def exception(opts) do
    {auto_line, auto_source} = Lua.VM.Executor.current_position()

    function_name = Keyword.fetch!(opts, :function_name)

    %__MODULE__{
      function_name: function_name,
      arg_num: Keyword.get(opts, :arg_num),
      expected: Keyword.get(opts, :expected),
      got: Keyword.get(opts, :got),
      details: Keyword.get(opts, :details),
      line: Keyword.get(opts, :line) || auto_line,
      source: Keyword.get(opts, :source) || auto_source,
      call_stack: Keyword.get(opts, :call_stack, [])
    }
  end

  @impl true
  def message(%__MODULE__{} = e) do
    base = build_base(e.function_name, e.arg_num, e.expected, e.got, e.details)

    Lua.VM.ErrorFormatter.format(:type_error, base,
      source: e.source,
      line: e.line,
      call_stack: e.call_stack
    )
  end

  defp build_base(function_name, arg_num, expected, got, details) do
    base =
      if arg_num do
        "bad argument ##{arg_num} to '#{function_name}'"
      else
        "bad argument to '#{function_name}'"
      end

    expectation =
      case {expected, got} do
        {nil, nil} ->
          nil

        {exp, nil} ->
          "(#{exp} expected)"

        {exp, got_val} ->
          "(#{exp} expected, got #{got_val})"
      end

    case {expectation, details} do
      {nil, nil} -> base
      {exp, nil} -> "#{base} #{exp}"
      {nil, detail} -> "#{base} (#{detail})"
      {_exp, detail} -> "#{base} (#{detail})"
    end
  end

  @doc """
  Creates an ArgumentError when no value is provided for a required argument.

  ## Example

      ArgumentError.value_expected("string.lower", 1)
  """
  def value_expected(function_name, arg_num) do
    exception(
      function_name: function_name,
      arg_num: arg_num,
      expected: "value"
    )
  end

  @doc """
  Creates an ArgumentError for type mismatches.

  ## Example

      ArgumentError.type_error("string.rep", 2, "number", "string")
  """
  def type_error(function_name, arg_num, expected, got) do
    exception(
      function_name: function_name,
      arg_num: arg_num,
      expected: expected,
      got: got
    )
  end
end

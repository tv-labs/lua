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

  alias Lua.VM.RuntimeError

  @type t :: %__MODULE__{}

  # `:state` carries the `Lua.VM.State` as of the raise, so protected calls
  # (pcall/xpcall) can keep heap effects made before the error instead of
  # rolling back to their entry snapshot. It is out-of-band metadata: it never
  # participates in `message` and stays `nil` when no state was in scope.
  @derive {Inspect, except: [:state]}
  defexception [
    :function_name,
    :arg_num,
    :expected,
    :got,
    :details,
    :line,
    :source,
    :call_stack,
    :state
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
      call_stack: Keyword.get(opts, :call_stack, []),
      state: Keyword.get(opts, :state)
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
  @spec value_expected(String.t(), pos_integer()) :: t()
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
  @spec type_error(String.t(), pos_integer(), String.t(), String.t()) :: t()
  def type_error(function_name, arg_num, expected, got) do
    exception(
      function_name: function_name,
      arg_num: arg_num,
      expected: expected,
      got: got
    )
  end

  @doc """
  Builds the PUC-Lua "wrong number of arguments to 'X'" runtime error.

  This is not a bad-argument error — it is the top-level message PUC-Lua's
  `luaL_error(L, "wrong number of arguments to '%s'", name)` emits when a
  variadic stdlib function is called with too few or too many positional
  arguments. Returns a `Lua.VM.RuntimeError` so callers can `raise` it
  directly:

      raise ArgumentError.wrong_number_of_arguments("insert")
  """
  @spec wrong_number_of_arguments(String.t()) :: RuntimeError.t()
  def wrong_number_of_arguments(function_name) do
    RuntimeError.exception(value: "wrong number of arguments to '#{function_name}'")
  end
end

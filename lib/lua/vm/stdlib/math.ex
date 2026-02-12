defmodule Lua.VM.Stdlib.Math do
  @moduledoc """
  Lua 5.3 math standard library.

  Provides mathematical functions including trigonometry, logarithms,
  random number generation, and numeric utilities.

  ## Functions

  - `math.abs(x)` - Returns the absolute value of x
  - `math.acos(x)` - Returns the arc cosine of x (in radians)
  - `math.asin(x)` - Returns the arc sine of x (in radians)
  - `math.atan(y [, x])` - Returns the arc tangent of y/x (in radians)
  - `math.ceil(x)` - Returns the smallest integer >= x
  - `math.cos(x)` - Returns the cosine of x (in radians)
  - `math.exp(x)` - Returns e^x
  - `math.floor(x)` - Returns the largest integer <= x
  - `math.log(x [, base])` - Returns the logarithm of x in the given base (default e)
  - `math.max(x, ...)` - Returns the maximum value among arguments
  - `math.min(x, ...)` - Returns the minimum value among arguments
  - `math.pi` - The value of π
  - `math.random([m [, n]])` - Returns a pseudo-random number
  - `math.randomseed(x)` - Sets the seed for the pseudo-random generator
  - `math.sin(x)` - Returns the sine of x (in radians)
  - `math.sqrt(x)` - Returns the square root of x
  - `math.tan(x)` - Returns the tangent of x (in radians)
  - `math.tointeger(x)` - Converts x to an integer, or nil if not possible
  - `math.type(x)` - Returns "integer", "float", or nil
  - `math.huge` - A value larger than any other numeric value
  - `math.maxinteger` - Maximum value for an integer
  - `math.mininteger` - Minimum value for an integer
  """

  @behaviour Lua.VM.Stdlib.Library

  alias Lua.VM.ArgumentError
  alias Lua.VM.State
  alias Lua.VM.Stdlib.Util

  @impl true
  def lib_name, do: "math"

  @impl true
  def install(state) do
    math_table = %{
      "abs" => {:native_func, &math_abs/2},
      "acos" => {:native_func, &math_acos/2},
      "asin" => {:native_func, &math_asin/2},
      "atan" => {:native_func, &math_atan/2},
      "ceil" => {:native_func, &math_ceil/2},
      "cos" => {:native_func, &math_cos/2},
      "exp" => {:native_func, &math_exp/2},
      "floor" => {:native_func, &math_floor/2},
      "log" => {:native_func, &math_log/2},
      "max" => {:native_func, &math_max/2},
      "min" => {:native_func, &math_min/2},
      "pi" => :math.pi(),
      "random" => {:native_func, &math_random/2},
      "randomseed" => {:native_func, &math_randomseed/2},
      "sin" => {:native_func, &math_sin/2},
      "sqrt" => {:native_func, &math_sqrt/2},
      "tan" => {:native_func, &math_tan/2},
      "tointeger" => {:native_func, &math_tointeger/2},
      "type" => {:native_func, &math_type/2},
      "huge" => 1.0e308,
      "maxinteger" => 9_223_372_036_854_775_807,
      "mininteger" => -9_223_372_036_854_775_808
    }

    {tref, state} = State.alloc_table(state, math_table)
    State.set_global(state, "math", tref)
  end

  # math.abs(x)
  defp math_abs([x], state) when is_number(x) do
    {[abs(x)], state}
  end

  defp math_abs([x | _], _state) do
    raise ArgumentError,
      function_name: "math.abs",
      arg_num: 1,
      expected: "number",
      got: Util.typeof(x)
  end

  defp math_abs([], _state) do
    raise ArgumentError.value_expected("math.abs", 1)
  end

  # math.acos(x)
  defp math_acos([x], state) when is_number(x) do
    {[:math.acos(x / 1)], state}
  end

  defp math_acos([x | _], _state) do
    raise ArgumentError,
      function_name: "math.acos",
      arg_num: 1,
      expected: "number",
      got: Util.typeof(x)
  end

  defp math_acos([], _state) do
    raise ArgumentError.value_expected("math.acos", 1)
  end

  # math.asin(x)
  defp math_asin([x], state) when is_number(x) do
    {[:math.asin(x / 1)], state}
  end

  defp math_asin([x | _], _state) do
    raise ArgumentError,
      function_name: "math.asin",
      arg_num: 1,
      expected: "number",
      got: Util.typeof(x)
  end

  defp math_asin([], _state) do
    raise ArgumentError.value_expected("math.asin", 1)
  end

  # math.atan(y [, x])
  defp math_atan([y], state) when is_number(y) do
    {[:math.atan(y / 1)], state}
  end

  defp math_atan([y, x], state) when is_number(y) and is_number(x) do
    {[:math.atan2(y / 1, x / 1)], state}
  end

  defp math_atan([y, x | _], _state) when is_number(y) do
    raise ArgumentError,
      function_name: "math.atan",
      arg_num: 2,
      expected: "number",
      got: Util.typeof(x)
  end

  defp math_atan([y | _], _state) do
    raise ArgumentError,
      function_name: "math.atan",
      arg_num: 1,
      expected: "number",
      got: Util.typeof(y)
  end

  defp math_atan([], _state) do
    raise ArgumentError.value_expected("math.atan", 1)
  end

  # math.ceil(x)
  defp math_ceil([x], state) when is_number(x) do
    {[trunc(Float.ceil(x / 1))], state}
  end

  defp math_ceil([x | _], _state) do
    raise ArgumentError,
      function_name: "math.ceil",
      arg_num: 1,
      expected: "number",
      got: Util.typeof(x)
  end

  defp math_ceil([], _state) do
    raise ArgumentError.value_expected("math.ceil", 1)
  end

  # math.cos(x)
  defp math_cos([x], state) when is_number(x) do
    {[:math.cos(x / 1)], state}
  end

  defp math_cos([x | _], _state) do
    raise ArgumentError,
      function_name: "math.cos",
      arg_num: 1,
      expected: "number",
      got: Util.typeof(x)
  end

  defp math_cos([], _state) do
    raise ArgumentError.value_expected("math.cos", 1)
  end

  # math.exp(x)
  defp math_exp([x], state) when is_number(x) do
    {[:math.exp(x / 1)], state}
  end

  defp math_exp([x | _], _state) do
    raise ArgumentError,
      function_name: "math.exp",
      arg_num: 1,
      expected: "number",
      got: Util.typeof(x)
  end

  defp math_exp([], _state) do
    raise ArgumentError.value_expected("math.exp", 1)
  end

  # math.floor(x)
  defp math_floor([x], state) when is_number(x) do
    {[trunc(Float.floor(x / 1))], state}
  end

  defp math_floor([x | _], _state) do
    raise ArgumentError,
      function_name: "math.floor",
      arg_num: 1,
      expected: "number",
      got: Util.typeof(x)
  end

  defp math_floor([], _state) do
    raise ArgumentError.value_expected("math.floor", 1)
  end

  # math.log(x [, base])
  defp math_log([x], state) when is_number(x) do
    {[:math.log(x / 1)], state}
  end

  defp math_log([x, base], state) when is_number(x) and is_number(base) do
    result = :math.log(x / 1) / :math.log(base / 1)
    {[result], state}
  end

  defp math_log([x, base | _], _state) when is_number(x) do
    raise ArgumentError,
      function_name: "math.log",
      arg_num: 2,
      expected: "number",
      got: Util.typeof(base)
  end

  defp math_log([x | _], _state) do
    raise ArgumentError,
      function_name: "math.log",
      arg_num: 1,
      expected: "number",
      got: Util.typeof(x)
  end

  defp math_log([], _state) do
    raise ArgumentError.value_expected("math.log", 1)
  end

  # math.max(x, ...)
  defp math_max(args, state) when length(args) > 0 do
    if Enum.all?(args, &is_number/1) do
      {[Enum.max(args)], state}
    else
      non_number = Enum.find(args, &(not is_number(&1)))
      idx = Enum.find_index(args, &(&1 == non_number)) + 1

      raise ArgumentError,
        function_name: "math.max",
        arg_num: idx,
        expected: "number",
        got: Util.typeof(non_number)
    end
  end

  defp math_max([], _state) do
    raise ArgumentError.value_expected("math.max", 1)
  end

  # math.min(x, ...)
  defp math_min(args, state) when length(args) > 0 do
    if Enum.all?(args, &is_number/1) do
      {[Enum.min(args)], state}
    else
      non_number = Enum.find(args, &(not is_number(&1)))
      idx = Enum.find_index(args, &(&1 == non_number)) + 1

      raise ArgumentError,
        function_name: "math.min",
        arg_num: idx,
        expected: "number",
        got: Util.typeof(non_number)
    end
  end

  defp math_min([], _state) do
    raise ArgumentError.value_expected("math.min", 1)
  end

  # math.random([m [, n]])
  defp math_random([], state) do
    # Returns a float in [0, 1)
    {[:rand.uniform()], state}
  end

  defp math_random([m], state) when is_integer(m) and m > 0 do
    # Returns an integer in [1, m]
    {[:rand.uniform(m)], state}
  end

  defp math_random([m, n], state) when is_integer(m) and is_integer(n) and m <= n do
    # Returns an integer in [m, n]
    range = n - m + 1
    {[m + :rand.uniform(range) - 1], state}
  end

  defp math_random([m, n | _], _state) when is_integer(m) and is_integer(n) do
    raise ArgumentError,
      function_name: "math.random",
      details: "interval is empty"
  end

  defp math_random([m, n | _], _state) when is_integer(m) do
    raise ArgumentError,
      function_name: "math.random",
      arg_num: 2,
      expected: "number",
      got: Util.typeof(n)
  end

  defp math_random([m | _], _state) do
    raise ArgumentError,
      function_name: "math.random",
      arg_num: 1,
      expected: "number",
      got: Util.typeof(m)
  end

  # math.randomseed(x [, y])
  defp math_randomseed([x], state) when is_integer(x) do
    :rand.seed(:exsss, {x, 0, 0})
    {[], state}
  end

  defp math_randomseed([x, y], state) when is_integer(x) and is_integer(y) do
    :rand.seed(:exsss, {x, y, 0})
    {[], state}
  end

  defp math_randomseed([x, y | _], _state) when is_integer(x) do
    raise ArgumentError,
      function_name: "math.randomseed",
      arg_num: 2,
      expected: "number",
      got: Util.typeof(y)
  end

  defp math_randomseed([x | _], _state) do
    raise ArgumentError,
      function_name: "math.randomseed",
      arg_num: 1,
      expected: "number",
      got: Util.typeof(x)
  end

  defp math_randomseed([], _state) do
    raise ArgumentError.value_expected("math.randomseed", 1)
  end

  # math.sin(x)
  defp math_sin([x], state) when is_number(x) do
    {[:math.sin(x / 1)], state}
  end

  defp math_sin([x | _], _state) do
    raise ArgumentError,
      function_name: "math.sin",
      arg_num: 1,
      expected: "number",
      got: Util.typeof(x)
  end

  defp math_sin([], _state) do
    raise ArgumentError.value_expected("math.sin", 1)
  end

  # math.sqrt(x)
  defp math_sqrt([x], state) when is_number(x) do
    {[:math.sqrt(x / 1)], state}
  end

  defp math_sqrt([x | _], _state) do
    raise ArgumentError,
      function_name: "math.sqrt",
      arg_num: 1,
      expected: "number",
      got: Util.typeof(x)
  end

  defp math_sqrt([], _state) do
    raise ArgumentError.value_expected("math.sqrt", 1)
  end

  # math.tan(x)
  defp math_tan([x], state) when is_number(x) do
    {[:math.tan(x / 1)], state}
  end

  defp math_tan([x | _], _state) do
    raise ArgumentError,
      function_name: "math.tan",
      arg_num: 1,
      expected: "number",
      got: Util.typeof(x)
  end

  defp math_tan([], _state) do
    raise ArgumentError.value_expected("math.tan", 1)
  end

  # math.tointeger(x)
  defp math_tointeger([x], state) when is_integer(x) do
    {[x], state}
  end

  defp math_tointeger([x], state) when is_float(x) do
    if Float.floor(x) == x do
      {[trunc(x)], state}
    else
      {[nil], state}
    end
  end

  defp math_tointeger([_x], state) do
    {[nil], state}
  end

  defp math_tointeger([], _state) do
    raise ArgumentError.value_expected("math.tointeger", 1)
  end

  # math.type(x)
  defp math_type([x], state) when is_integer(x) do
    {["integer"], state}
  end

  defp math_type([x], state) when is_float(x) do
    {["float"], state}
  end

  defp math_type([_x], state) do
    {[nil], state}
  end

  defp math_type([], _state) do
    raise ArgumentError.value_expected("math.type", 1)
  end
end

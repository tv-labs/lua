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
  - `math.fmod(x, y)` - Returns the remainder of x/y rounded toward zero
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

  import Bitwise

  alias Lua.VM.ArgumentError
  alias Lua.VM.Numeric
  alias Lua.VM.State
  alias Lua.VM.Stdlib.Util
  alias Lua.VM.Value

  @max_int 9_223_372_036_854_775_807

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
      "deg" => {:native_func, &math_deg/2},
      "exp" => {:native_func, &math_exp/2},
      "floor" => {:native_func, &math_floor/2},
      "fmod" => {:native_func, &math_fmod/2},
      "log" => {:native_func, &math_log/2},
      "max" => {:native_func, &math_max/2},
      "min" => {:native_func, &math_min/2},
      "modf" => {:native_func, &math_modf/2},
      "pi" => :math.pi(),
      "rad" => {:native_func, &math_rad/2},
      "random" => {:native_func, &math_random/2},
      "randomseed" => {:native_func, &math_randomseed/2},
      "sin" => {:native_func, &math_sin/2},
      "sqrt" => {:native_func, &math_sqrt/2},
      "tan" => {:native_func, &math_tan/2},
      "tointeger" => {:native_func, &math_tointeger/2},
      "type" => {:native_func, &math_type/2},
      "ult" => {:native_func, &math_ult/2},
      "huge" => 1.0e308,
      "maxinteger" => 9_223_372_036_854_775_807,
      "mininteger" => -9_223_372_036_854_775_808
    }

    {tref, state} = State.alloc_table(state, math_table)
    State.set_global(state, "math", tref)
  end

  # math.abs(x). Integer arithmetic wraps modulo 2^64 (Lua 5.3 §3.4.2), so
  # `math.abs(math.mininteger)` is `math.mininteger` itself rather than a value
  # that escapes the signed 64-bit range.
  defp math_abs([x], state) when is_integer(x) do
    {[Numeric.to_signed_int64(abs(x))], state}
  end

  defp math_abs([x], state) when is_float(x) do
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

  # math.ceil(x). An integer argument is already integral and is returned
  # unchanged; routing it through a float would lose precision near the 64-bit
  # limits (e.g. `maxint` rounds up to 2^63 as a float).
  defp math_ceil([x], state) when is_integer(x) do
    {[x], state}
  end

  defp math_ceil([x], state) when is_float(x) do
    {[integral_float_result(Float.ceil(x))], state}
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

  # math.deg(x) — radians to degrees
  defp math_deg([x], state) when is_number(x) do
    {[x / 1 * (180.0 / :math.pi())], state}
  end

  defp math_deg([x | _], _state) do
    raise ArgumentError,
      function_name: "math.deg",
      arg_num: 1,
      expected: "number",
      got: Util.typeof(x)
  end

  defp math_deg([], _state) do
    raise ArgumentError.value_expected("math.deg", 1)
  end

  # math.rad(x) — degrees to radians
  defp math_rad([x], state) when is_number(x) do
    {[x / 1 * (:math.pi() / 180.0)], state}
  end

  defp math_rad([x | _], _state) do
    raise ArgumentError,
      function_name: "math.rad",
      arg_num: 1,
      expected: "number",
      got: Util.typeof(x)
  end

  defp math_rad([], _state) do
    raise ArgumentError.value_expected("math.rad", 1)
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

  # math.floor(x). An integer argument is already integral and is returned
  # unchanged; routing it through a float would lose precision near the 64-bit
  # limits (e.g. `maxint` rounds up to 2^63 as a float).
  defp math_floor([x], state) when is_integer(x) do
    {[x], state}
  end

  defp math_floor([x], state) when is_float(x) do
    {[integral_float_result(Float.floor(x))], state}
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

  # Lua 5.3 §6.7: `math.floor`/`math.ceil` return an integer when the integral
  # result fits the signed 64-bit range, otherwise the (already integral) float.
  defp integral_float_result(f) do
    truncated = trunc(f)
    if Numeric.signed?(truncated), do: truncated, else: f
  end

  # math.fmod(x, y)
  #
  # Returns the remainder of the division of x by y that rounds the quotient
  # toward zero (truncated division). Per Lua 5.3 §6.7:
  #
  #   * If both x and y are integers, the result is an integer.
  #   * Otherwise the result is a float computed via C's fmod (matching
  #     `:math.fmod/2`).
  #   * For two integers, y == 0 raises "bad argument #2 ... (zero)".
  #   * The integer case y == -1 short-circuits to 0 to avoid overflow on
  #     `mininteger / -1` (matching the C implementation in lmathlib.c).
  #
  # Note: Lua 5.3 defines `math.fmod(x, 0.0)` as NaN for floats. The BEAM has
  # no NaN value, so we raise instead — consistent with the rest of this VM,
  # which raises on `0.0 / 0.0` and similar (see safe_divide/2 in
  # Lua.VM.Executor).
  defp math_fmod([x, y], _state) when is_integer(x) and is_integer(y) and y == 0 do
    raise ArgumentError,
      function_name: "math.fmod",
      arg_num: 2,
      details: "zero"
  end

  defp math_fmod([x, y], state) when is_integer(x) and is_integer(y) and y == -1 do
    # Avoid overflow trap on mininteger / -1; remainder is always 0.
    {[0], state}
  end

  defp math_fmod([x, y], state) when is_integer(x) and is_integer(y) do
    {[Kernel.rem(x, y)], state}
  end

  defp math_fmod([x, y], _state) when is_number(x) and is_number(y) and y == 0 do
    raise ArgumentError,
      function_name: "math.fmod",
      arg_num: 2,
      details: "zero"
  end

  defp math_fmod([x, y], state) when is_number(x) and is_number(y) do
    {[:math.fmod(x / 1, y / 1)], state}
  end

  defp math_fmod([x, y | _], _state) when is_number(x) do
    raise ArgumentError,
      function_name: "math.fmod",
      arg_num: 2,
      expected: "number",
      got: Util.typeof(y)
  end

  defp math_fmod([x], _state) when is_number(x) do
    raise ArgumentError.value_expected("math.fmod", 2)
  end

  defp math_fmod([x | _], _state) do
    raise ArgumentError,
      function_name: "math.fmod",
      arg_num: 1,
      expected: "number",
      got: Util.typeof(x)
  end

  defp math_fmod([], _state) do
    raise ArgumentError.value_expected("math.fmod", 1)
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

  # Lua 5.3 §6.7: the interval `[m, n]` is too large when its span `n - m`
  # exceeds the signed 64-bit range (e.g. `math.random(minint, 0)`). The span
  # is computed in unbounded integer arithmetic before the range check so the
  # overflow is detected rather than silently wrapping.
  defp math_random([m, n], _state) when is_integer(m) and is_integer(n) and m <= n and n - m > @max_int do
    raise ArgumentError,
      function_name: "math.random",
      details: "interval too large"
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

  # math.tointeger(x). Returns x as an integer when it has an exact integer
  # value within the signed 64-bit range, otherwise nil. Strings are coerced
  # via the standard numeric-string rules (Lua 5.3 `lua_tointegerx`).
  defp math_tointeger([x], state) when is_integer(x) do
    {[x], state}
  end

  defp math_tointeger([x], state) when is_float(x) do
    {[float_to_integer_or_nil(x)], state}
  end

  defp math_tointeger([x], state) when is_binary(x) do
    case Value.parse_number(x) do
      n when is_integer(n) -> {[n], state}
      n when is_float(n) -> {[float_to_integer_or_nil(n)], state}
      _ -> {[nil], state}
    end
  end

  defp math_tointeger([_x], state) do
    {[nil], state}
  end

  defp math_tointeger([], _state) do
    raise ArgumentError.value_expected("math.tointeger", 1)
  end

  # A float converts to an integer only when it is integral and fits the signed
  # 64-bit range (the `1.0e308` `math.huge` stand-in does not).
  defp float_to_integer_or_nil(f) do
    if Float.floor(f) == f do
      truncated = trunc(f)
      if Numeric.signed?(truncated), do: truncated
    end
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

  # math.modf(x) — returns the integer and fractional parts of x.
  # Per Lua 5.3 §6.7: integer input returns itself plus 0.0 (float);
  # float input returns floor/ceil-toward-zero as a float plus the
  # fractional remainder.
  defp math_modf([:nan | _], state), do: {[:nan, :nan], state}

  defp math_modf([x | _], state) when is_integer(x) do
    {[x, 0.0], state}
  end

  defp math_modf([x | _], state) when is_float(x) do
    cond do
      x == 0.0 ->
        {[x, x], state}

      x > 0.0 ->
        i = Float.floor(x)
        {[i, x - i], state}

      true ->
        i = Float.ceil(x)
        {[i, x - i], state}
    end
  end

  defp math_modf([x | _], _state) do
    raise ArgumentError,
      function_name: "math.modf",
      arg_num: 1,
      expected: "number",
      got: Util.typeof(x)
  end

  defp math_modf([], _state) do
    raise ArgumentError.value_expected("math.modf", 1)
  end

  # math.ult(a, b) — unsigned 64-bit comparison of two integers.
  defp math_ult([a, b | _], state) when is_integer(a) and is_integer(b) do
    mask = 0xFFFFFFFFFFFFFFFF
    ua = a &&& mask
    ub = b &&& mask
    {[ua < ub], state}
  end

  defp math_ult([a, _ | _], _state) when not is_integer(a) do
    raise ArgumentError,
      function_name: "math.ult",
      arg_num: 1,
      expected: "integer",
      got: Util.typeof(a)
  end

  defp math_ult([_, b | _], _state) do
    raise ArgumentError,
      function_name: "math.ult",
      arg_num: 2,
      expected: "integer",
      got: Util.typeof(b)
  end

  defp math_ult(_args, _state) do
    raise ArgumentError.value_expected("math.ult", 1)
  end
end

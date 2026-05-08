defmodule Lua.VM.FloatDivZeroTest do
  @moduledoc """
  Pins the float-division-by-zero semantics required by Lua 5.3 §3.4.1.

  `/` is always float division and never raises. Zero divisors produce
  ±inf or NaN. The BEAM has no IEEE float infinity or NaN, so we use
  finite stand-ins consistent with `math.huge = 1.0e308`:

    * `1/0`  → `+1.0e308`
    * `-1/0` → `-1.0e308`
    * `0/0`  → `:nan` sentinel atom, which compares unequal to itself

  Only `//` and `%` raise on integer-zero divisors (covered elsewhere);
  this module locks down the `/` contract.
  """

  use ExUnit.Case, async: true

  defp run!(code) do
    {results, _state} = Lua.eval!(Lua.new(), code)
    results
  end

  describe "positive infinity" do
    test "1/0 equals math.huge" do
      assert run!("return 1/0 == math.huge") == [true]
    end

    test "1/0 is positive" do
      assert run!("return 1/0 > 0") == [true]
    end

    test "any positive numerator over zero is +inf" do
      assert run!("return 42/0 == math.huge") == [true]
    end

    test "math.huge + 1 == math.huge survives" do
      # Float precision swallows the +1 at this magnitude; assert it does.
      assert run!("return math.huge + 1 == math.huge") == [true]
    end
  end

  describe "negative infinity" do
    test "-1/0 equals -math.huge" do
      assert run!("return -1/0 == -math.huge") == [true]
    end

    test "-1/0 is negative" do
      assert run!("return -1/0 < 0") == [true]
    end

    test "any negative numerator over zero is -inf" do
      assert run!("return -42/0 == -math.huge") == [true]
    end
  end

  describe "NaN (0/0)" do
    test "0/0 ~= 0/0 — the canonical NaN inequality" do
      assert run!("return 0/0 ~= 0/0") == [true]
    end

    test "0/0 == 0/0 is false" do
      assert run!("return 0/0 == 0/0") == [false]
    end

    test "NaN compared to a number is unequal" do
      assert run!("return 0/0 == 1") == [false]
    end
  end

  describe "non-zero divisors still divide normally" do
    test "ordinary float division is unaffected" do
      assert run!("return 6/2") == [3.0]
    end

    test "negative-result division is unaffected" do
      assert run!("return -6/2") == [-3.0]
    end
  end

  describe "floor div and modulo with integer-zero divisor still raise" do
    test "1 // 0 raises" do
      assert_raise Lua.RuntimeException, ~r/divide by zero/, fn ->
        Lua.eval!(Lua.new(), "return 1 // 0")
      end
    end

    test "1 % 0 raises" do
      assert_raise Lua.RuntimeException, ~r/modulo by zero/, fn ->
        Lua.eval!(Lua.new(), "return 1 % 0")
      end
    end
  end

  describe "floor div with float-zero divisor (Lua 5.3 §3.4.1)" do
    test "1.0 // 0.0 equals math.huge" do
      assert run!("return 1.0 // 0.0 == math.huge") == [true]
    end

    test "-1.0 // 0.0 equals -math.huge" do
      assert run!("return -1.0 // 0.0 == -math.huge") == [true]
    end

    test "any positive float over 0.0 is +inf" do
      assert run!("return 42.5 // 0.0 == math.huge") == [true]
    end

    test "any negative float over 0.0 is -inf" do
      assert run!("return -42.5 // 0.0 == -math.huge") == [true]
    end

    test "0.0 // 0.0 is NaN — unequal to itself" do
      assert run!("return 0.0 // 0.0 ~= 0.0 // 0.0") == [true]
    end

    test "0.0 // 0.0 == 0.0 // 0.0 is false" do
      assert run!("return 0.0 // 0.0 == 0.0 // 0.0") == [false]
    end
  end

  describe "modulo with float-zero divisor (Lua 5.3 §3.4.1)" do
    test "1.0 % 0.0 is NaN — unequal to itself" do
      assert run!("return 1.0 % 0.0 ~= 1.0 % 0.0") == [true]
    end

    test "-1.0 % 0.0 is NaN" do
      assert run!("return -1.0 % 0.0 ~= -1.0 % 0.0") == [true]
    end

    test "0.0 % 0.0 is NaN" do
      assert run!("return 0.0 % 0.0 ~= 0.0 % 0.0") == [true]
    end

    test "NaN result is unequal to a number" do
      assert run!("return 1.0 % 0.0 == 1") == [false]
    end
  end

  describe "mixed integer/float zero divisors" do
    test "1 // 0.0 follows the float path and returns +inf" do
      assert run!("return 1 // 0.0 == math.huge") == [true]
    end

    test "-1 // 0.0 follows the float path and returns -inf" do
      assert run!("return -1 // 0.0 == -math.huge") == [true]
    end

    test "0 // 0.0 follows the float path and returns NaN" do
      assert run!("return 0 // 0.0 ~= 0 // 0.0") == [true]
    end

    test "1.0 // 0 still raises — integer divisor" do
      assert_raise Lua.RuntimeException, ~r/divide by zero/, fn ->
        Lua.eval!(Lua.new(), "return 1.0 // 0")
      end
    end

    test "1 % 0.0 follows the float path and returns NaN" do
      assert run!("return 1 % 0.0 ~= 1 % 0.0") == [true]
    end

    test "1.0 % 0 still raises — integer divisor" do
      assert_raise Lua.RuntimeException, ~r/modulo by zero/, fn ->
        Lua.eval!(Lua.new(), "return 1.0 % 0")
      end
    end
  end
end

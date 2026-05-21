defmodule Lua.VM.Numeric do
  @moduledoc """
  Numeric helpers implementing Lua 5.3 integer semantics.

  Lua 5.3 specifies that integer arithmetic and bitwise operations operate
  on signed 64-bit values that wrap modulo 2^64 on overflow. This is a
  divergence from Erlang's arbitrary-precision integers, which is why this
  module exists.

  The reference: Lua 5.3 §3.4.1 "Arithmetic Operators":

  > In case of overflows in integer arithmetic, all operations wrap around,
  > according to the usual rules of two-complement arithmetic.

  ## Lua vs. Luerl

  This module also marks a deliberate divergence from Luerl, which inherits
  Erlang's bignum behavior. Code written against Lua 5.3 (textbooks, the
  official test suite, copy-paste from elsewhere) expects wrapping; Luerl
  does not provide it. This library does, on the new VM.

  ## Bounds

    * `max_int/0` — `9_223_372_036_854_775_807`  (`2^63 - 1`)
    * `min_int/0` — `-9_223_372_036_854_775_808` (`-2^63`)

  ## Functions

    * `to_signed_int64/1` — wrap any integer into the signed 64-bit range.
    * `signed?/1` — predicate, true when an integer is already in range.
  """

  import Bitwise

  @uint64_modulus 0x10000000000000000
  @uint64_mask 0xFFFFFFFFFFFFFFFF
  @sign_bit 0x8000000000000000

  @max_int 0x7FFFFFFFFFFFFFFF
  @min_int -0x8000000000000000

  @compile {:inline, signed?: 1, to_signed_int64: 1}

  @doc "Maximum signed 64-bit integer (`2^63 - 1`)."
  @spec max_int() :: integer()
  def max_int, do: @max_int

  @doc "Minimum signed 64-bit integer (`-2^63`)."
  @spec min_int() :: integer()
  def min_int, do: @min_int

  @doc """
  Wrap an integer to the signed 64-bit range.

  Floats are returned unchanged so this is safe to apply to results of mixed
  integer/float pipelines that have already been narrowed by the caller.

  ## Examples

      iex> Lua.VM.Numeric.to_signed_int64(0)
      0

      iex> Lua.VM.Numeric.to_signed_int64(Lua.VM.Numeric.max_int() + 1)
      -9_223_372_036_854_775_808

      iex> Lua.VM.Numeric.to_signed_int64(Lua.VM.Numeric.min_int() - 1)
      9_223_372_036_854_775_807

      iex> Lua.VM.Numeric.to_signed_int64(0xFFFFFFFFFFFFFFFF)
      -1
  """
  @spec to_signed_int64(integer()) :: integer()
  def to_signed_int64(n) when is_integer(n) and n >= @min_int and n <= @max_int do
    n
  end

  def to_signed_int64(n) when is_integer(n) do
    masked = band(n, @uint64_mask)
    if masked >= @sign_bit, do: masked - @uint64_modulus, else: masked
  end

  @doc """
  Returns `true` when `n` is already in the signed 64-bit range.

  Cheap predicate for the fast path: integers produced by Lua-level
  operations on already-narrow integers are usually still narrow, so we can
  avoid the masking step in those cases when we want.
  """
  @spec signed?(integer()) :: boolean()
  def signed?(n) when is_integer(n), do: n >= @min_int and n <= @max_int
end

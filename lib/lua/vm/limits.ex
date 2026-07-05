defmodule Lua.VM.Limits do
  @moduledoc """
  Practical resource ceilings for stdlib operations whose output size is a
  function of a numeric argument.

  These guard against denial-of-service via a single oversized allocation
  (e.g. `string.rep("x", 1e15)`, `table.unpack(t, 1, 1e12)`). Each call
  site computes the result size *before* allocating and asks here whether
  it is permitted, turning what would otherwise be an out-of-memory crash
  of the host into a catchable Lua error.

  PUC-Lua raises the same messages — "resulting string too large" on
  `size_t` overflow in `str_rep`, and "too many results to unpack" on the
  `INT_MAX` guard in `unpack`. The thresholds here sit far above any
  legitimate embedded use; they are the same guards at a practical bound
  rather than at the machine word size.

  This is the deterministic, OTP-independent layer: it never relies on the
  garbage collector or heap accounting to notice a bomb, because the bomb
  is refused before a byte is allocated.
  """

  alias Lua.VM.ArgumentError
  alias Lua.VM.RuntimeError

  # 256 MiB. A single string this large is already pathological for an
  # embedded interpreter; legitimate snippets never approach it.
  @max_string_bytes 256 * 1024 * 1024

  # 10 million elements. Bounds the result list of `table.unpack` and the
  # element reads of `table.concat`/`table.move` well under what would
  # exhaust memory, while staying generous for real data.
  @max_element_count 10_000_000

  @doc "The string-size ceiling, in bytes."
  @spec max_string_bytes() :: pos_integer()
  def max_string_bytes, do: @max_string_bytes

  @doc "The element-count ceiling for range-based table operations."
  @spec max_element_count() :: pos_integer()
  def max_element_count, do: @max_element_count

  @doc """
  Asserts that an as-yet-unallocated string of `bytes` bytes is within the
  given ceiling (a state's `max_string_bytes`, defaulting to the practical
  bound here). Raises a catchable "resulting string too large" runtime
  error otherwise.
  """
  # `max` may be `:infinity` (from `Lua.new(max_string_bytes: :infinity)`).
  # Erlang term ordering places every number below every atom, so an integer
  # `bytes <= :infinity` is always true and the check passes unconditionally —
  # no separate clause is needed.
  @spec check_string_size!(integer(), pos_integer() | :infinity) :: :ok
  def check_string_size!(bytes, max \\ @max_string_bytes)

  def check_string_size!(bytes, max) when is_integer(bytes) and bytes <= max, do: :ok

  def check_string_size!(_bytes, _max) do
    raise RuntimeError, value: "resulting string too large"
  end

  @doc """
  Asserts that a range-based table operation (`concat`, `move`) would not
  touch more than the element ceiling. Raises a catchable bad-argument
  error attributed to `function_name` otherwise.
  """
  @spec check_range_count!(integer(), String.t()) :: :ok
  def check_range_count!(count, _function_name) when is_integer(count) and count <= @max_element_count, do: :ok

  def check_range_count!(_count, function_name) do
    raise ArgumentError, function_name: function_name, details: "range too large"
  end
end

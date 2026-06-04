defmodule Lua.VM.StateTest do
  @moduledoc """
  Pins the authoritative `State.next_call_depth!/1` and, by extension, the
  shared semantics the inlined copies in `Lua.VM.Dispatcher` and
  `Lua.VM.Executor` must match: the depth bumps by one under the limit,
  `:infinity` skips the comparison, and reaching `max_call_depth` raises a
  catchable Lua `"stack overflow"`.
  """
  use ExUnit.Case, async: true

  alias Lua.VM.RuntimeError
  alias Lua.VM.State

  describe "next_call_depth!/1" do
    test "returns the incremented depth when under a finite limit" do
      state = %State{call_depth: 3, max_call_depth: 10}

      assert State.next_call_depth!(state) == 4
    end

    test "returns the incremented depth when max_call_depth is :infinity" do
      state = %State{call_depth: 41, max_call_depth: :infinity}

      assert State.next_call_depth!(state) == 42
    end

    test "skips the limit comparison for :infinity at depth 0 (the default)" do
      assert State.next_call_depth!(%State{}) == 1
    end

    test "raises a catchable stack overflow once the depth reaches the limit" do
      frames = [%{source: "chunk", line: 1, name: "f", namewhat: ""}]
      state = %State{call_depth: 10, max_call_depth: 10, call_stack: frames}

      assert_raise RuntimeError, ~r/stack overflow/, fn ->
        State.next_call_depth!(state)
      end
    end

    test "the raised error carries the stack-overflow value and the call stack" do
      frames = [%{source: "chunk", line: 1, name: "f", namewhat: ""}]
      state = %State{call_depth: 5, max_call_depth: 5, call_stack: frames}

      error = catch_error(State.next_call_depth!(state))

      assert %RuntimeError{value: "stack overflow", call_stack: ^frames} = error
    end
  end
end

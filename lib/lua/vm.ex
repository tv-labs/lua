defmodule Lua.VM do
  @moduledoc """
  Public API for the Lua Virtual Machine.

  Executes compiled Lua prototypes.
  """

  alias Lua.Compiler.Prototype
  alias Lua.VM.Executor
  alias Lua.VM.State

  @doc """
  Executes a compiled prototype.

  Returns {:ok, results, state} on success.
  """
  @spec execute(Prototype.t(), State.t()) :: {:ok, list(), State.t()}
  def execute(%Prototype{} = proto, state \\ State.new()) do
    # Size the register file to the prototype's honest register peak, with no
    # slack buffer — same contract as every other call frame. `max_registers`
    # covers every statically-fixed destination (codegen's `instruction_peak/1`
    # backstop); runtime-dynamic writes (multi-return result distribution,
    # unbounded varargs) grow the tuple lazily via `ensure_regs_capacity/2`.
    registers = Tuple.duplicate(nil, max(proto.max_registers, proto.param_count))

    # Execute the prototype instructions
    {results, _final_regs, final_state} =
      Executor.execute(proto.instructions, registers, [], proto, state)

    {:ok, results, final_state}
  end
end

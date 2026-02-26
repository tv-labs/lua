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
    # Create register file sized to the prototype's needs.
    # The +16 buffer covers multi-return expansion slots that the codegen doesn't
    # always track in max_registers (call results can land beyond the stated max).
    registers = Tuple.duplicate(nil, proto.max_registers + 16)

    # Execute the prototype instructions
    {results, _final_regs, final_state} =
      Executor.execute(proto.instructions, registers, [], proto, state)

    {:ok, results, final_state}
  end
end

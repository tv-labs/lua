defmodule Lua.VM do
  @moduledoc """
  Public API for the Lua Virtual Machine.

  Executes compiled Lua prototypes.
  """

  alias Lua.Compiler.Prototype
  alias Lua.VM.{State, Executor}

  @doc """
  Executes a compiled prototype.

  Returns {:ok, results, state} on success.
  """
  @spec execute(Prototype.t(), State.t()) :: {:ok, list(), State.t()}
  def execute(%Prototype{} = proto, state \\ State.new()) do
    # Create register file - tuple of nils
    # For now, just allocate 256 registers (we'll optimize this later)
    registers = Tuple.duplicate(nil, 256)

    # Execute the prototype instructions
    {results, _final_regs, final_state} =
      Executor.execute(proto.instructions, registers, [], proto, state)

    {:ok, results, final_state}
  end
end

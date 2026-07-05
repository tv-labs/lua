defmodule Lua.VM do
  @moduledoc """
  Internal entry point for the Lua Virtual Machine — executes compiled
  prototypes.

  This module is not part of the public, stable API (it is filtered out of
  the published HexDocs) and is kept readable for source readers and IEx
  exploration only. Reach for `Lua.eval!/2` and friends instead; its shape
  may change between releases without notice.
  """

  alias Lua.Compiler.Prototype
  alias Lua.VM.Executor
  alias Lua.VM.State

  @doc """
  Executes a compiled prototype.

  Returns {:ok, results, state} on success.

  ## Options

    * `:reset_instructions` - (default `true`) reset the `:max_instructions` instruction
      tally to 0 before executing. This is internal require-reentrancy
      machinery, not user API. It is `true` at a genuine top-level evaluation
      (`Lua.eval`/`eval!`). Internal re-entries that run mid-evaluation —
      notably `require`, which loads and runs a module's chunk through this
      function — must pass `false` so the module body accumulates against the
      one per-evaluation budget instead of resetting it.
  """
  @spec execute(Prototype.t(), State.t(), keyword()) :: {:ok, list(), State.t()}
  def execute(%Prototype{} = proto, state \\ State.new(), opts \\ []) do
    # Size the register file to the prototype's honest register peak, with no
    # slack buffer — same contract as every other call frame. `max_registers`
    # covers every statically-fixed destination (codegen's `instruction_peak/1`
    # backstop); runtime-dynamic writes (multi-return result distribution,
    # unbounded varargs) grow the tuple lazily via `ensure_regs_capacity/2`.
    registers = Tuple.duplicate(nil, max(proto.max_registers, proto.param_count))

    # Reset the instruction-budget tally at the top-level evaluation
    # boundary so `:max_instructions` bounds ONE evaluation's total work rather
    # than accumulating over the whole %Lua{} lifetime. The terminals stamp
    # the per-eval tally back into `state.instruction_count`, so without this reset a
    # long-lived %Lua{} running many small evals would eventually trip the
    # budget even though no single eval came close. Nested Lua/compiled calls
    # within this evaluation thread the tally as a bare parameter and never
    # re-enter here — but `require` does re-enter (it runs a module's chunk
    # through this function), so it passes `reset_instructions: false` to keep the
    # module body counting against the same budget.
    state = if Keyword.get(opts, :reset_instructions, true), do: %{state | instruction_count: 0}, else: state

    # Execute the prototype instructions
    {results, _final_regs, final_state} =
      Executor.execute(proto.instructions, registers, [], proto, state)

    {:ok, results, final_state}
  end
end

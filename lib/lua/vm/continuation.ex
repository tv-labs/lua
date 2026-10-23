defmodule Lua.VM.Continuation do
  @moduledoc """
  Opaque resumable machine state for a suspended Lua evaluation.

  A continuation is a stack of machine layers, innermost first, captured when
  a `deflua` / Elixir callback suspends execution with `{:suspend, values}`.
  Each layer is a plain map holding one engine's loop state at the suspended
  call site:

    * `%{engine: :executor, ...}` — the interpreter's `do_execute/9` state
      (`rest`, `regs`, `upvalues`, `proto`, `cont`, `frames`, `line`,
      `instruction_count`, `base`, `result_count`, `open_upvalues`, and
      `pop_call_frame` when the layer was parked at an engine-boundary
      bridge).
    * `%{engine: :dispatcher, ...}` — the dispatcher's `dispatch/11` state
      (`code`, `pc`, `regs`, `upvalues`, `proto`, `cont`, `frames`, `cs`,
      `cd`, `ou`, `placement`, `instruction_count`).
    * `%{engine: :pending_call}` — a native suspended when called directly
      via `Lua.call_function/3` outside any Lua execution; resume returns
      the resume values as the call results.

  The heap flows through the run, not through the layers: resuming seeds the
  innermost layer from the host's `%Lua{}` state, and each layer's
  completion state feeds the next-outer layer (applying the boundary
  bookkeeping the parked bridge would have done on the normal return path).

  > #### Unstable internals {: .warning}
  > The layer shapes are VM internals and may change between releases. A
  > continuation is an immutable, in-memory term: it can be passed between
  > processes on one node and copied to branch, but it is not persistable
  > when a register holds a local fun.
  """

  alias Lua.VM.State

  defstruct [:layers]

  @type t :: %__MODULE__{layers: [map()]}

  @doc """
  Runs the continuation until it completes or suspends again.

  `values` are the encoded resume values: they become the suspended call's
  results in the innermost layer. Returns `{:ok, results, state}` when the
  outermost layer completes, or `{:suspended, values, layers, state}` when a
  layer suspends again (`layers` is the replacement layer stack, already
  re-composed with any remaining outer layers).
  """
  @spec run(t(), [term()], State.t()) ::
          {:ok, [term()], State.t()} | {:suspended, [term()], [map()], State.t()}
  def run(%__MODULE__{layers: [first | rest]}, values, state) do
    run_from(first, rest, values, seed_first(first, state))
  end

  defp run_from(layer, rest, values, state) do
    case run_layer(layer, values, state) do
      {:ok, results, state} ->
        case rest do
          [] ->
            {:ok, results, state}

          [outer | outer_rest] ->
            run_from(outer, outer_rest, results, transition(rest, state))
        end

      {:suspended, values, layers, state} ->
        {:suspended, values, layers ++ rest, state}
    end
  end

  defp run_layer(%{engine: :executor} = layer, values, state), do: Lua.VM.Executor.resume_layer(layer, values, state)

  defp run_layer(%{engine: :dispatcher} = layer, values, state), do: Lua.VM.Dispatcher.resume_layer(layer, values, state)

  # A native suspended when called directly through the programmatic
  # boundary (no Lua machine around it): the resume values are the results.
  defp run_layer(%{engine: :pending_call}, values, state), do: {:ok, values, state}

  # The innermost layer seeds the machine's budget tally and open upvalue
  # cells from its capture — the host's state may carry a tally from an
  # unrelated later evaluation. Outer layers are seeded by the inner layer's
  # completion state instead, which carries the fresh tally (and the
  # restored open cells) the normal return path would have produced.
  defp seed_first(%{engine: :executor, instruction_count: instruction_count, open_upvalues: open_upvalues}, state) do
    %{state | instruction_count: instruction_count, open_upvalues: open_upvalues}
  end

  defp seed_first(%{instruction_count: instruction_count}, state) do
    %{state | instruction_count: instruction_count}
  end

  # A degenerate `:pending_call` layer carries no machine state — the resume
  # values are the call results, nothing to seed.
  defp seed_first(_layer, state), do: state

  # An executor layer parked at the compiled-closure bridge expects the state
  # the bridge would have computed on the normal return path: the
  # dispatcher's terminal stamps the call frame it was entered with back
  # into the struct, and the branch pops it before continuing. Dispatcher
  # layers need no such adjustment — their bridges continue with the
  # loop-carried `cs`/`cd`/`ou` params, not the struct's fields.
  defp transition([%{engine: :executor, pop_call_frame: true} | _], state) do
    %{state | call_stack: tl(state.call_stack), call_depth: state.call_depth - 1}
  end

  defp transition(_rest, state), do: state
end

defmodule Lua.Compiler.GotoResolution do
  @moduledoc """
  Resolves `goto` / `::label::` ahead of interpreter execution.

  The list interpreter walks an instruction tree and, by the time it reaches
  a `:goto`, has already consumed the head of the current block — so it can
  neither scan backward nor reach an enclosing block at run time. This pass
  resolves every goto up front, rewriting `{:goto, name}` to `{:goto, id}`
  and recording in `proto.goto_targets` an entry
  `id => {depth, level, target_tail}`:

    * `depth` — the number of `cont` entries the interpreter drops to leave
      the blocks between the goto and its target. A `:test` branch pushes one
      `cont` entry, each loop body pushes two (a CPS marker plus a
      `:loop_exit`); `depth` is the sum across the boundaries crossed, so
      after dropping it the remaining `cont` is exactly what was active when
      the destination block was first entered.

    * `level` — the target label's scope register level (recorded by codegen
      on the `{:label, name, level}` instruction). The goto closes any open
      upvalue cell at or above this register, so locals in the blocks it
      leaves or re-enters get fresh cells (Lua 5.3 §3.3.4 block-exit).

    * `target_tail` — the instruction sublist immediately after the matching
      `{:label, name, level}` in its owning block.

  Label scope (Lua 5.3 §3.3.4): a goto targets a label in its own block or an
  enclosing one, never inside a nested block. `do` blocks are flattened by
  codegen, so a name can appear more than once in a single list; the nearest
  label after the goto (else the nearest before) is chosen, which matches the
  lexical intent of the forward `continue` / `break` idioms and the single
  backward-jump loop. Labels are unique per real scope, so within one genuine
  block there is never more than one candidate.

  Gotos never cross a function boundary, so each prototype is resolved
  independently against its own instruction tree.
  """

  alias Lua.Compiler.Prototype

  # `cont` entries pushed when the interpreter enters a nested block.
  @test_weight 1
  @loop_weight 2

  @doc """
  Resolve gotos in `proto` and every nested prototype, returning the proto
  with rewritten `instructions` and a populated `goto_targets` map.
  """
  @spec resolve(Prototype.t()) :: Prototype.t()
  def resolve(%Prototype{} = proto) do
    proto = %{proto | prototypes: Enum.map(proto.prototypes, &resolve/1)}

    {tree, _next, id_to_name} = assign_ids(proto.instructions, 0, %{})
    targets = collect_targets(tree, [], %{}, id_to_name)

    %{proto | instructions: tree, goto_targets: targets}
  end

  # ── Pass 1: assign each goto a unique id ────────────────────────────────
  #
  # Rewriting `{:goto, name}` to `{:goto, id}` keeps the instruction a single
  # element, so block structure and label positions are unchanged — pass 2
  # can compute target tails directly against this tree.

  defp assign_ids(list, counter, names) when is_list(list) do
    {acc, counter, names} =
      Enum.reduce(list, {[], counter, names}, fn instr, {acc, c, n} ->
        {instr, c, n} = assign_instr(instr, c, n)
        {[instr | acc], c, n}
      end)

    {Enum.reverse(acc), counter, names}
  end

  defp assign_instr({:goto, name}, c, names), do: {{:goto, c}, c + 1, Map.put(names, c, name)}

  defp assign_instr({:test, reg, then_body, else_body}, c, names) do
    {then_body, c, names} = assign_ids(then_body, c, names)
    {else_body, c, names} = assign_ids(else_body, c, names)
    {{:test, reg, then_body, else_body}, c, names}
  end

  defp assign_instr({:numeric_for, base, loop_var, body}, c, names) do
    {body, c, names} = assign_ids(body, c, names)
    {{:numeric_for, base, loop_var, body}, c, names}
  end

  defp assign_instr({:while_loop, cond_body, test_reg, body}, c, names) do
    {body, c, names} = assign_ids(body, c, names)
    {{:while_loop, cond_body, test_reg, body}, c, names}
  end

  defp assign_instr({:repeat_loop, body, cond_body, test_reg}, c, names) do
    {body, c, names} = assign_ids(body, c, names)
    {{:repeat_loop, body, cond_body, test_reg}, c, names}
  end

  defp assign_instr({:generic_for, base, var_regs, body}, c, names) do
    {body, c, names} = assign_ids(body, c, names)
    {{:generic_for, base, var_regs, body}, c, names}
  end

  defp assign_instr(other, c, names), do: {other, c, names}

  # ── Pass 2: resolve each goto to {depth, target_tail} ───────────────────
  #
  # `ancestors` is a stack of `{parent_block, child_index, weight}` from the
  # innermost enclosing block outward, where `weight` is the number of `cont`
  # entries crossing from the inner block into `parent_block` costs.

  defp collect_targets(block, ancestors, targets, names) do
    block
    |> Enum.with_index()
    |> Enum.reduce(targets, fn {instr, idx}, targets ->
      resolve_instr(instr, idx, block, ancestors, targets, names)
    end)
  end

  defp resolve_instr({:goto, id}, idx, block, ancestors, targets, names) do
    name = Map.fetch!(names, id)

    case resolve_target(name, block, idx, ancestors) do
      {:ok, depth, level, tail} -> Map.put(targets, id, {depth, level, tail})
      # Unresolved (illegal goto the parser should have rejected): leave it
      # out so the interpreter raises "goto target not found" at run time.
      :error -> targets
    end
  end

  defp resolve_instr({:test, _reg, then_body, else_body}, idx, block, ancestors, targets, names) do
    ancestors = [{block, idx, @test_weight} | ancestors]

    targets = collect_targets(then_body, ancestors, targets, names)
    collect_targets(else_body, ancestors, targets, names)
  end

  defp resolve_instr({:numeric_for, _base, _loop_var, body}, idx, block, ancestors, targets, names) do
    collect_targets(body, [{block, idx, @loop_weight} | ancestors], targets, names)
  end

  defp resolve_instr({:while_loop, _cond_body, _test_reg, body}, idx, block, ancestors, targets, names) do
    collect_targets(body, [{block, idx, @loop_weight} | ancestors], targets, names)
  end

  defp resolve_instr({:repeat_loop, body, _cond_body, _test_reg}, idx, block, ancestors, targets, names) do
    collect_targets(body, [{block, idx, @loop_weight} | ancestors], targets, names)
  end

  defp resolve_instr({:generic_for, _base, _var_regs, body}, idx, block, ancestors, targets, names) do
    collect_targets(body, [{block, idx, @loop_weight} | ancestors], targets, names)
  end

  defp resolve_instr(_other, _idx, _block, _ancestors, targets, _names), do: targets

  # Search the current block, then each enclosing block, summing `cont`
  # weights along the way. Returns `{:ok, depth, level, target_tail}` where
  # `level` is the target label's scope register level (the goto's close
  # threshold).
  defp resolve_target(name, block, idx, ancestors) do
    case find_label_pos(block, name, idx) do
      {:ok, pos, level} -> {:ok, 0, level, Enum.drop(block, pos + 1)}
      :error -> resolve_in_ancestors(name, ancestors, 0)
    end
  end

  defp resolve_in_ancestors(_name, [], _depth), do: :error

  defp resolve_in_ancestors(name, [{parent_block, child_idx, weight} | rest], depth) do
    depth = depth + weight

    case find_label_pos(parent_block, name, child_idx) do
      {:ok, pos, level} -> {:ok, depth, level, Enum.drop(parent_block, pos + 1)}
      :error -> resolve_in_ancestors(name, rest, depth)
    end
  end

  # The label nearest after `from`, else the nearest before it. Within a
  # genuine Lua scope a name is unique, so the only multi-candidate case is
  # flattened `do` blocks, where forward-then-backward matches lexical intent.
  # Returns the chosen position and its codegen-recorded scope `level`.
  defp find_label_pos(block, name, from) do
    labels =
      block
      |> Enum.with_index()
      |> Enum.flat_map(fn
        {{:label, ^name, level}, i} -> [{i, level}]
        _ -> []
      end)

    after_label = labels |> Enum.filter(fn {i, _} -> i > from end) |> Enum.min_by(&elem(&1, 0), fn -> nil end)
    before_label = labels |> Enum.filter(fn {i, _} -> i < from end) |> Enum.max_by(&elem(&1, 0), fn -> nil end)

    case after_label || before_label do
      {pos, level} -> {:ok, pos, level}
      nil -> :error
    end
  end
end

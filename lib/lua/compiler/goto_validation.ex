defmodule Lua.Compiler.GotoValidation do
  @moduledoc """
  Static legality check for `goto` / `::label::` (Lua 5.3 §3.3.4).

  PUC-Lua rejects illegal gotos at compile time; this pass mirrors that so
  both VM engines refuse the same programs before either goto resolver runs.
  It walks the AST function by function (gotos never cross a function
  boundary) and reports the first violation as `{:error, message}`:

    * a label defined twice in the same block — `label '%s' already defined`;
    * a `goto` whose label is not visible from its block or any enclosing one
      (undefined, or hidden inside a nested/sibling block) —
      `no visible label '%s' for goto`;
    * a forward `goto` that jumps into the scope of a local — i.e. it crosses
      a local declaration that is still in scope at the target label, and the
      label is not at the end of its block — `jumps into the scope of local
      '%s'`.

  Active-local counts (`nact`) are tracked function-wide, like PUC's
  `nactvar`. When a goto leaves a block unresolved its count is clamped to the
  block's entry level (mirroring PUC's `leaveblock`), so the local-scope check
  stays sound across block boundaries.
  """

  alias Lua.AST.Block
  alias Lua.AST.Chunk
  alias Lua.AST.Expr
  alias Lua.AST.Statement

  @doc """
  Validate every function in `chunk`. Returns `:ok` or `{:error, message}`.
  """
  @spec validate(Chunk.t()) :: :ok | {:error, String.t()}
  def validate(%Chunk{block: block}) do
    validate_function(block)
  end

  # ── Per-function validation ──────────────────────────────────────────────
  #
  # A function body is the root block. We resolve all of its labels and
  # gotos; any goto that escapes the root block unresolved targets a
  # non-visible label.

  defp validate_function(%Block{} = block) do
    case check_block(block, new_ctx()) do
      {:ok, %{pending: [{name, _nact, _depth} | _]}} ->
        {:error, "no visible label '#{name}' for goto"}

      {:ok, _ctx} ->
        :ok

      {:error, _} = err ->
        err
    end
  end

  defp new_ctx, do: %{nact: 0, pending: [], labels: %{}, locals: [], depth: 0, block_kind: :block}

  # ── Block walk ───────────────────────────────────────────────────────────
  #
  # `ctx.nact` is the function-wide active-local count on entry. `ctx.labels`
  # accumulates every label still in scope (its own block plus enclosing
  # ones), keyed by name to `{nact, end?, depth}`; enclosing labels stay
  # visible so a goto can jump backward out to them. `ctx.pending` is the list
  # of forward gotos not yet matched.
  #
  # Returns `{:ok, ctx}` with `nact`, `locals`, `depth`, and `labels` restored
  # to the block's entry state (inner locals and labels leave scope), and
  # `pending` carrying every goto still unresolved — to be matched by an
  # enclosing block's later labels.

  defp check_block(block, ctx), do: check_block(block, ctx, :block)

  defp check_block(%Block{stmts: stmts}, ctx, kind) do
    entry_nact = ctx.nact
    entry_locals = ctx.locals
    entry_labels = ctx.labels
    entry_depth = ctx.depth
    entry_kind = ctx.block_kind

    with {:ok, ctx} <- walk(stmts, %{ctx | depth: entry_depth + 1, block_kind: kind}) do
      # Gotos still pending when this block ends leave it: their locals go out
      # of scope, so clamp each one's active-local count down to this block's
      # entry level (PUC's `leaveblock` does the same). Without the clamp a
      # later enclosing label would compare against an inflated count and miss
      # a jump into the scope of an enclosing local.
      pending =
        Enum.map(ctx.pending, fn {name, goto_nact, goto_depth} ->
          {name, min(goto_nact, entry_nact), goto_depth}
        end)

      ctx = %{
        ctx
        | nact: entry_nact,
          locals: entry_locals,
          labels: entry_labels,
          depth: entry_depth,
          block_kind: entry_kind,
          pending: pending
      }

      {:ok, ctx}
    end
  end

  # Whether a label sits at the end of its block (only labels follow). Used for
  # the "jump over a local to the end of the block is legal" exception. A
  # `repeat` body's labels never count as end-of-block: the `until` condition
  # extends the body's local scope, so the locals are still live at the label.
  defp at_block_end?(_stmts_after, :repeat), do: false
  defp at_block_end?(stmts_after, _kind), do: Enum.all?(stmts_after, &match?(%Statement.Label{}, &1))

  defp walk([], ctx), do: {:ok, ctx}

  defp walk([stmt | rest], ctx) do
    with {:ok, ctx} <- check_statement(stmt, rest, ctx) do
      walk(rest, ctx)
    end
  end

  # ── Statements that affect goto legality ─────────────────────────────────

  defp check_statement(%Statement.Label{name: name}, rest, ctx) do
    case Map.get(ctx.labels, name) do
      {_nact, _end?, depth} when depth == ctx.depth ->
        {:error, "label '#{name}' already defined"}

      _ ->
        label_end? = at_block_end?(rest, ctx.block_kind)
        ctx = %{ctx | labels: Map.put(ctx.labels, name, {ctx.nact, label_end?, ctx.depth})}
        resolve_pending(name, ctx.nact, ctx.depth, label_end?, ctx)
    end
  end

  defp check_statement(%Statement.Goto{label: name}, _rest, ctx) do
    case Map.get(ctx.labels, name) do
      # Backward jump to a label already in scope (this block or an enclosing
      # one). A backward jump lands where its locals were already in scope, so
      # it can never jump into a local's scope — accept unconditionally.
      {_label_nact, _end?, _depth} ->
        {:ok, ctx}

      nil ->
        # Forward (or enclosing-but-later) reference: defer. The goto's active
        # local count and block depth are captured so the local-scope and
        # visibility checks can run when the label appears.
        {:ok, %{ctx | pending: [{name, ctx.nact, ctx.depth} | ctx.pending]}}
    end
  end

  defp check_statement(%Statement.Local{names: names}, _rest, ctx) do
    {:ok, %{ctx | nact: ctx.nact + length(names), locals: ctx.locals ++ names}}
  end

  defp check_statement(%Statement.LocalFunc{name: name} = lf, _rest, ctx) do
    with {:ok, _} <- as_ok(validate_function(lf.body)) do
      {:ok, %{ctx | nact: ctx.nact + 1, locals: ctx.locals ++ [name]}}
    end
  end

  defp check_statement(%Statement.Do{body: body}, _rest, ctx) do
    check_block(body, ctx)
  end

  defp check_statement(%Statement.If{then_block: then_b, elseifs: elseifs, else_block: else_b}, _rest, ctx) do
    blocks = [then_b | Enum.map(elseifs, fn {_cond, blk} -> blk end)] ++ List.wrap(else_b)
    reduce_blocks(blocks, ctx)
  end

  defp check_statement(%Statement.While{body: body}, _rest, ctx), do: check_block(body, ctx)

  defp check_statement(%Statement.Repeat{body: body}, _rest, ctx), do: check_block(body, ctx, :repeat)

  defp check_statement(%Statement.ForNum{var: var, body: body}, _rest, ctx) do
    check_loop_block(body, [var], ctx)
  end

  defp check_statement(%Statement.ForIn{vars: vars, body: body}, _rest, ctx) do
    check_loop_block(body, vars, ctx)
  end

  # Function declarations open their own goto scope.
  defp check_statement(%Statement.FuncDecl{body: body}, _rest, ctx) do
    with {:ok, _} <- as_ok(validate_function(body)) do
      {:ok, ctx}
    end
  end

  defp check_statement(%Expr.Function{body: body}, _rest, ctx) do
    with {:ok, _} <- as_ok(validate_function(body)) do
      {:ok, ctx}
    end
  end

  # Everything else is goto-irrelevant, but it may contain a function literal
  # in an expression position — those are validated when scope resolution
  # reaches them, so nothing more is needed here.
  defp check_statement(_stmt, _rest, ctx), do: {:ok, ctx}

  # ── Helpers ──────────────────────────────────────────────────────────────

  # The loop variable(s) are in scope for the body. Bump `nact` accordingly
  # for the body walk, then restore.
  defp check_loop_block(body, vars, ctx) do
    inner = %{ctx | nact: ctx.nact + length(vars), locals: ctx.locals ++ vars}

    with {:ok, inner} <- check_block(body, inner) do
      {:ok, %{inner | nact: ctx.nact, locals: ctx.locals}}
    end
  end

  defp reduce_blocks(blocks, ctx) do
    Enum.reduce_while(blocks, {:ok, ctx}, fn block, {:ok, ctx} ->
      case check_block(block, ctx) do
        {:ok, ctx} -> {:cont, {:ok, ctx}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  # When a label at `label_depth` appears, resolve the pending forward gotos it
  # can satisfy. A label can only be the target of a goto in its own block or a
  # nested one (`goto_depth >= label_depth`); a goto in an enclosing block
  # (`goto_depth < label_depth`) cannot jump into this nested block, so it is
  # left pending to bubble outward. A resolved goto is illegal if it jumps into
  # the scope of a local: the label sees more active locals than the goto did,
  # and the label is not at the end of its block.
  defp resolve_pending(name, label_nact, label_depth, label_end?, ctx) do
    {matched, rest} =
      Enum.split_with(ctx.pending, fn {n, _nact, goto_depth} ->
        n == name and goto_depth >= label_depth
      end)

    case Enum.find(matched, fn {_n, goto_nact, _depth} -> label_nact > goto_nact and not label_end? end) do
      {_n, goto_nact, _depth} ->
        # The crossed local is the first one in scope at the label that was not
        # in scope at the goto — index `goto_nact` in the label's live locals.
        crossed = Enum.at(ctx.locals, goto_nact, "?")
        {:error, "jumps into the scope of local '#{crossed}'"}

      nil ->
        {:ok, %{ctx | pending: rest}}
    end
  end

  defp as_ok(:ok), do: {:ok, :ok}
  defp as_ok({:error, _} = err), do: err
end

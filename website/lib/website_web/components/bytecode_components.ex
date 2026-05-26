defmodule DemoWeb.BytecodeComponents do
  @moduledoc """
  Reusable HEEx components for rendering register-based bytecode
  disassembly. Used by the playground (`/playground`) and the tour
  (`/tour/:slug`) so the column layout, colour scheme, opcode tooltips,
  and meta-pill set stay in sync between the two surfaces.

  All tooltips are powered by the body-level Tippy.js delegator in
  `assets/js/app.js` — emit `data-tip`, `data-tip-html`, or
  `data-tip-op` attributes and the tooltip renders automatically.
  """
  use Phoenix.Component

  alias DemoWeb.Bytecode

  @doc """
  Renders the opcode-doc JSON blob the JS tooltip layer reads to
  build per-opcode cards. Drop one of these onto any page that uses
  `bytecode_panel/1` or `bytecode_table/1`.
  """
  def opcode_docs_script(assigns) do
    assigns =
      assign_new(assigns, :json, fn ->
        Jason.encode!(Bytecode.opcode_tooltip_map())
      end)

    ~H"""
    <script type="application/json" id="opcode-docs" phx-update="ignore">
      {Phoenix.HTML.raw(@json)}
    </script>
    <template id="args-glossary"><.args_glossary_tip /></template>
    """
  end

  defp args_glossary_tip(assigns) do
    ~H"""
    <div class="lua-tip">
      <div class="lua-tip-section">Reading the arguments</div>
      <dl class="lua-tip-defs">
        <dt><code>r0</code>, <code>r1</code>, …</dt>
        <dd>register slots — scratch space the VM uses for locals and temporaries</dd>
        <dt><code>up[0]</code></dt>
        <dd>upvalue — a variable captured from the enclosing function</dd>
        <dt><code>_G["x"]</code></dt>
        <dd>global variable named <code>x</code></dd>
        <dt><code>proto[0]</code></dt>
        <dd>a nested function definition inside this one</dd>
        <dt><code>"foo"</code>, <code>42</code></dt>
        <dd>a constant literal baked into the bytecode</dd>
        <dt><code>multi(n)</code></dt>
        <dd>multiple return values (n of them)</dd>
        <dt><code>...</code></dt>
        <dd>varargs — the rest of the arguments</dd>
      </dl>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :tip, :string, default: nil

  @doc """
  Small label/value pill used to summarise a prototype's metadata
  (`params`, `vararg`, `registers`, `upvalues`).
  """
  def meta_pill(assigns) do
    ~H"""
    <div
      class="rounded-box bg-base-100/60 border border-base-300/40 px-3 py-2"
      data-tip={@tip}
    >
      <div class="text-[10px] uppercase tracking-wider text-base-content/50 font-semibold">
        {@label}
      </div>
      <div class="font-mono text-sm text-base-content/90">{@value}</div>
    </div>
    """
  end

  attr :blocks, :list, required: true
  attr :selected, :integer, default: 0
  attr :variant, :atom, default: :full, values: [:full, :compact]
  attr :max_height, :string, default: "max-h-[520px]"
  attr :show_block_tabs, :boolean, default: true
  attr :show_meta_pills, :boolean, default: true
  attr :show_legend, :boolean, default: true
  attr :empty_label, :string, default: "Bytecode appears here after a successful parse."
  attr :cross_highlight?, :boolean, default: true

  @doc """
  The full bytecode panel: header, block tabs, meta pills, legend,
  and instruction table with tooltips.

  Both the playground and tour render this. Pass `variant: :compact`
  on the tour for a denser layout that omits the per-prototype meta
  grid and the column header strip.
  """
  def bytecode_panel(assigns) do
    ~H"""
    <div class="rounded-box border border-base-300/60 bg-base-200/50 overflow-hidden">
      <.opcode_docs_script />

      <div class="px-4 py-2 border-b border-base-300/60 bg-base-300/30 flex items-center justify-between">
        <div class="text-sm font-semibold text-base-content/70">
          Bytecode &middot; <span class="font-mono text-base-content/50">Lua.Compiler.Prototype</span>
        </div>
        <div class="text-xs font-mono text-base-content/50">
          <%= if @blocks != [] do %>
            {length(@blocks)} proto{if length(@blocks) != 1, do: "s"}
          <% else %>
            —
          <% end %>
        </div>
      </div>

      <%= if @blocks == [] do %>
        <div class="p-6 text-sm text-base-content/50 font-mono">
          {@empty_label}
        </div>
      <% else %>
        <%= if @show_block_tabs and length(@blocks) > 1 do %>
          <div class="px-3 pt-3 flex gap-1 flex-wrap">
            <%= for block <- @blocks do %>
              <button
                phx-click="select-block"
                phx-value-index={block.index}
                class={[
                  "btn btn-xs font-mono",
                  block.index == @selected && "btn-primary",
                  block.index != @selected && "btn-ghost border border-base-300/60"
                ]}
              >
                {block.name}
              </button>
            <% end %>
          </div>
        <% end %>

        <%= for block <- @blocks, block.index == @selected do %>
          <%= if @show_meta_pills do %>
            <div class="px-4 py-3 border-b border-base-300/40 grid grid-cols-2 sm:grid-cols-4 gap-2 text-xs">
              <.meta_pill
                label="params"
                value={block.param_count}
                tip="**Parameters.** How many named arguments this function declares (e.g. `function f(a, b)` has 2). Extra args beyond this collect into `...` if vararg is `yes`."
              />
              <.meta_pill
                label="vararg"
                value={if block.is_vararg, do: "yes", else: "no"}
                tip="**Varargs.** Whether this function accepts `...` (extra arguments past the declared params). The top-level chunk is always vararg."
              />
              <.meta_pill
                label="registers"
                value={block.max_registers}
                tip="**Registers.** How many slots this function reserves on the VM's stack. Think of them as numbered scratch boxes (`r0`, `r1`, …) where the VM stashes locals and intermediate values."
              />
              <.meta_pill
                label="upvalues"
                value={block.upvalue_count}
                tip="**Upvalues.** Variables this function borrows from the enclosing function. When you define a closure, every outer variable it touches becomes an upvalue."
              />
            </div>
          <% end %>

          <%= if @show_legend and @cross_highlight? do %>
            <div class="px-4 py-1.5 text-[11px] text-base-content/55 border-b border-base-300/40 flex items-center gap-2">
              <span class="inline-block size-2.5 rounded-sm bg-primary/40 ring-1 ring-primary/60">
              </span>
              Hover a row to highlight every instruction from the same source line. Click to jump the editor there.
            </div>
          <% end %>

          <div
            id={"bytecode-table-#{block.index}"}
            phx-hook={@cross_highlight? && "BytecodeHighlight"}
            class={["font-mono text-xs leading-6", @max_height, "overflow-auto"]}
          >
            <table class="w-full">
              <%= if @variant == :full do %>
                <thead class="sticky top-0 bg-base-300/40 backdrop-blur z-10">
                  <tr class="text-[10px] uppercase tracking-wider text-base-content/55">
                    <th
                      class="px-3 py-1.5 font-semibold text-right w-12 border-b border-base-300/50"
                      data-tip="**PC** — program counter. The index of this instruction in the function's bytecode, starting at `000`. The VM executes them top to bottom unless an instruction jumps."
                    >
                      PC
                    </th>
                    <th
                      class="px-2 py-1.5 font-semibold text-right w-10 border-b border-base-300/50"
                      data-tip="**Source line.** Which line of your Lua code this instruction was compiled from. Hover a row to light up every instruction from the same line; click to jump the editor there."
                    >
                      Line
                    </th>
                    <th
                      class="px-3 py-1.5 font-semibold text-left border-b border-base-300/50"
                      data-tip="**Instruction.** An opcode (e.g. `load_constant`) plus its operands. Hover any opcode to see what it does, or click to open the full reference."
                    >
                      Instruction
                    </th>
                  </tr>
                </thead>
              <% end %>
              <tbody>
                <%= for ins <- block.instructions do %>
                  <tr class={row_classes(ins, @cross_highlight?)} data-line={ins.line}>
                    <td class="px-3 py-1 text-base-content/40 select-none text-right w-12 align-top">
                      {pad_pc(ins.pc)}
                    </td>
                    <td class="px-2 py-1 text-base-content/40 select-none w-10 text-right align-top">
                      <%= if ins.line do %>
                        <span class="lua-row-line text-base-content/40">L{ins.line}</span>
                      <% end %>
                    </td>
                    <td class="px-3 py-1 align-top">
                      <.opcode_link op={ins.op} />
                      <span class="text-base-content/80" data-tip-html="#args-glossary">
                        {" "}{Bytecode.format_args(ins.op, ins.args)}
                      </span>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  attr :op, :atom, required: true

  @doc """
  An opcode mnemonic rendered as an anchor to the reference page. The
  Tippy delegator picks up `data-tip-op` and renders the rich card.
  """
  def opcode_link(assigns) do
    ~H"""
    <a
      href={"/reference/opcodes##{@op}"}
      data-tip-op={@op}
      class={[
        "hover:underline decoration-dotted underline-offset-2",
        Bytecode.op_class(@op)
      ]}
    >
      {@op}
    </a>
    """
  end

  defp pad_pc(n), do: n |> Integer.to_string() |> String.pad_leading(3, "0")

  defp row_classes(ins, cross_highlight?) do
    [
      "border-b border-base-300/30 hover:bg-base-300/30",
      ins.line && cross_highlight? && "cursor-pointer",
      ins.op == :source_line && "text-base-content/40 italic"
    ]
  end
end

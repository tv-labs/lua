defmodule DemoWeb.PlaygroundLive do
  use DemoWeb, :live_view

  alias Website.LuaSandbox

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Playground")
      |> assign(:examples, LuaSandbox.examples())
      |> assign(:active_example, "hello")
      |> assign(:source, default_source("hello"))
      |> assign(:result, nil)
      |> assign(:running, false)
      |> assign(:show_bytecode, true)
      |> assign(:selected_block, 0)
      |> assign(:hover_line, nil)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    case params do
      %{"example" => id} ->
        if Enum.any?(LuaSandbox.examples(), &(&1.id == id)) and
             socket.assigns.active_example != id do
          source = default_source(id)

          {:noreply,
           socket
           |> assign(:active_example, id)
           |> assign(:source, source)
           |> assign(:result, nil)
           |> assign(:selected_block, 0)
           |> push_event("lua-editor:set-source", %{source: source})}
        else
          {:noreply, socket}
        end

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("source-changed", %{"source" => source}, socket) do
    {:noreply, assign(socket, :source, source)}
  end

  def handle_event("load-example", %{"id" => id}, socket) do
    source = default_source(id)

    {:noreply,
     socket
     |> assign(:active_example, id)
     |> assign(:source, source)
     |> assign(:result, nil)
     |> assign(:selected_block, 0)
     |> push_event("lua-editor:set-source", %{source: source})
     |> push_patch(to: ~p"/playground/#{id}")}
  end

  def handle_event("run", %{"source" => source}, socket) do
    socket = assign(socket, source: source, running: true)
    send(self(), {:run, source})
    {:noreply, socket}
  end

  def handle_event("toggle-bytecode", _, socket) do
    {:noreply, update(socket, :show_bytecode, &(!&1))}
  end

  def handle_event("select-block", %{"index" => idx}, socket) do
    {:noreply, assign(socket, :selected_block, String.to_integer(idx))}
  end

  def handle_event("hover-line", %{"line" => line}, socket) do
    parsed =
      case line do
        nil -> nil
        "" -> nil
        s -> String.to_integer(s)
      end

    {:noreply, assign(socket, :hover_line, parsed)}
  end

  def handle_event("clear", _params, socket) do
    {:noreply,
     socket
     |> assign(:source, "")
     |> assign(:result, nil)
     |> assign(:selected_block, 0)
     |> push_event("lua-editor:set-source", %{source: ""})}
  end

  @impl true
  def handle_info({:run, source}, socket) do
    result = LuaSandbox.run(source, timeout_ms: 1500)

    {:noreply,
     socket
     |> assign(:running, false)
     |> assign(:result, result)
     |> assign(:selected_block, 0)}
  end

  defp default_source(id) do
    case Enum.find(LuaSandbox.examples(), &(&1.id == id)) do
      nil -> hd(LuaSandbox.examples()).source
      ex -> ex.source
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:playground}>
      <div class="mx-auto max-w-7xl px-4 sm:px-6 lg:px-8 py-8">
        <div class="mb-6 flex flex-col md:flex-row md:items-end md:justify-between gap-4">
          <div>
            <h1 class="text-3xl sm:text-4xl font-bold tracking-tight">
              Lua Playground
            </h1>
            <p class="text-base-content/70 mt-2 max-w-2xl">
              Write Lua, run it on the BEAM, and watch the
              <span class="text-primary font-semibold">register-based bytecode</span>
              this VM actually executes. No JavaScript Lua — every byte is Elixir.
            </p>
          </div>
          <div class="flex items-center gap-2">
            <button class="btn btn-ghost btn-sm" phx-click="clear">
              <.icon name="hero-trash-micro" class="size-4" /> Clear
            </button>
            <button
              class={["btn btn-sm", @show_bytecode && "btn-primary", !@show_bytecode && "btn-ghost"]}
              phx-click="toggle-bytecode"
            >
              <.icon name="hero-code-bracket-square-micro" class="size-4" />
              Bytecode {if @show_bytecode, do: "on", else: "off"}
            </button>
          </div>
        </div>

        <div class="flex gap-2 overflow-x-auto pb-3 -mx-1 px-1 mb-4 scrollbar-thin">
          <%= for ex <- @examples do %>
            <button
              phx-click="load-example"
              phx-value-id={ex.id}
              class={[
                "btn btn-sm whitespace-nowrap",
                @active_example == ex.id && "btn-primary",
                @active_example != ex.id && "btn-outline"
              ]}
            >
              {raw(ex.title)}
            </button>
          <% end %>
        </div>

        <div class={[
          "grid gap-4",
          @show_bytecode && "lg:grid-cols-[1.1fr_1fr]",
          !@show_bytecode && "grid-cols-1"
        ]}>
          <div class="flex flex-col gap-4 min-w-0">
            <.editor_panel source={@source} running={@running} />
            <.output_panel result={@result} running={@running} />
          </div>

          <%= if @show_bytecode do %>
            <.bytecode_panel
              result={@result}
              source={@source}
              selected={@selected_block}
              hover_line={@hover_line}
            />
          <% end %>
        </div>

        <div class="mt-10 grid sm:grid-cols-3 gap-3 text-sm">
          <.kbd_card>
            <:label>Run</:label>
            <kbd class="kbd kbd-sm">⌘</kbd> <span>+</span> <kbd class="kbd kbd-sm">↵</kbd>
          </.kbd_card>
          <.kbd_card>
            <:label>Indent</:label>
            <kbd class="kbd kbd-sm">Tab</kbd> <span>/</span> <kbd class="kbd kbd-sm">Shift</kbd>
            <span>+</span> <kbd class="kbd kbd-sm">Tab</kbd>
          </.kbd_card>
          <.kbd_card>
            <:label>Heads-up</:label>
            <span class="text-base-content/70">
              Snippets run in a sandboxed VM with a 1.5s timeout.
            </span>
          </.kbd_card>
        </div>
      </div>
    </Layouts.app>
    """
  end

  slot :label, required: true
  slot :inner_block, required: true

  defp kbd_card(assigns) do
    ~H"""
    <div class="rounded-box border border-base-300/60 bg-base-200/50 px-4 py-3 flex items-center gap-3">
      <span class="text-xs uppercase tracking-wider text-base-content/50 font-semibold w-16">
        {render_slot(@label)}
      </span>
      <span class="flex items-center gap-1 flex-wrap">
        {render_slot(@inner_block)}
      </span>
    </div>
    """
  end

  attr :source, :string, required: true
  attr :running, :boolean, required: true

  defp editor_panel(assigns) do
    ~H"""
    <form
      phx-submit="run"
      phx-change="source-changed"
      class="rounded-box border border-base-300/60 bg-base-200/50 overflow-hidden shadow-sm"
    >
      <div class="flex items-center justify-between px-4 py-2 border-b border-base-300/60 bg-base-300/30">
        <div class="flex items-center gap-2 text-sm font-mono text-base-content/70">
          <span class="size-2 rounded-full bg-red-400/70" />
          <span class="size-2 rounded-full bg-yellow-400/70" />
          <span class="size-2 rounded-full bg-green-400/70" />
          <span class="ml-2 font-semibold">main.lua</span>
        </div>
        <button
          type="submit"
          class={[
            "btn btn-sm btn-primary shadow-sm",
            @running && "btn-disabled"
          ]}
          disabled={@running}
        >
          <%= if @running do %>
            <span class="loading loading-spinner loading-xs" /> Running
          <% else %>
            <.icon name="hero-play-micro" class="size-4" /> Run
          <% end %>
        </button>
      </div>
      <div
        id="editor-wrap"
        phx-hook="LuaEditor"
        phx-update="ignore"
        class="relative h-[420px] overflow-hidden"
      >
        <textarea
          id="lua-source"
          name="source"
          spellcheck="false"
          autocomplete="off"
          class="w-full h-full font-mono text-sm leading-6 p-4 bg-transparent resize-none focus:outline-none"
        ><%= @source %></textarea>
      </div>
    </form>
    """
  end

  attr :result, :map, default: nil
  attr :running, :boolean, required: true

  defp output_panel(assigns) do
    ~H"""
    <div class="rounded-box border border-base-300/60 bg-base-200/50 overflow-hidden">
      <div class="px-4 py-2 border-b border-base-300/60 bg-base-300/30 flex items-center justify-between">
        <div class="text-sm font-semibold text-base-content/70">Output</div>
        <div class="text-xs font-mono text-base-content/50">
          <%= cond do %>
            <% @running -> %>
              <span class="text-primary">executing…</span>
            <% match?(%{status: :ok}, @result) -> %>
              <span class="text-success">
                ok &middot; {format_us(@result.duration_us)}
              </span>
            <% match?(%{status: :timeout}, @result) -> %>
              <span class="text-warning">timeout</span>
            <% match?(%{status: :error}, @result) -> %>
              <span class="text-error">error</span>
            <% true -> %>
              <span class="text-base-content/40">idle</span>
          <% end %>
        </div>
      </div>
      <div class="p-4 font-mono text-sm space-y-2 min-h-[140px]">
        <%= cond do %>
          <% @running -> %>
            <div class="text-base-content/50">Running on the BEAM…</div>
          <% match?(%{status: :error}, @result) -> %>
            <pre class="whitespace-pre-wrap text-error/90"><%= @result.error %></pre>
            <%= if @result.output != "" do %>
              <div class="mt-3 border-t border-base-300/50 pt-2">
                <div class="text-xs uppercase text-base-content/50 mb-1">
                  Output before error
                </div>
                <pre class="whitespace-pre-wrap text-base-content/80"><%= @result.output %></pre>
              </div>
            <% end %>
          <% match?(%{status: :timeout}, @result) -> %>
            <div class="text-warning">{@result.error}</div>
          <% match?(%{status: :ok}, @result) -> %>
            <%= if @result.output != "" do %>
              <pre class="whitespace-pre-wrap text-base-content/90"><%= @result.output %></pre>
            <% end %>
            <%= if @result.returns != [] do %>
              <div class={["mt-1", @result.output != "" && "border-t border-base-300/50 pt-2"]}>
                <div class="text-xs uppercase tracking-wider text-base-content/50 mb-1 flex items-center gap-2">
                  <.icon name="hero-arrow-uturn-left-micro" class="size-3" /> returned
                </div>
                <pre class="whitespace-pre-wrap text-primary"><%= Enum.join(@result.returns, ", ") %></pre>
              </div>
            <% end %>
            <%= if @result.output == "" and @result.returns == [] do %>
              <div class="text-base-content/40">
                <em>(no output, no return values)</em>
              </div>
            <% end %>
          <% true -> %>
            <div class="text-base-content/40">
              Hit <kbd class="kbd kbd-xs">Run</kbd>
              or press <kbd class="kbd kbd-xs">⌘</kbd> <kbd class="kbd kbd-xs">↵</kbd>
              to execute.
            </div>
        <% end %>
      </div>
    </div>
    """
  end

  attr :result, :map, default: nil
  attr :source, :string, required: true
  attr :selected, :integer, required: true
  attr :hover_line, :integer, default: nil

  defp bytecode_panel(assigns) do
    bytecode =
      cond do
        match?(%{bytecode: [_ | _]}, assigns.result) ->
          assigns.result.bytecode

        true ->
          case LuaSandbox.compile(assigns.source) do
            {:ok, _chunk, blocks} -> blocks
            {:error, _} -> []
          end
      end

    assigns = assign(assigns, :bytecode, bytecode)

    ~H"""
    <div class="rounded-box border border-base-300/60 bg-base-200/50 overflow-hidden lg:sticky lg:top-20 self-start">
      <div class="px-4 py-2 border-b border-base-300/60 bg-base-300/30 flex items-center justify-between">
        <div class="text-sm font-semibold text-base-content/70">
          Bytecode &middot; <span class="font-mono text-base-content/50">Lua.Compiler.Prototype</span>
        </div>
        <div class="text-xs font-mono text-base-content/50">
          <%= if @bytecode != [] do %>
            {length(@bytecode)} proto{if length(@bytecode) != 1, do: "s"}
          <% else %>
            —
          <% end %>
        </div>
      </div>

      <%= if @bytecode == [] do %>
        <div class="p-6 text-sm text-base-content/50 font-mono">
          Bytecode appears here after a successful parse.
        </div>
      <% else %>
        <%= if length(@bytecode) > 1 do %>
          <div class="px-3 pt-3 flex gap-1 flex-wrap">
            <%= for block <- @bytecode do %>
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

        <%= for block <- @bytecode, block.index == @selected do %>
          <div class="px-4 py-3 border-b border-base-300/40 grid grid-cols-2 sm:grid-cols-4 gap-2 text-xs">
            <.meta_pill label="params" value={block.param_count} />
            <.meta_pill label="vararg" value={if block.is_vararg, do: "yes", else: "no"} />
            <.meta_pill label="registers" value={block.max_registers} />
            <.meta_pill label="upvalues" value={block.upvalue_count} />
          </div>

          <div class="font-mono text-xs leading-6 max-h-[520px] overflow-auto">
            <table class="w-full">
              <tbody>
                <%= for ins <- block.instructions do %>
                  <tr class={[
                    "border-b border-base-300/30 hover:bg-base-300/30",
                    @hover_line && ins.line == @hover_line && "bg-primary/10",
                    ins.op == :source_line && "text-base-content/40 italic"
                  ]}>
                    <td class="px-3 py-1 text-base-content/40 select-none text-right w-12">
                      {pad_pc(ins.pc)}
                    </td>
                    <td class="px-2 py-1 text-base-content/40 select-none w-10 text-right">
                      <%= if ins.line do %>
                        <span class="text-base-content/40">L{ins.line}</span>
                      <% end %>
                    </td>
                    <td class="px-3 py-1">
                      <span class={op_class(ins.op)}>{ins.op}</span>
                      {" "}
                      <span class="text-base-content/80">{format_args(ins.op, ins.args)}</span>
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

  attr :label, :string, required: true
  attr :value, :any, required: true

  defp meta_pill(assigns) do
    ~H"""
    <div class="rounded-box bg-base-100/60 border border-base-300/40 px-3 py-2">
      <div class="text-[10px] uppercase tracking-wider text-base-content/50 font-semibold">
        {@label}
      </div>
      <div class="font-mono text-sm text-base-content/90">{@value}</div>
    </div>
    """
  end

  defp pad_pc(n), do: n |> Integer.to_string() |> String.pad_leading(3, "0")

  # Per-opcode rendering — argument positions vary by opcode, so we tag the
  # ones that are register indices with `r` and leave counts/values bare.
  defp format_args(op, args), do: do_format(op, args)

  # All-register triadic arithmetic and comparison ops
  defp do_format(op, [a, b, c])
       when op in [
              :add,
              :subtract,
              :multiply,
              :divide,
              :floor_divide,
              :modulo,
              :power,
              :concatenate,
              :bitwise_and,
              :bitwise_or,
              :bitwise_xor,
              :shift_left,
              :shift_right,
              :equal,
              :less_than,
              :less_equal
            ],
       do: "r#{a}, r#{b}, r#{c}"

  # Unary register ops
  defp do_format(op, [a, b])
       when op in [:negate, :not, :length, :bitwise_not, :move],
       do: "r#{a}, r#{b}"

  defp do_format(:load_constant, [dest, val]), do: "r#{dest}, #{format_lit(val)}"
  defp do_format(:load_nil, [dest, count]), do: "r#{dest}, #{count}"
  defp do_format(:load_boolean, [dest, val]), do: "r#{dest}, #{val}"
  defp do_format(:load_env, [dest]), do: "r#{dest}"

  defp do_format(:get_upvalue, [dest, idx]), do: "r#{dest}, up[#{idx}]"
  defp do_format(:set_upvalue, [idx, src]), do: "up[#{idx}], r#{src}"
  defp do_format(:get_open_upvalue, [dest, reg]), do: "r#{dest}, r#{reg}"
  defp do_format(:set_open_upvalue, [reg, src]), do: "r#{reg}, r#{src}"
  defp do_format(:get_global, [dest, name]), do: ~s|r#{dest}, _G["#{name}"]|
  defp do_format(:set_global, [name, src]), do: ~s|_G["#{name}"], r#{src}|

  defp do_format(:new_table, [dest, a, h]), do: "r#{dest}, array=#{a}, hash=#{h}"

  defp do_format(:get_table, [d, t, k | _]),
    do: "r#{d}, r#{t}[#{format_arg(k)}]"

  defp do_format(:set_table, [t, k, v | _]),
    do: "r#{t}[#{format_arg(k)}], r#{v}"

  defp do_format(:get_field, [d, t, name | _]), do: ~s|r#{d}, r#{t}.#{name}|
  defp do_format(:set_field, [t, name, v | _]), do: ~s|r#{t}.#{name}, r#{v}|

  defp do_format(:set_list, [t, start, count, offset]),
    do: "r#{t}, start=#{start}, count=#{count}, off=#{offset}"

  defp do_format(:call, [base, argc, resc | _]),
    do: "r#{base}, args=#{count_fmt(argc)}, results=#{count_fmt(resc)}"

  defp do_format(:tail_call, [base, argc | _]),
    do: "r#{base}, args=#{count_fmt(argc)}"

  defp do_format(:return, [base, count]), do: "r#{base}, count=#{count_fmt(count)}"
  defp do_format(:return_vararg, _), do: "(varargs)"
  defp do_format(:vararg, [base, count]), do: "r#{base}, count=#{count_fmt(count)}"
  defp do_format(:self, [base, obj, name | _]), do: "r#{base}, r#{obj}, .#{name}"
  defp do_format(:closure, [dest, proto_idx]), do: "r#{dest}, proto[#{proto_idx}]"

  defp do_format(:test, [reg | _]), do: "r#{reg}"
  defp do_format(:test_true, [reg | _]), do: "r#{reg}"
  defp do_format(:test_and, [dest, src | _]), do: "r#{dest}, r#{src}"
  defp do_format(:test_or, [dest, src | _]), do: "r#{dest}, r#{src}"
  defp do_format(:numeric_for, [base | _]), do: "r#{base}"

  defp do_format(:generic_for, [base, var_count | _]),
    do: "r#{base}, vars=#{var_count}"

  defp do_format(:scope, [n | _]), do: "registers=#{n}"
  defp do_format(:source_line, [ln]), do: "line #{ln}"
  defp do_format(_, args), do: args |> Enum.map(&format_arg/1) |> Enum.join(", ")

  defp format_arg({:constant, val}), do: format_lit(val)
  defp format_arg({:global, name}), do: ~s|<#{name}>|
  defp format_arg(atom) when is_atom(atom), do: inspect(atom)
  defp format_arg(n) when is_integer(n), do: Integer.to_string(n)
  defp format_arg(other), do: inspect(other, limit: 20)

  defp format_lit(val) when is_binary(val), do: inspect(val)
  defp format_lit(val), do: inspect(val, limit: 20)

  defp count_fmt({:multi, n}), do: "multi(#{n})"
  defp count_fmt(:varargs), do: "..."
  defp count_fmt(n) when is_integer(n), do: Integer.to_string(n)
  defp count_fmt(other), do: inspect(other)

  defp op_class(:source_line), do: "text-base-content/40"

  defp op_class(op) when op in [:return, :return_vararg, :tail_call],
    do: "text-accent font-semibold"

  defp op_class(op)
       when op in [:call, :closure, :self, :vararg],
       do: "text-primary font-semibold"

  defp op_class(op)
       when op in [
              :test,
              :test_true,
              :test_and,
              :test_or,
              :while_loop,
              :repeat_loop,
              :numeric_for,
              :generic_for,
              :break,
              :scope
            ],
       do: "text-warning font-semibold"

  defp op_class(op)
       when op in [
              :add,
              :subtract,
              :multiply,
              :divide,
              :floor_divide,
              :modulo,
              :power,
              :concatenate,
              :negate,
              :equal,
              :less_than,
              :less_equal,
              :length,
              :not,
              :bitwise_and,
              :bitwise_or,
              :bitwise_xor,
              :shift_left,
              :shift_right,
              :bitwise_not
            ],
       do: "text-secondary font-semibold"

  defp op_class(op)
       when op in [:new_table, :set_list, :get_table, :set_table, :get_field, :set_field],
       do: "text-info font-semibold"

  defp op_class(_), do: "text-success font-semibold"

  defp format_us(us) when us < 1_000, do: "#{us} µs"
  defp format_us(us) when us < 1_000_000, do: "#{Float.round(us / 1_000, 2)} ms"
  defp format_us(us), do: "#{Float.round(us / 1_000_000, 3)} s"
end

defmodule DemoWeb.OpcodesLive do
  use DemoWeb, :live_view

  alias DemoWeb.Bytecode

  @categories [
    %{
      id: "loads",
      title: "Loads & moves",
      blurb:
        "Get values into registers — constants, nil, booleans, and register-to-register copies.",
      ops: [:load_constant, :load_nil, :load_boolean, :load_env, :move]
    },
    %{
      id: "globals-upvalues",
      title: "Globals & upvalues",
      blurb: "Read and write the global environment and captured outer-scope bindings.",
      ops: [
        :get_global,
        :set_global,
        :get_upvalue,
        :set_upvalue,
        :get_open_upvalue,
        :set_open_upvalue
      ]
    },
    %{
      id: "tables",
      title: "Tables",
      blurb: "Allocate, index, field-access, and bulk-fill the universal Lua data structure.",
      ops: [:new_table, :get_table, :set_table, :get_field, :set_field, :set_list, :self]
    },
    %{
      id: "arithmetic",
      title: "Arithmetic & strings",
      blurb: "Numeric and bitwise ops, plus string concatenation and length.",
      ops: [
        :add,
        :subtract,
        :multiply,
        :divide,
        :floor_divide,
        :modulo,
        :power,
        :negate,
        :concatenate,
        :length,
        :bitwise_and,
        :bitwise_or,
        :bitwise_xor,
        :bitwise_not,
        :shift_left,
        :shift_right
      ]
    },
    %{
      id: "comparison",
      title: "Comparison & logic",
      blurb: "Equality, ordering, and short-circuit logical control.",
      ops: [:equal, :less_than, :less_equal, :not, :test, :test_true, :test_and, :test_or]
    },
    %{
      id: "control",
      title: "Control flow",
      blurb:
        "Loops and structured exits. Most jumps live on the continuation list, not as PC offsets.",
      ops: [:while_loop, :repeat_loop, :numeric_for, :generic_for, :break, :scope]
    },
    %{
      id: "calls",
      title: "Calls & returns",
      blurb:
        "Invoke and return — including tail calls, varargs, and the method-shim for `obj:method(...)`.",
      ops: [:call, :tail_call, :return, :return_vararg, :vararg]
    },
    %{
      id: "closures",
      title: "Closures",
      blurb: "Build nested functions with captured upvalues.",
      ops: [:closure]
    },
    %{
      id: "meta",
      title: "Metadata",
      blurb: "Pseudo-instructions for source tracking and debugging.",
      ops: [:source_line]
    }
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Opcode reference")
     |> assign(:categories, @categories)
     |> assign(:query, "")}
  end

  @impl true
  def handle_event("filter", %{"q" => q}, socket) do
    {:noreply, assign(socket, :query, q)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:opcodes}>
      <div class="mx-auto max-w-7xl px-4 sm:px-6 lg:px-8 py-10">
        <div class="grid lg:grid-cols-[260px_1fr] gap-10">
          <aside class="lg:sticky lg:top-20 lg:self-start space-y-4">
            <div>
              <h2 class="text-xs uppercase tracking-[0.18em] font-bold text-base-content/50 mb-2">
                Opcode reference
              </h2>
              <p class="text-sm text-base-content/70 leading-relaxed">
                Every instruction this VM emits, grouped by what it does.
                Match the colours from the <.link navigate={~p"/playground"} class="link link-primary">playground</.link>.
              </p>
            </div>

            <form phx-change="filter" class="contents">
              <input
                type="text"
                name="q"
                value={@query}
                placeholder="Filter opcodes…"
                class="input input-sm input-bordered w-full"
                autocomplete="off"
                spellcheck="false"
              />
            </form>

            <nav>
              <ol class="space-y-1 text-sm">
                <%= for cat <- @categories do %>
                  <li>
                    <a
                      href={"##{cat.id}"}
                      class="block px-3 py-1.5 rounded-box text-base-content/70 hover:bg-base-200 hover:text-base-content"
                    >
                      {cat.title}
                      <span class="ml-1 text-xs text-base-content/40">
                        ({length(visible_ops(cat.ops, @query))})
                      </span>
                    </a>
                  </li>
                <% end %>
              </ol>
            </nav>
          </aside>

          <article class="min-w-0">
            <header class="mb-8">
              <h1 class="text-3xl sm:text-4xl font-bold tracking-tight">
                Opcode reference
              </h1>
              <p class="mt-3 text-base-content/70 max-w-2xl leading-relaxed">
                The Lua compiler in this library lowers source to a flat
                stream of <strong>register-based</strong>
                opcodes. There
                are no labels and no PC-relative jumps — control flow is
                threaded through an explicit <code class="text-primary">continuation list</code>
                inside the executor. The full set of opcodes the
                disassembler emits is documented below.
              </p>
            </header>

            <%= for cat <- @categories do %>
              <% ops = visible_ops(cat.ops, @query) %>
              <%= if ops != [] do %>
                <section id={cat.id} class="mb-12 scroll-mt-20">
                  <div class="mb-4">
                    <h2 class="text-xl sm:text-2xl font-bold tracking-tight">
                      {cat.title}
                    </h2>
                    <p class="mt-1 text-sm text-base-content/60">{cat.blurb}</p>
                  </div>

                  <div class="grid sm:grid-cols-2 gap-3">
                    <%= for op <- ops do %>
                      <div class="rounded-box border border-base-300/50 bg-base-200/40 p-4 hover:bg-base-200 transition-colors">
                        <div class="flex items-baseline justify-between gap-3 mb-2">
                          <code class={["text-lg font-bold font-mono", Bytecode.op_class(op)]}>
                            {op}
                          </code>
                          <span class="text-[10px] uppercase tracking-wider text-base-content/40 font-mono">
                            {op_signature(op)}
                          </span>
                        </div>
                        <p class="text-sm text-base-content/75 leading-relaxed">
                          {Bytecode.opcode_doc(op) ||
                            raw("<em class='text-base-content/40'>(undocumented — see source)</em>")}
                        </p>
                      </div>
                    <% end %>
                  </div>
                </section>
              <% end %>
            <% end %>

            <%= if all_visible(@categories, @query) == 0 do %>
              <div class="text-center py-16 text-base-content/50">
                <.icon name="hero-magnifying-glass" class="size-8 mx-auto mb-2 opacity-50" />
                <div>No opcodes match <code>{@query}</code>.</div>
              </div>
            <% end %>
          </article>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp visible_ops(ops, ""), do: ops

  defp visible_ops(ops, query) do
    q = String.downcase(String.trim(query))
    Enum.filter(ops, &String.contains?(Atom.to_string(&1), q))
  end

  defp all_visible(cats, q), do: Enum.sum(Enum.map(cats, &length(visible_ops(&1.ops, q))))

  # Compact signature shown on each opcode card; not meant to be exhaustive,
  # just enough for a reader skimming to know what the args look like.
  defp op_signature(op) do
    case op do
      :load_constant ->
        "rD, K"

      :load_nil ->
        "rD, N"

      :load_boolean ->
        "rD, bool"

      :load_env ->
        "rD"

      :move ->
        "rD, rS"

      :get_global ->
        "rD, name"

      :set_global ->
        "name, rS"

      :get_upvalue ->
        "rD, up[i]"

      :set_upvalue ->
        "up[i], rS"

      :get_open_upvalue ->
        "rD, rS"

      :set_open_upvalue ->
        "rD, rS"

      :new_table ->
        "rD, array, hash"

      :get_table ->
        "rD, rT, k"

      :set_table ->
        "rT, k, rV"

      :get_field ->
        "rD, rT, name"

      :set_field ->
        "rT, name, rV"

      :set_list ->
        "rT, start, count, off"

      :self ->
        "rD, rO, name"

      :closure ->
        "rD, proto[i]"

      :call ->
        "rB, argc, resc"

      :tail_call ->
        "rB, argc"

      :return ->
        "rB, count"

      :return_vararg ->
        "(varargs)"

      :vararg ->
        "rB, count"

      :test ->
        "rR"

      :test_true ->
        "rR"

      :test_and ->
        "rD, rS"

      :test_or ->
        "rD, rS"

      :numeric_for ->
        "rB"

      :generic_for ->
        "rB, vars"

      :scope ->
        "registers"

      :source_line ->
        "line"

      op when op in [:add, :subtract, :multiply, :divide, :floor_divide, :modulo, :power] ->
        "rD, rA, rB"

      op when op in [:concatenate, :bitwise_and, :bitwise_or, :bitwise_xor] ->
        "rD, rA, rB"

      op when op in [:shift_left, :shift_right] ->
        "rD, rA, rB"

      op when op in [:equal, :less_than, :less_equal] ->
        "rD, rA, rB"

      op when op in [:negate, :not, :length, :bitwise_not] ->
        "rD, rS"

      _ ->
        ""
    end
  end
end

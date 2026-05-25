defmodule DemoWeb.TourLive do
  use DemoWeb, :live_view

  alias Website.LuaSandbox

  @impl true
  def mount(_params, _session, socket) do
    lessons = LuaSandbox.tour_lessons()

    socket =
      socket
      |> assign(:page_title, "Tour of Lua")
      |> assign(:lessons, lessons)
      |> assign(:lesson, hd(lessons))
      |> assign(:source, Map.get(hd(lessons), :source, ""))
      |> assign(:result, nil)
      |> assign(:running, false)
      |> assign(:show_bytecode, false)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    case params do
      %{"slug" => slug} ->
        case Enum.find(socket.assigns.lessons, &(&1.slug == slug)) do
          nil ->
            {:noreply, push_patch(socket, to: ~p"/tour")}

          lesson ->
            {:noreply,
             socket
             |> assign(:lesson, lesson)
             |> assign(:source, Map.get(lesson, :source, ""))
             |> assign(:result, nil)}
        end

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("source-changed", %{"source" => source}, socket) do
    {:noreply, assign(socket, :source, source)}
  end

  def handle_event("run", %{"source" => source}, socket) do
    send(self(), {:run, source})
    {:noreply, assign(socket, source: source, running: true)}
  end

  def handle_event("reset", _params, socket) do
    source = Map.get(socket.assigns.lesson, :source, "")

    {:noreply,
     socket
     |> assign(:source, source)
     |> assign(:result, nil)
     |> push_event("lua-editor:set-source", %{source: source})}
  end

  def handle_event("toggle-bytecode", _, socket) do
    {:noreply, update(socket, :show_bytecode, &(!&1))}
  end

  # The shared LuaEditor hook pushes cursor-line events; tour doesn't
  # cross-highlight, so just acknowledge.
  def handle_event("hover-line", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:run, source}, socket) do
    result = LuaSandbox.run(source, timeout_ms: 1500)
    {:noreply, socket |> assign(:result, result) |> assign(:running, false)}
  end

  defp lesson_index(lessons, lesson) do
    Enum.find_index(lessons, &(&1.slug == lesson.slug)) || 0
  end

  defp prev_lesson(lessons, lesson) do
    idx = lesson_index(lessons, lesson)
    if idx > 0, do: Enum.at(lessons, idx - 1), else: nil
  end

  defp next_lesson(lessons, lesson) do
    idx = lesson_index(lessons, lesson)
    Enum.at(lessons, idx + 1)
  end

  defp lesson_by_slug(lessons, slug), do: Enum.find(lessons, &(&1.slug == slug))

  defp runnable?(lesson), do: Map.get(lesson, :runnable, true)

  defp has_editor?(lesson), do: is_binary(Map.get(lesson, :source))

  defp integration?(lesson), do: lesson.chapter == :integration

  attr :lessons, :list, required: true
  attr :lesson, :map, required: true

  defp nav_body(assigns) do
    ~H"""
    <div>
      <div class="mb-4">
        <h2 class="text-xs font-semibold uppercase tracking-wider text-base-content/50 mb-2">
          A tour of Lua &amp; Lua.ex
        </h2>
        <p class="text-sm text-base-content/70">
          {length(@lessons)} lessons across {length(LuaSandbox.chapters())} chapters.
          Every snippet runs live on the BEAM.
        </p>
      </div>

      <%= for {{chapter_slug, chapter_title}, chapter_idx} <- Enum.with_index(LuaSandbox.chapters()) do %>
        <div class="mb-5">
          <div class="px-3 pb-1.5 text-[11px] uppercase tracking-[0.14em] text-base-content/40 font-semibold">
            <span class="text-base-content/30">{roman(chapter_idx + 1)}.</span>
            &nbsp;{chapter_title}
          </div>
          <ol class="space-y-1">
            <%= for lesson <- @lessons, lesson.chapter == chapter_slug do %>
              <li>
                <.link
                  patch={~p"/tour/#{lesson.slug}"}
                  class={[
                    "flex items-center gap-3 px-3 py-1.5 rounded-box transition-colors",
                    @lesson.slug == lesson.slug && "bg-primary/10 text-primary",
                    @lesson.slug != lesson.slug && "hover:bg-base-200 text-base-content/80"
                  ]}
                >
                  <span class={[
                    "size-6 rounded-full text-xs font-mono flex items-center justify-center shrink-0",
                    @lesson.slug == lesson.slug && "bg-primary text-primary-content",
                    @lesson.slug != lesson.slug && "bg-base-300 text-base-content/60"
                  ]}>
                    {lesson_index(@lessons, lesson) + 1}
                  </span>
                  <span class="text-sm font-medium">
                    {raw(render_inline(lesson.title))}
                  </span>
                </.link>
              </li>
            <% end %>
          </ol>
        </div>
      <% end %>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:tour}>
      <div class="mx-auto max-w-7xl px-4 sm:px-6 lg:px-8 py-8">
        <div class="grid lg:grid-cols-[280px_1fr] gap-8">
          <aside class="lg:sticky lg:top-20 lg:self-start">
            <details class="disclosure group lg:hidden [&[open]>summary>.tour-chevron]:rotate-180">
              <summary class="flex items-center justify-between gap-3 px-3 py-2.5 mb-3 rounded-box border border-base-300/60 bg-base-200/50 cursor-pointer list-none [&::-webkit-details-marker]:hidden">
                <span class="min-w-0 flex-1">
                  <span class="block text-[11px] uppercase tracking-[0.12em] font-semibold text-base-content/60">
                    Chapter {chapter_label(@lesson.chapter)} · Lesson {lesson_index(
                      @lessons,
                      @lesson
                    ) + 1} of {length(@lessons)}
                  </span>
                  <span class="block text-sm font-medium text-base-content/90 line-clamp-2">
                    {raw(render_inline(@lesson.title))}
                  </span>
                </span>
                <.icon
                  name="hero-chevron-down-micro"
                  class="tour-chevron size-4 text-base-content/50 transition-transform shrink-0"
                />
              </summary>

              <.nav_body lessons={@lessons} lesson={@lesson} />
            </details>

            <div class="hidden lg:block">
              <.nav_body lessons={@lessons} lesson={@lesson} />
            </div>
          </aside>

          <article class="min-w-0">
            <div class="mb-2 flex items-center gap-2 text-xs font-mono">
              <span class="text-primary/80 font-semibold">
                Chapter {chapter_label(@lesson.chapter)} ·
                <span class="text-base-content/70">
                  {LuaSandbox.chapter_title(@lesson.chapter)}
                </span>
              </span>
              <span class="text-base-content/30">/</span>
              <span class="text-base-content/50">
                Lesson {lesson_index(@lessons, @lesson) + 1} of {length(@lessons)}
              </span>
              <%= if integration?(@lesson) do %>
                <span class="ml-2 inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-[10px] uppercase tracking-wider font-semibold bg-accent/15 text-accent border border-accent/30">
                  <.icon name="hero-arrows-right-left-micro" class="size-3" /> Host integration
                </span>
              <% end %>
            </div>

            <h1 class="text-3xl sm:text-4xl font-bold tracking-tight mb-3">
              {raw(render_inline(@lesson.title))}
            </h1>

            <%= if obj = Map.get(@lesson, :objective) do %>
              <div class="mb-5 flex items-start gap-2.5 rounded-lg border border-primary/30 bg-primary/5 px-4 py-3">
                <.icon name="hero-flag-micro" class="size-4 text-primary shrink-0 mt-0.5" />
                <span class="text-sm text-base-content/85">
                  <span class="text-primary font-semibold">You'll learn:</span> {raw(
                    render_inline(obj)
                  )}
                </span>
              </div>
            <% end %>

            <div class="prose prose-invert prose-sm max-w-none mb-6 text-base-content/80">
              <%= for paragraph <- String.split(@lesson.body, "\n\n") do %>
                <p>{raw(render_inline(paragraph))}</p>
              <% end %>
            </div>

            <%= if elixir = Map.get(@lesson, :elixir_source) do %>
              <div class="rounded-box border border-accent/30 bg-base-200/40 overflow-hidden mb-3">
                <div class="flex items-center justify-between px-4 py-2 border-b border-accent/20 bg-accent/5">
                  <div class="text-sm font-mono text-accent font-semibold flex items-center gap-2">
                    <.icon name="hero-cube-micro" class="size-3.5" /> Elixir &middot; your app
                  </div>
                  <span class="text-[10px] uppercase tracking-wider text-base-content/40 font-semibold">
                    Reference only
                  </span>
                </div>
                <pre class="highlight p-4 font-mono text-[13px] leading-6 overflow-x-auto"><code>{DemoWeb.Highlight.to_html(elixir, :elixir)}</code></pre>
              </div>
            <% end %>

            <%= if has_editor?(@lesson) do %>
              <%= unless runnable?(@lesson) do %>
                <div class="mb-3 flex items-start gap-2.5 rounded-lg border border-warning/40 bg-warning/5 px-4 py-3">
                  <.icon
                    name="hero-information-circle-micro"
                    class="size-4 text-warning shrink-0 mt-0.5"
                  />
                  <span class="text-sm text-base-content/85">
                    <span class="text-warning font-semibold">Read-only:</span>
                    this snippet uses canonical Lua features that aren't implemented in Lua.ex yet. It's here as a reference.
                  </span>
                </div>
              <% end %>

              <div class="rounded-box border border-base-300/60 bg-base-200/50 overflow-hidden mb-3">
                <form
                  phx-submit="run"
                  phx-change="source-changed"
                  class="contents"
                >
                  <div class="flex items-center justify-between px-4 py-2 border-b border-base-300/60 bg-base-300/30">
                    <div class="text-sm font-mono text-base-content/70 font-semibold flex items-center gap-2">
                      <%= if integration?(@lesson) do %>
                        <.icon name="hero-bolt-micro" class="size-3.5 text-primary" />
                      <% end %>
                      {@lesson.slug}.lua
                    </div>
                    <div class="flex items-center gap-2">
                      <%= if runnable?(@lesson) do %>
                        <button
                          type="button"
                          class={[
                            "btn btn-xs",
                            @show_bytecode && "btn-primary",
                            !@show_bytecode && "btn-ghost border border-base-300/60"
                          ]}
                          phx-click="toggle-bytecode"
                        >
                          <.icon name="hero-code-bracket-square-micro" class="size-3.5" /> Bytecode
                        </button>
                        <button
                          type="button"
                          class="btn btn-xs btn-ghost border border-base-300/60"
                          phx-click="reset"
                        >
                          <.icon name="hero-arrow-uturn-left-micro" class="size-3.5" /> Reset
                        </button>
                        <button
                          type="submit"
                          class={["btn btn-xs btn-primary", @running && "btn-disabled"]}
                        >
                          <%= if @running do %>
                            <span class="loading loading-spinner loading-xs" />
                          <% else %>
                            <.icon name="hero-play-micro" class="size-3.5" /> Run
                          <% end %>
                        </button>
                      <% end %>
                    </div>
                  </div>
                  <div
                    id={"tour-editor-#{@lesson.slug}"}
                    phx-hook="LuaEditor"
                    phx-update="ignore"
                    class="relative h-[260px] overflow-hidden"
                  >
                    <textarea
                      name="source"
                      spellcheck="false"
                      autocomplete="off"
                      readonly={!runnable?(@lesson)}
                      class={[
                        "w-full h-full font-mono text-sm leading-6 p-4 bg-transparent resize-none focus:outline-none",
                        !runnable?(@lesson) && "cursor-default"
                      ]}
                    ><%= @source %></textarea>
                  </div>
                </form>
              </div>

              <%= if runnable?(@lesson) do %>
                <.tour_output result={@result} running={@running} />
              <% end %>
            <% end %>

            <%= if ex = Map.get(@lesson, :exercise) do %>
              <div class="mt-4 flex items-start gap-2.5 rounded-lg border border-accent/30 bg-accent/5 px-4 py-3">
                <.icon name="hero-beaker-micro" class="size-4 text-accent shrink-0 mt-0.5" />
                <div class="text-sm text-base-content/85">
                  <span class="text-accent font-semibold">Try it:</span>
                  {raw(render_inline(ex))}
                </div>
              </div>
            <% end %>

            <%= if @show_bytecode and has_editor?(@lesson) and runnable?(@lesson) do %>
              <.tour_bytecode source={@source} result={@result} />
            <% end %>

            <%= if (refs = Map.get(@lesson, :see_also)) && refs != [] do %>
              <div class="mt-6 flex flex-wrap items-center gap-2">
                <span class="text-[11px] uppercase tracking-[0.14em] text-base-content/40 font-semibold">
                  See also
                </span>
                <%= for slug <- refs, target = lesson_by_slug(@lessons, slug), target != nil do %>
                  <.link
                    patch={~p"/tour/#{target.slug}"}
                    class="inline-flex items-center gap-1 px-2.5 py-1 rounded-full text-xs bg-base-200 hover:bg-base-300/70 border border-base-300/60 text-base-content/80"
                  >
                    {target.title}
                  </.link>
                <% end %>
              </div>
            <% end %>

            <div class="mt-8 flex items-center justify-between gap-3">
              <%= if prev = prev_lesson(@lessons, @lesson) do %>
                <.link patch={~p"/tour/#{prev.slug}"} class="btn btn-ghost">
                  <.icon name="hero-arrow-left-micro" class="size-4" /> {prev.title}
                </.link>
              <% else %>
                <.link navigate={~p"/playground"} class="btn btn-ghost">
                  <.icon name="hero-arrow-left-micro" class="size-4" /> Playground
                </.link>
              <% end %>

              <%= if nxt = next_lesson(@lessons, @lesson) do %>
                <.link patch={~p"/tour/#{nxt.slug}"} class="btn btn-primary">
                  {nxt.title} <.icon name="hero-arrow-right-micro" class="size-4" />
                </.link>
              <% else %>
                <.link navigate={~p"/playground"} class="btn btn-primary">
                  Open the full playground <.icon name="hero-arrow-right-micro" class="size-4" />
                </.link>
              <% end %>
            </div>
          </article>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :result, :map, default: nil
  attr :running, :boolean, required: true

  defp tour_output(assigns) do
    ~H"""
    <div class="rounded-box border border-base-300/60 bg-base-200/30 overflow-hidden">
      <div class="px-4 py-2 border-b border-base-300/60 bg-base-300/20 flex items-center justify-between">
        <span class="text-xs uppercase tracking-wider text-base-content/50 font-semibold">
          Output
        </span>
        <span class="text-xs font-mono text-base-content/50">
          <%= cond do %>
            <% @running -> %>
              <span class="text-primary">running…</span>
            <% match?(%{status: :ok}, @result) -> %>
              <span class="text-success">
                ok &middot; {format_us(@result.duration_us)}
              </span>
            <% match?(%{status: :error}, @result) -> %>
              <span class="text-error">
                error &middot; {format_us(@result.duration_us)}
              </span>
            <% true -> %>
              <span class="text-base-content/40">idle</span>
          <% end %>
        </span>
      </div>
      <div class="p-4 font-mono text-sm min-h-[80px]">
        <%= cond do %>
          <% @running -> %>
            <span class="text-base-content/50">…</span>
          <% match?(%{status: :error}, @result) -> %>
            <pre class="whitespace-pre-wrap text-error/90"><%= @result.error %></pre>
          <% match?(%{status: :ok}, @result) -> %>
            <%= if @result.output != "" do %>
              <pre class="whitespace-pre-wrap"><%= @result.output %></pre>
            <% end %>
            <%= if @result.returns != [] do %>
              <div class={[
                "text-primary",
                @result.output != "" && "border-t border-base-300/40 mt-2 pt-2"
              ]}>
                → {Enum.join(@result.returns, ", ")}
              </div>
            <% end %>
            <%= if @result.output == "" and @result.returns == [] do %>
              <span class="text-base-content/40">(no output)</span>
            <% end %>
          <% true -> %>
            <span class="text-base-content/40">Hit Run to execute.</span>
        <% end %>
      </div>
    </div>
    """
  end

  attr :source, :string, required: true
  attr :result, :map, default: nil

  defp tour_bytecode(assigns) do
    blocks =
      cond do
        match?(%{bytecode: [_ | _]}, assigns.result) ->
          assigns.result.bytecode

        true ->
          case LuaSandbox.compile(assigns.source) do
            {:ok, _, bs} -> bs
            _ -> []
          end
      end

    assigns = assign(assigns, :blocks, blocks)

    ~H"""
    <div class="mt-3 rounded-box border border-base-300/60 bg-base-200/30 overflow-hidden">
      <div class="px-4 py-2 border-b border-base-300/60 bg-base-300/20 text-xs uppercase tracking-wider text-base-content/50 font-semibold">
        Compiled bytecode
      </div>
      <div class="font-mono text-xs leading-5 max-h-[400px] overflow-auto p-2">
        <%= for block <- @blocks do %>
          <div class="px-3 py-1 text-base-content/60 italic">
            ; {block.name} · registers={block.max_registers} · upvalues={block.upvalue_count}
          </div>
          <%= for ins <- block.instructions do %>
            <div class={[
              "flex gap-2 px-3 py-0.5",
              ins.op == :source_line && "text-base-content/40 italic"
            ]}>
              <span class="text-base-content/40 w-8 text-right">{ins.pc}</span>
              <span class="text-base-content/90">{ins.pretty}</span>
            </div>
          <% end %>
        <% end %>
        <%= if @blocks == [] do %>
          <div class="px-3 py-2 text-base-content/50 italic">
            Run the snippet to see bytecode.
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp format_us(us) when is_integer(us) and us < 1_000, do: "#{us} µs"

  defp format_us(us) when is_integer(us) and us < 1_000_000,
    do: "#{Float.round(us / 1_000, 2)} ms"

  defp format_us(us) when is_integer(us), do: "#{Float.round(us / 1_000_000, 3)} s"

  defp roman(1), do: "I"
  defp roman(2), do: "II"
  defp roman(3), do: "III"
  defp roman(4), do: "IV"
  defp roman(5), do: "V"
  defp roman(n), do: Integer.to_string(n)

  defp chapter_label(chapter) do
    case Enum.find_index(LuaSandbox.chapters(), fn {slug, _} -> slug == chapter end) do
      nil -> "?"
      idx -> roman(idx + 1)
    end
  end

  # Markdown-lite for lesson body / objective / exercise text:
  #   `code` → styled inline code
  #   [text](url) → anchor (external links open a new tab)
  defp render_inline(text) do
    text =
      Regex.replace(~r/\[([^\]]+)\]\(([^)]+)\)/, text, fn _full, anchor, url ->
        link_html(anchor, url)
      end)

    Regex.replace(~r/`([^`]+)`/, text, fn _full, code ->
      ~s|<code class="text-primary bg-base-300/40 px-1 rounded">#{code}</code>|
    end)
  end

  defp link_html(text, "http" <> _ = url) do
    ~s|<a href="#{url}" class="text-primary underline decoration-primary/30 hover:decoration-primary" target="_blank" rel="noopener noreferrer">#{text}</a>|
  end

  defp link_html(text, url) do
    ~s|<a href="#{url}" class="text-primary underline decoration-primary/30 hover:decoration-primary">#{text}</a>|
  end
end

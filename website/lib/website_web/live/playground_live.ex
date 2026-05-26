defmodule DemoWeb.PlaygroundLive do
  use DemoWeb, :live_view

  import DemoWeb.BytecodeComponents
  alias Website.LuaSandbox

  @max_shared_bytes 20_000
  @lua_timeout_ms 1_500

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Playground")
      |> assign(:examples, LuaSandbox.examples())
      |> assign(:active_example, "hello")
      |> assign(:source, default_source("hello"))
      |> assign(:blocks, LuaSandbox.example_blocks("hello"))
      |> assign(:result, nil)
      |> assign(:running, false)
      |> assign(:show_bytecode, true)
      |> assign(:selected_block, 0)
      |> assign(:shared_source?, false)
      |> assign(:lua_timer_ref, nil)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    cond do
      Map.has_key?(params, "example") ->
        id = params["example"]

        cond do
          not Enum.any?(LuaSandbox.examples(), &(&1.id == id)) ->
            {:noreply,
             socket
             |> put_flash(:error, "No example named \"#{id}\". Showing the default.")
             |> push_patch(to: ~p"/playground")}

          socket.assigns.active_example == id ->
            {:noreply, socket}

          true ->
            source = default_source(id)

            {:noreply,
             socket
             |> assign(:active_example, id)
             |> assign(:source, source)
             |> assign(:blocks, LuaSandbox.example_blocks(id))
             |> assign(:result, nil)
             |> assign(:selected_block, 0)
             |> assign(:shared_source?, false)
             |> push_event("lua-editor:set-source", %{source: source, example_id: id})}
        end

      Map.has_key?(params, "source") ->
        case decode_shared_source(params["source"]) do
          {:ok, source} ->
            {:noreply,
             socket
             |> assign(:active_example, nil)
             |> assign(:source, source)
             |> assign(:blocks, compile_blocks(source))
             |> assign(:result, nil)
             |> assign(:selected_block, 0)
             |> assign(:shared_source?, true)
             |> push_event("lua-editor:set-source", %{source: source, example_id: nil})}

          :error ->
            {:noreply,
             socket
             |> put_flash(:error, "That shared link is invalid or expired.")
             |> push_patch(to: ~p"/playground")}
        end

      true ->
        {:noreply, push_patch(socket, to: ~p"/playground/#{default_example_id()}", replace: true)}
    end
  end

  defp decode_shared_source(encoded) when is_binary(encoded) do
    with {:ok, gzipped} <- Base.url_decode64(encoded, padding: false),
         {:ok, source} <- safe_gunzip(gzipped),
         true <- byte_size(source) <= @max_shared_bytes do
      {:ok, source}
    else
      _ -> :error
    end
  end

  defp decode_shared_source(_), do: :error

  defp safe_gunzip(bin) do
    {:ok, :zlib.gunzip(bin)}
  rescue
    _ -> :error
  catch
    _, _ -> :error
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
     |> assign(:blocks, LuaSandbox.example_blocks(id))
     |> assign(:result, nil)
     |> assign(:selected_block, 0)
     |> push_event("lua-editor:set-source", %{source: source, example_id: id})
     |> push_patch(to: ~p"/playground/#{id}")}
  end

  def handle_event("run", %{"source" => source}, socket) do
    {:noreply, start_lua_run(socket, source)}
  end

  def handle_event("toggle-bytecode", _, socket) do
    {:noreply, update(socket, :show_bytecode, &(!&1))}
  end

  def handle_event("select-block", %{"index" => idx}, socket) when is_binary(idx) do
    {:noreply, assign(socket, :selected_block, String.to_integer(idx))}
  end

  def handle_event("reset", _params, %{assigns: %{active_example: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("reset", _params, socket) do
    id = socket.assigns.active_example
    source = default_source(id)

    {:noreply,
     socket
     |> assign(:source, source)
     |> assign(:blocks, LuaSandbox.example_blocks(id))
     |> assign(:result, nil)
     |> assign(:selected_block, 0)
     |> push_event("lua-editor:set-source", %{
       source: source,
       example_id: id,
       clear_storage: true
     })}
  end

  @impl true
  def handle_async(:lua_run, {:ok, result}, socket) do
    socket =
      socket
      |> finish_lua_run()
      |> assign(:result, result)
      |> assign(:selected_block, 0)

    socket =
      case result do
        %{bytecode: [_ | _] = bs} -> assign(socket, :blocks, bs)
        _ -> socket
      end

    {:noreply, socket}
  end

  def handle_async(:lua_run, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> finish_lua_run()
     |> assign(:result, timeout_result())}
  end

  @impl true
  def handle_info(:lua_timeout, %{assigns: %{running: true}} = socket) do
    {:noreply, cancel_async(socket, :lua_run)}
  end

  def handle_info(:lua_timeout, socket), do: {:noreply, socket}

  defp start_lua_run(socket, source) do
    socket
    |> cancel_lua_run()
    |> assign(:source, source)
    |> assign(:running, true)
    |> assign(:lua_timer_ref, Process.send_after(self(), :lua_timeout, @lua_timeout_ms))
    |> start_async(:lua_run, fn -> LuaSandbox.run(source) end)
  end

  defp cancel_lua_run(socket) do
    if ref = socket.assigns[:lua_timer_ref], do: Process.cancel_timer(ref)

    socket
    |> cancel_async(:lua_run)
    |> assign(:lua_timer_ref, nil)
  end

  defp finish_lua_run(socket) do
    if ref = socket.assigns[:lua_timer_ref], do: Process.cancel_timer(ref)

    socket
    |> assign(:running, false)
    |> assign(:lua_timer_ref, nil)
  end

  defp timeout_result do
    %{
      status: :timeout,
      output: "",
      returns: [],
      error: "Execution timed out after #{@lua_timeout_ms}ms",
      duration_us: @lua_timeout_ms * 1_000,
      bytecode: []
    }
  end

  defp default_source(id) do
    case Enum.find(LuaSandbox.examples(), &(&1.id == id)) do
      nil -> hd(LuaSandbox.examples()).source
      ex -> ex.source
    end
  end

  defp default_example_id, do: hd(LuaSandbox.examples()).id

  defp active_blurb(examples, active_id) do
    case Enum.find(examples, &(&1.id == active_id)) do
      %{blurb: blurb} when is_binary(blurb) and blurb != "" -> blurb
      _ -> nil
    end
  end

  defp has_copyable_output?(%{status: :ok, output: out, returns: rets})
       when out != "" or rets != [],
       do: true

  defp has_copyable_output?(%{status: :error}), do: true
  defp has_copyable_output?(_), do: false

  defp empty_source?(nil), do: true
  defp empty_source?(""), do: true
  defp empty_source?(source) when is_binary(source), do: String.trim(source) == ""
  defp empty_source?(_), do: false

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
              this VM actually executes. No JavaScript Lua. Every byte is Elixir.
            </p>
          </div>
          <div class="flex items-center gap-2">
            <button
              class={["btn btn-ghost btn-sm", is_nil(@active_example) && "btn-disabled"]}
              phx-click="reset"
              disabled={is_nil(@active_example)}
              title={
                if is_nil(@active_example),
                  do: "Pick an example to reset to.",
                  else: "Restore this example's original source."
              }
            >
              <.icon name="hero-arrow-uturn-left-micro" class="size-4" /> Reset
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

        <div class="flex gap-2 overflow-x-auto pb-3 -mx-1 px-1 mb-3 scrollbar-thin">
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

        <%= if blurb = active_blurb(@examples, @active_example) do %>
          <div class="mb-4 flex items-start gap-2.5 text-sm text-base-content/70 bg-base-200/40 border border-base-300/40 rounded-lg px-3.5 py-2.5">
            <.icon name="hero-light-bulb-micro" class="size-4 text-accent shrink-0 mt-0.5" />
            <span>{raw(blurb)}</span>
          </div>
        <% end %>

        <div class={[
          "grid gap-4",
          @show_bytecode && "lg:grid-cols-[1.1fr_1fr]",
          !@show_bytecode && "grid-cols-1"
        ]}>
          <div class="flex flex-col gap-4 min-w-0">
            <.editor_panel source={@source} running={@running} active_example={@active_example} />
            <.output_panel result={@result} running={@running} />
          </div>

          <%= if @show_bytecode do %>
            <.playground_bytecode blocks={@blocks} selected={@selected_block} />
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
            <:label><span class="whitespace-nowrap">Heads-up</span></:label>
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
  attr :active_example, :string, default: nil

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
        <div class="flex items-center gap-2">
          <button
            type="button"
            id="share-btn"
            phx-hook="ShareSnippet"
            class="btn btn-xs btn-ghost border border-base-300/60"
            aria-label="Copy a shareable URL for this snippet"
          >
            <.icon name="hero-link-micro" class="size-3.5" />
            <span data-share-label>Share</span>
          </button>
          <button
            type="submit"
            class={[
              "btn btn-sm btn-primary shadow-sm",
              (@running or empty_source?(@source)) && "btn-disabled"
            ]}
            disabled={@running or empty_source?(@source)}
            title={if empty_source?(@source), do: "Write some Lua first.", else: nil}
          >
            <%= if @running do %>
              <span class="loading loading-spinner loading-xs" /> Running
            <% else %>
              <.icon name="hero-play-micro" class="size-4" /> Run
            <% end %>
          </button>
        </div>
      </div>
      <div
        id="editor-wrap"
        phx-hook="LuaEditor"
        phx-update="ignore"
        data-storage-key="playground:source"
        data-example-id={@active_example || ""}
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
        <div class="flex items-center gap-3 text-xs font-mono text-base-content/50">
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
          <%= if has_copyable_output?(@result) do %>
            <button
              id="copy-output"
              phx-hook="CopyButton"
              data-copy-target="#output-body"
              class="btn btn-ghost btn-xs gap-1 normal-case"
              aria-label="Copy output"
            >
              <.icon name="hero-clipboard-document-micro" class="size-3.5" />
              <span data-copy-label>Copy</span>
            </button>
          <% end %>
        </div>
      </div>
      <div id="output-body" class="p-4 font-mono text-sm space-y-2 min-h-[140px]">
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

  attr :blocks, :list, required: true
  attr :selected, :integer, required: true

  defp playground_bytecode(assigns) do
    ~H"""
    <div class="lg:sticky lg:top-20 self-start">
      <.bytecode_panel
        blocks={@blocks}
        selected={@selected}
        variant={:full}
        max_height="max-h-[520px]"
      />
    </div>
    """
  end

  defp compile_blocks(source) do
    case LuaSandbox.compile(source) do
      {:ok, _chunk, blocks} -> blocks
      {:error, _} -> []
    end
  end

  defp format_us(us) when us < 1_000, do: "#{us} µs"
  defp format_us(us) when us < 1_000_000, do: "#{Float.round(us / 1_000, 2)} ms"
  defp format_us(us), do: "#{Float.round(us / 1_000_000, 3)} s"
end

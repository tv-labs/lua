defmodule DemoWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use DemoWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  slot :inner_block, required: true

  attr :active, :atom, default: nil

  def app(assigns) do
    ~H"""
    <.site_nav active={@active} />
    <main>
      {render_slot(@inner_block)}
    </main>
    <.site_footer />
    <.flash_group flash={@flash} />
    """
  end

  attr :active, :atom, default: nil

  def site_nav(assigns) do
    ~H"""
    <header class="sticky top-0 z-30 backdrop-blur-md bg-base-100/70 border-b border-base-300/60">
      <div class="mx-auto max-w-7xl px-4 sm:px-6 lg:px-8 h-16 flex items-center gap-6">
        <a href="/" class="flex items-center gap-2.5 group">
          <.lua_mark class="h-8 w-8 transition-transform group-hover:rotate-12" />
          <span class="font-semibold tracking-tight text-lg">
            Lua<span class="text-primary">.ex</span>
          </span>
        </a>

        <nav class="hidden md:flex items-center gap-1 ml-4">
          <.nav_link href="/playground" active={@active == :playground}>Playground</.nav_link>
          <.nav_link href="/tour" active={@active == :tour}>Tour</.nav_link>
          <.nav_link href="/reference/opcodes" active={@active == :opcodes}>Opcodes</.nav_link>
          <.nav_link href="/about" active={@active == :about}>About</.nav_link>
          <a
            href="https://hexdocs.pm/lua"
            target="_blank"
            class="btn btn-ghost btn-sm font-medium"
          >
            Docs
          </a>
        </nav>

        <div class="flex-1" />

        <a
          href="https://github.com/tv-labs/lua"
          target="_blank"
          class="btn btn-ghost btn-sm font-medium hidden sm:inline-flex"
        >
          <svg viewBox="0 0 24 24" class="size-4 fill-current" aria-hidden="true">
            <path
              fill-rule="evenodd"
              clip-rule="evenodd"
              d="M12 0C5.37 0 0 5.506 0 12.303c0 5.445 3.435 10.043 8.205 11.674.6.107.825-.262.825-.585 0-.292-.015-1.261-.015-2.291C6 21.67 5.22 20.346 4.98 19.654c-.135-.354-.72-1.446-1.23-1.738-.42-.23-1.02-.8-.015-.815.945-.015 1.62.892 1.845 1.261 1.08 1.86 2.805 1.338 3.495 1.015.105-.8.42-1.338.765-1.645-2.67-.308-5.46-1.37-5.46-6.075 0-1.338.465-2.446 1.23-3.307-.12-.308-.54-1.569.12-3.26 0 0 1.005-.323 3.3 1.26.96-.276 1.98-.415 3-.415s2.04.139 3 .416c2.295-1.6 3.3-1.261 3.3-1.261.66 1.691.24 2.952.12 3.26.765.861 1.23 1.953 1.23 3.307 0 4.721-2.805 5.767-5.475 6.075.435.384.81 1.122.81 2.276 0 1.645-.015 2.968-.015 3.383 0 .323.225.707.825.585a12.047 12.047 0 0 0 5.919-4.489A12.536 12.536 0 0 0 24 12.304C24 5.505 18.63 0 12 0Z"
            />
          </svg>
          GitHub
        </a>
        <.theme_toggle />
        <a href="/playground" class="btn btn-primary btn-sm shadow-sm">
          Try it <.icon name="hero-arrow-right-micro" class="size-4" />
        </a>
      </div>
    </header>
    """
  end

  attr :href, :string, required: true
  attr :active, :boolean, default: false
  slot :inner_block, required: true

  def nav_link(assigns) do
    ~H"""
    <.link
      navigate={@href}
      class={[
        "btn btn-ghost btn-sm font-medium",
        @active && "text-primary bg-primary/10"
      ]}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  def site_footer(assigns) do
    ~H"""
    <footer class="border-t border-base-300/60 mt-24 pt-12 pb-8 px-4 sm:px-6 lg:px-8">
      <div class="mx-auto max-w-7xl">
        <div class="grid grid-cols-2 sm:grid-cols-4 gap-8 mb-10">
          <div class="col-span-2 sm:col-span-1">
            <div class="flex items-center gap-2 mb-3">
              <.lua_mark class="h-6 w-6" />
              <span class="font-semibold tracking-tight">
                Lua<span class="text-primary">.ex</span>
              </span>
            </div>
            <p class="text-sm text-base-content/60 leading-relaxed">
              An Elixir-native Lua 5.3 VM. Scriptable, sandboxed, agent-ready.
            </p>
          </div>

          <div>
            <h4 class="text-xs font-bold uppercase tracking-wider text-base-content/50 mb-3">
              Product
            </h4>
            <ul class="space-y-2 text-sm">
              <li>
                <.link navigate={~p"/playground"} class="text-base-content/70 hover:text-primary">
                  Playground
                </.link>
              </li>
              <li>
                <.link navigate={~p"/tour"} class="text-base-content/70 hover:text-primary">
                  Tour
                </.link>
              </li>
              <li>
                <.link
                  navigate={~p"/reference/opcodes"}
                  class="text-base-content/70 hover:text-primary"
                >
                  Opcode reference
                </.link>
              </li>
              <li>
                <.link navigate={~p"/about"} class="text-base-content/70 hover:text-primary">
                  About
                </.link>
              </li>
            </ul>
          </div>

          <div>
            <h4 class="text-xs font-bold uppercase tracking-wider text-base-content/50 mb-3">
              Resources
            </h4>
            <ul class="space-y-2 text-sm">
              <li>
                <a
                  href="https://hexdocs.pm/lua"
                  target="_blank"
                  class="text-base-content/70 hover:text-primary"
                >
                  HexDocs
                </a>
              </li>
              <li>
                <a
                  href="https://hex.pm/packages/lua"
                  target="_blank"
                  class="text-base-content/70 hover:text-primary"
                >
                  Hex.pm
                </a>
              </li>
              <li>
                <a
                  href="https://github.com/tv-labs/lua/blob/main/CHANGELOG.md"
                  target="_blank"
                  class="text-base-content/70 hover:text-primary"
                >
                  Changelog
                </a>
              </li>
              <li>
                <a
                  href="https://github.com/tv-labs/lua/blob/main/ROADMAP.md"
                  target="_blank"
                  class="text-base-content/70 hover:text-primary"
                >
                  Roadmap
                </a>
              </li>
            </ul>
          </div>

          <div>
            <h4 class="text-xs font-bold uppercase tracking-wider text-base-content/50 mb-3">
              Community
            </h4>
            <ul class="space-y-2 text-sm">
              <li>
                <a
                  href="https://github.com/tv-labs/lua"
                  target="_blank"
                  class="text-base-content/70 hover:text-primary"
                >
                  GitHub
                </a>
              </li>
              <li>
                <a
                  href="https://github.com/tv-labs/lua/issues"
                  target="_blank"
                  class="text-base-content/70 hover:text-primary"
                >
                  Report an issue
                </a>
              </li>
              <li>
                <a
                  href="https://elixirforum.com/"
                  target="_blank"
                  class="text-base-content/70 hover:text-primary"
                >
                  Elixir Forum
                </a>
              </li>
            </ul>
          </div>
        </div>

        <div class="pt-6 border-t border-base-300/40 flex flex-col sm:flex-row items-center justify-between gap-3 text-xs text-base-content/50">
          <span>
            Built at
            <a
              href="https://tvlabs.ai"
              target="_blank"
              class="link link-hover text-base-content/70"
            >
              TV Labs
            </a>
            &middot; standing on the shoulders of
            <a
              href="https://github.com/rvirding/luerl"
              target="_blank"
              class="link link-hover text-base-content/70"
            >
              Luerl
            </a>
            and three decades of Lua.
          </span>
          <span>MIT licensed</span>
        </div>
      </div>
    </footer>
    """
  end

  attr :class, :string, default: ""

  def lua_mark(assigns) do
    ~H"""
    <svg viewBox="0 0 64 64" class={@class} aria-hidden="true">
      <defs>
        <linearGradient id="lua-mark-grad-sm" x1="0" x2="1" y1="0" y2="1">
          <stop offset="0%" stop-color="var(--lua-drop-from)" />
          <stop offset="100%" stop-color="var(--lua-drop-to)" />
        </linearGradient>
        <mask id="lua-crescent-mask-sm">
          <rect width="64" height="64" fill="white" />
          <circle cx="42" cy="28" r="14" fill="black" />
        </mask>
      </defs>
      <path
        d="M 32 4 Q 12 24 12 36 A 20 20 0 0 0 52 36 Q 52 24 32 4 Z"
        fill="url(#lua-mark-grad-sm)"
        mask="url(#lua-crescent-mask-sm)"
      />
      <circle cx="52" cy="12" r="3.25" fill="var(--lua-satellite)" />
    </svg>
    """
  end

  attr :class, :string, default: ""

  @doc """
  TV Labs wordmark (brand mark + "tv labs" lockup). Color inherits from `currentColor`.
  """
  def tvlabs_wordmark(assigns) do
    ~H"""
    <svg
      viewBox="0 0 1001 258"
      class={["fill-current", @class]}
      aria-label="TV Labs"
      role="img"
    >
      <path d="M197.549 58.9141C175.821 59.0587 154.963 60.2734 134.744 62.298L144.346 2.86329L133.526 0L110.289 65.1902C98.6855 66.7809 87.3429 68.6897 76.2034 70.8589L36.6929 36.9623L28.2513 42.6599L52.909 75.8913C34.8073 80.1718 17.2278 85.1174 0.228433 90.844C-1.71518 166.562 8.90215 217.117 26.0466 254.6C93.899 263.624 159.344 254.716 222.294 227.5C221.191 137.958 212.227 85.1464 197.549 58.9141ZM195.547 195.975C159.46 215.989 118.934 223.885 74.3758 220.848C64.5707 195.339 59.4651 160.604 60.0453 114.878C98.0763 100.301 138.515 94.0832 181.884 98.0166C192.443 130.438 196.91 163.091 195.547 195.975Z" />
      <path d="M156.907 111.147C151.743 111.986 147.769 118.031 145.854 126.649C145.796 126.649 145.767 126.649 145.738 126.649C143.185 135.037 138.486 140.908 132.568 141.862C127.404 142.672 122.299 139.606 118.209 133.967C117.715 133.186 109.912 119.911 98.9755 122.224C86.7917 124.827 78.6691 142.412 81.0189 162.918C83.3686 183.452 95.1463 197.971 107.446 196.525C123.604 194.645 121.197 164.248 137.558 161.211C142.924 160.228 148.233 163.67 152.439 169.627C155.92 175.036 160.214 178.044 164.478 177.35C173.123 175.961 178.461 160.025 176.372 141.747C174.254 123.468 165.552 109.759 156.907 111.147Z" />
      <path d="M571.999 81.7625H538.087V229.091H648.757V199.793H571.999V81.7625Z" />
      <path d="M742.747 138.334H742.283C735.408 128.356 723.253 122.571 707.443 122.571C676.983 122.571 654.733 145.42 654.733 176.945C654.733 208.441 676.954 231.318 707.443 231.318C723.485 231.318 735.407 225.331 742.515 215.122H742.979L743.907 229.091H768.884V124.827H743.907L742.747 138.334ZM712.519 205.578C696.245 205.578 685.019 193.806 685.019 176.945C685.019 160.083 696.245 148.312 712.519 148.312C728.561 148.312 739.788 160.083 739.788 176.945C739.788 193.806 728.561 205.578 712.519 205.578Z" />
      <path d="M850.98 122.6C837.694 122.6 827.164 126.592 819.824 133.909H819.36V73.78H789.336V229.091H814.312L815.444 215.324H815.908C822.783 225.302 835.141 231.289 850.951 231.289C881.411 231.289 903.661 208.441 903.661 176.916C903.69 145.449 881.44 122.6 850.98 122.6ZM845.932 205.578C829.658 205.578 818.664 193.806 818.664 176.945C818.664 160.083 829.658 148.312 845.932 148.312C862.439 148.312 873.433 160.083 873.433 176.945C873.433 193.806 862.439 205.578 845.932 205.578Z" />
      <path d="M960.142 163.872C945.927 162.975 942.272 160.98 942.272 156.323C942.272 149.903 948.016 146.577 959.677 146.577C973.66 146.577 984.654 150.134 991.761 157.018H992.893V129.281C984.422 125.059 972.035 122.629 958.981 122.629C931.713 122.629 914.075 136.165 914.075 157.249C914.075 177.87 924.837 185.882 952.106 188.311C967.22 189.642 971.803 191.869 971.803 197.422C971.803 204.074 966.088 207.4 954.398 207.4C937.659 207.4 924.837 202.946 916.367 194.096H915.003V222.063C924.17 228.281 937.92 231.376 955.79 231.376C983.523 231.376 1000 218.737 1000 197.422C1000 175.412 988.774 165.636 960.142 163.872Z" />
      <path d="M443.923 195.368H443.488L395.362 81.7625H395.159H250.694L260.934 106.954H310.742V229.091H341.84V106.954H373.402L426.315 229.091H461.097L523.409 81.7625H490.222L443.923 195.368Z" />
    </svg>
    """
  end

  attr :class, :string, default: ""

  def lua_orbit(assigns) do
    ~H"""
    <svg viewBox="0 0 64 64" class={["overflow-visible", @class]} aria-hidden="true">
      <defs>
        <linearGradient id="lua-mark-grad-lg" x1="0" x2="1" y1="0" y2="1">
          <stop offset="0%" stop-color="var(--lua-drop-from)" />
          <stop offset="100%" stop-color="var(--lua-drop-to)" />
        </linearGradient>
        <mask id="lua-crescent-mask-lg">
          <rect width="64" height="64" fill="white" />
          <circle cx="42" cy="28" r="14" fill="black" />
        </mask>
        <filter id="lua-satellite-glow-lg" x="-200%" y="-200%" width="500%" height="500%">
          <feGaussianBlur stdDeviation="1.2" />
        </filter>
      </defs>
      <circle
        cx="32"
        cy="32"
        r="28.3"
        fill="none"
        stroke="var(--lua-drop-from)"
        stroke-opacity="0.22"
        stroke-width="0.4"
      />
      <path
        d="M 32 4 Q 12 24 12 36 A 20 20 0 0 0 52 36 Q 52 24 32 4 Z"
        fill="url(#lua-mark-grad-lg)"
        mask="url(#lua-crescent-mask-lg)"
      />
      <g class="lua-orbit-satellite">
        <circle
          cx="52"
          cy="12"
          r="6"
          fill="var(--lua-satellite)"
          fill-opacity="0.35"
          filter="url(#lua-satellite-glow-lg)"
        />
        <circle cx="52" cy="12" r="3.25" fill="var(--lua-satellite)" />
      </g>
    </svg>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end

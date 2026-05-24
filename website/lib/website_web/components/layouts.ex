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
          <span class="hidden sm:inline-block badge badge-outline badge-sm font-mono">
            BEAM
          </span>
        </a>

        <nav class="hidden md:flex items-center gap-1 ml-4">
          <.nav_link href="/playground" active={@active == :playground}>Playground</.nav_link>
          <.nav_link href="/tour" active={@active == :tour}>Tour</.nav_link>
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
    <footer class="border-t border-base-300/60 mt-24 py-10 px-4 sm:px-6 lg:px-8">
      <div class="mx-auto max-w-7xl flex flex-col sm:flex-row items-center justify-between gap-4 text-sm text-base-content/60">
        <div class="flex items-center gap-2">
          <.lua_mark class="h-5 w-5 opacity-70" />
          <span>
            <strong class="text-base-content/80">Lua on the BEAM</strong>
            &middot; an Elixir-native Lua 5.3 VM
          </span>
        </div>
        <div class="flex items-center gap-4">
          <a href="https://github.com/tv-labs/lua" class="link link-hover" target="_blank">GitHub</a>
          <a href="https://hexdocs.pm/lua" class="link link-hover" target="_blank">HexDocs</a>
          <a href="https://hex.pm/packages/lua" class="link link-hover" target="_blank">Hex.pm</a>
        </div>
      </div>
    </footer>
    """
  end

  attr :class, :string, default: ""

  def lua_mark(assigns) do
    ~H"""
    <svg viewBox="0 0 32 32" class={@class} aria-hidden="true">
      <defs>
        <linearGradient id="lua-mark-grad" x1="0" x2="1" y1="0" y2="1">
          <stop offset="0%" stop-color="oklch(58% 0.233 277.117)" />
          <stop offset="100%" stop-color="oklch(60% 0.25 292.717)" />
        </linearGradient>
      </defs>
      <circle cx="16" cy="16" r="14" fill="url(#lua-mark-grad)" />
      <circle cx="22" cy="10" r="3" fill="white" fill-opacity="0.95" />
      <text
        x="16"
        y="22"
        text-anchor="middle"
        font-family="ui-monospace, SFMono-Regular, Menlo, monospace"
        font-size="11"
        font-weight="700"
        fill="white"
        fill-opacity="0.95"
      >
        Lua
      </text>
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

defmodule DemoWeb.PageHTML do
  @moduledoc """
  This module contains pages rendered by PageController.

  See the `page_html` directory for all templates available.
  """
  use DemoWeb, :html

  embed_templates "page_html/*"

  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :accent, :string, default: "primary"
  slot :inner_block, required: true

  def feature(assigns) do
    ~H"""
    <div class="group relative rounded-2xl border border-base-300/60 bg-base-200/50 p-6 hover:bg-base-200 hover:border-base-300 transition-colors">
      <div class={[
        "size-10 rounded-xl grid place-items-center mb-4",
        accent_bg(@accent)
      ]}>
        <.icon name={@icon} class={["size-5", accent_text(@accent)]} />
      </div>
      <h3 class="font-semibold text-lg mb-2 tracking-tight">{@title}</h3>
      <div class="text-sm text-base-content/70 leading-relaxed [&_code]:text-primary [&_code]:bg-base-300/40 [&_code]:px-1 [&_code]:rounded">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  defp accent_bg("primary"), do: "bg-primary/15"
  defp accent_bg("secondary"), do: "bg-secondary/15"
  defp accent_bg("accent"), do: "bg-accent/15"
  defp accent_bg("success"), do: "bg-success/15"
  defp accent_bg("info"), do: "bg-info/15"
  defp accent_bg("warning"), do: "bg-warning/15"
  defp accent_bg("error"), do: "bg-error/15"
  defp accent_bg(_), do: "bg-primary/15"

  defp accent_text("primary"), do: "text-primary"
  defp accent_text("secondary"), do: "text-secondary"
  defp accent_text("accent"), do: "text-accent"
  defp accent_text("success"), do: "text-success"
  defp accent_text("info"), do: "text-info"
  defp accent_text("warning"), do: "text-warning"
  defp accent_text("error"), do: "text-error"
  defp accent_text(_), do: "text-primary"
end

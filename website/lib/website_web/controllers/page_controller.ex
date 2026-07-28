defmodule DemoWeb.PageController do
  use DemoWeb, :controller

  alias Website.Benchmarks

  def home(conn, _params) do
    %{source: fib_source} = hd(Website.LuaSandbox.home_snippets())

    render(conn, :home,
      fib_source: fib_source,
      fib_bytecode: compile_bytecode(fib_source),
      lua_version: Website.LuaSandbox.lua_version()
    )
  end

  def about(conn, _params) do
    render(conn, :about, page_title: "About")
  end

  def benchmarks(conn, _params) do
    render(conn, :benchmarks,
      page_title: "Benchmarks",
      versions: Benchmarks.versions(),
      latest: Benchmarks.latest(),
      rows: Benchmarks.rows(),
      chart_rows: Benchmarks.chart_rows(),
      headline: Benchmarks.headline(),
      report: Benchmarks.report(),
      report_date: Benchmarks.report_date()
    )
  end

  def health(conn, _params) do
    send_resp(conn, 200, "ok")
  end

  defp compile_bytecode(source) do
    case Website.LuaSandbox.compile(source) do
      {:ok, _chunk, blocks} -> blocks
      {:error, _} -> []
    end
  end
end

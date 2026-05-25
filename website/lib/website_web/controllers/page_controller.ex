defmodule DemoWeb.PageController do
  use DemoWeb, :controller

  def home(conn, _params) do
    %{source: fib_source} = hd(Website.LuaSandbox.home_snippets())

    render(conn, :home,
      fib_source: fib_source,
      fib_bytecode: compile_bytecode(fib_source)
    )
  end

  def about(conn, _params) do
    render(conn, :about, page_title: "About — Lua.ex")
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

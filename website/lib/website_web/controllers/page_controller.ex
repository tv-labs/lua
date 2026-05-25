defmodule DemoWeb.PageController do
  use DemoWeb, :controller

  @fib_source """
  local function fib(n)
    if n < 2 then return n end
    return fib(n - 1)
         + fib(n - 2)
  end

  return fib(15)
  """

  def home(conn, _params) do
    render(conn, :home,
      fib_source: @fib_source,
      fib_bytecode: compile_bytecode(@fib_source)
    )
  end

  defp compile_bytecode(source) do
    case Website.LuaSandbox.compile(source) do
      {:ok, _chunk, blocks} -> blocks
      {:error, _} -> []
    end
  end
end

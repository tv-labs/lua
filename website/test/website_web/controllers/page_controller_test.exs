defmodule DemoWeb.PageControllerTest do
  use DemoWeb.ConnCase

  test "GET / renders the Lua showcase landing page", %{conn: conn} do
    body = conn |> get(~p"/") |> html_response(200)
    assert body =~ "Lua, on the"
    assert body =~ "Playground"
    assert body =~ "Tour"
  end
end

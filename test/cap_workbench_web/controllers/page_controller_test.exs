defmodule CapWorkbenchWeb.PageControllerTest do
  use CapWorkbenchWeb.ConnCase

  test "GET / redirects to the messages workbench", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == ~p"/messages"
  end
end

defmodule CapWorkbenchWeb.PageController do
  use CapWorkbenchWeb, :controller

  def home(conn, _params) do
    redirect(conn, to: ~p"/messages")
  end
end

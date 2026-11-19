defmodule ObsFactorWeb.PageController do
  use ObsFactorWeb, :controller

  def index(conn, _params), do: ObsFactorWeb.StaticPage.send_page(conn, "index.html")
end

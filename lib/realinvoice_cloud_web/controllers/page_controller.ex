defmodule RealinvoiceCloudWeb.PageController do
  use RealinvoiceCloudWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end

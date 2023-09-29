defmodule Web.RedirectController do
  use Web, :controller

  def home(conn, _params) do
    redirect(conn, external: "https://firezone.dev")
  end
end

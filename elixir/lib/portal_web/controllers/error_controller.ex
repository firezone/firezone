defmodule Web.ErrorController do
  use Web, :controller

  def show(_conn, params) do
    case params["code"] do
      "404" -> raise Web.LiveErrors.NotFoundError
      "500" -> raise "internal server error"
    end

    raise "unknown error"
  end
end

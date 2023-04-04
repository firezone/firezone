defmodule API.Router do
  use API, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", API do
    pipe_through :api
  end
end

defmodule API.Router do
  use API, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/client", API.Client do
    pipe_through :api
  end
end

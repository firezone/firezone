defmodule Web.Router do
  use Web, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, {Web.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
    # TODO: auth
  end

  pipeline :browser_static do
    plug :accepts, ["html", "xml"]
  end

  scope "/", Web do
    pipe_through :browser

    get "/", PageController, :home
  end

  scope "/browser", Web do
    pipe_through :browser_static

    get "/config.xml", BrowserController, :config
  end
end

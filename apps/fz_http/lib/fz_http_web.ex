defmodule FzHttpWeb do
  @moduledoc """
  The entrypoint for defining your web interface, such
  as controllers, views, channels and so on.

  This can be used in your application as:

      use FzHttpWeb, :controller
      use FzHttpWeb, :view

  The definitions below will be executed for every view,
  controller, etc, so keep them short and clean, focused
  on imports, uses and aliases.

  Do NOT define functions inside the quoted expressions
  below. Instead, define any helper function in modules
  and import those modules here.
  """

  def controller do
    quote do
      use Phoenix.Controller, namespace: FzHttpWeb

      import Plug.Conn
      import FzHttpWeb.Gettext
      import Phoenix.LiveView.Controller
      import FzHttpWeb.ControllerHelpers
      import FzHttpWeb.DocHelpers

      unquote(verified_routes())
    end
  end

  def view do
    quote do
      use Phoenix.View,
        root: "lib/fz_http_web/templates",
        namespace: FzHttpWeb

      # Import convenience functions from controllers
      import Phoenix.Controller, only: [view_module: 1]

      # Use all HTML functionality (forms, tags, etc)
      use Phoenix.HTML

      # Use all LiveView functionality
      use Phoenix.Component, global_prefixes: ~w(x-)

      import FzHttpWeb.ErrorHelpers
      import FzHttpWeb.AuthorizationHelpers
      import FzHttpWeb.Gettext
      import FzHttpWeb.LiveHelpers

      unquote(verified_routes())
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView, layout: {FzHttpWeb.LayoutView, :live}
      import FzHttpWeb.LiveHelpers

      alias Phoenix.LiveView.JS

      unquote(view_helpers())
    end
  end

  def live_view_without_layout do
    quote do
      use Phoenix.LiveView, layout: nil
      import FzHttpWeb.LiveHelpers

      alias Phoenix.LiveView.JS

      unquote(view_helpers())
    end
  end

  def live_component do
    quote do
      import Phoenix.LiveView
      use Phoenix.LiveComponent
      use Phoenix.Component, global_prefixes: ~w(x-)
      import FzHttpWeb.LiveHelpers

      unquote(view_helpers())
    end
  end

  def router do
    quote do
      use Phoenix.Router
      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
      import FzHttpWeb.Gettext
    end
  end

  def helper do
    quote do
      unquote(verified_routes())
    end
  end

  defp view_helpers do
    quote do
      # Use all HTML functionality (forms, tags, etc)
      use Phoenix.HTML

      # Import LiveView helpers (live_render, live_component, live_patch, etc)
      import Phoenix.Component

      # Import basic rendering functionality (render, render_layout, etc)
      import Phoenix.View

      # Authorization Helpers
      import FzHttpWeb.AuthorizationHelpers

      import FzHttpWeb.ErrorHelpers
      import FzHttpWeb.Gettext

      unquote(verified_routes())
    end
  end

  def static_paths, do: ~w(dist fonts images uploads robots.txt)

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: FzHttpWeb.Endpoint,
        router: FzHttpWeb.Router,
        statics: FzHttpWeb.static_paths()
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/view/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end

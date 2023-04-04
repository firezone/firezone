defmodule Web do
  @moduledoc """
  The entrypoint for defining your web interface, such
  as controllers, views, channels and so on.

  This can be used in your application as:

      use Web, :controller
      use Web, :view

  The definitions below will be executed for every view,
  controller, etc, so keep them short and clean, focused
  on imports, uses and aliases.

  Do NOT define functions inside the quoted expressions
  below. Instead, define any helper function in modules
  and import those modules here.
  """

  def controller do
    quote do
      use Phoenix.Controller, namespace: Web

      import Plug.Conn
      import Web.Gettext
      import Phoenix.LiveView.Controller
      import Web.ControllerHelpers
      import Web.DocHelpers

      unquote(verified_routes())
    end
  end

  def view do
    quote do
      use Phoenix.View,
        root: "lib/web/templates",
        namespace: Web

      # Import convenience functions from controllers
      import Phoenix.Controller, only: [view_module: 1]

      # Use all HTML functionality (forms, tags, etc)
      use Phoenix.HTML

      # Use all LiveView functionality
      use Phoenix.Component, global_prefixes: ~w(x-)

      import Web.ErrorHelpers
      import Web.AuthorizationHelpers
      import Web.Gettext
      import Web.LiveHelpers

      unquote(verified_routes())
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView, layout: {Web.LayoutView, :live}
      import Web.LiveHelpers

      alias Phoenix.LiveView.JS

      unquote(view_helpers())
    end
  end

  def live_view_without_layout do
    quote do
      use Phoenix.LiveView
      import Web.LiveHelpers

      alias Phoenix.LiveView.JS

      unquote(view_helpers())
    end
  end

  def live_component do
    quote do
      import Phoenix.LiveView
      use Phoenix.LiveComponent
      use Phoenix.Component, global_prefixes: ~w(x-)
      import Web.LiveHelpers

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
      import Web.Gettext
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
      import Web.AuthorizationHelpers

      import Web.ErrorHelpers
      import Web.Gettext

      unquote(verified_routes())
    end
  end

  def static_paths, do: ~w(dist fonts images uploads robots.txt)

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: Web.Endpoint,
        router: Web.Router,
        statics: Web.static_paths()
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/view/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end

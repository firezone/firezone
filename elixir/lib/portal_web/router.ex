defmodule Web.Router do
  use Web, :router

  pipeline :public do
    plug :accepts, ["html", "xml"]
    plug :fetch_session
    plug :protect_from_forgery
    plug :fetch_live_flash
    plug :put_root_layout, html: {Web.Layouts, :root}
    plug :delete_legacy_cookies
  end

  pipeline :dev_tools do
    plug :accepts, ["html"]
    plug :disable_csp
  end

  defp disable_csp(conn, _opts) do
    Plug.Conn.delete_resp_header(conn, "content-security-policy")
  end

  # TODO: Remove after Feb 1, 2027 as these will have expired
  defp delete_legacy_cookies(conn, _opts) do
    # These were the legacy cookie options
    cookie_opts = [
      sign: true,
      max_age: 365 * 24 * 60 * 60,
      same_site: "Lax",
      secure: true,
      http_only: true
    ]

    Plug.Conn.delete_resp_cookie(conn, "fz_recent_account_ids", cookie_opts)
  end

  scope "/browser", Web do
    pipe_through :public

    get "/config.xml", BrowserController, :config
  end

  scope "/", Web do
    pipe_through :public

    get "/", HomeController, :home
    post "/", HomeController, :redirect_to_sign_in
  end

  scope "/", Web do
    pipe_through :public

    get "/healthz", HealthController, :healthz
  end

  if Mix.env() in [:dev, :test] do
    scope "/dev" do
      pipe_through [:dev_tools]
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end

    scope "/error", Web do
      pipe_through [:public]

      get "/:code", ErrorController, :show
    end
  end

  scope "/sign_up", Web do
    pipe_through :public

    live "/", SignUp
  end

  # Maintained from the LaunchHN - show SignUp form
  scope "/try", Web do
    pipe_through :public

    live "/", SignUp
  end

  scope "/auth", Web do
    pipe_through :public

    get "/oidc/callback", OIDCController, :callback
  end

  # Legacy OIDC callback - must be outside RedirectIfAuthenticated scope
  # because IdP redirects don't include as=client param
  scope "/:account_id_or_slug", Web do
    pipe_through :public

    get "/sign_in/providers/:auth_provider_id/handle_callback", OIDCController, :callback
  end

  scope "/", Web do
    pipe_through :public

    live_session :verification,
      on_mount: [Web.LiveHooks.AllowEctoSandbox] do
      live "/verification", Verification
    end
  end

  scope "/:account_id_or_slug", Web do
    pipe_through [
      :public,
      Web.Plugs.FetchAccount,
      Web.Plugs.FetchSubject,
      Web.Plugs.RedirectIfAuthenticated,
      Web.Plugs.AutoRedirectDefaultProvider
    ]

    # Email auth entry point
    post "/sign_in/email_otp/:auth_provider_id", EmailOTPController, :sign_in
    get "/sign_in/email_otp/:auth_provider_id/verify", EmailOTPController, :verify
    post "/sign_in/email_otp/:auth_provider_id/verify", EmailOTPController, :verify

    # Userpass auth entry point
    post "/sign_in/userpass/:auth_provider_id", UserpassController, :sign_in

    live_session :redirect_if_user_is_authenticated,
      on_mount: [
        Web.LiveHooks.AllowEctoSandbox,
        Web.LiveHooks.FetchAccount,
        Web.LiveHooks.FetchSubject,
        Web.LiveHooks.RedirectIfAuthenticated
      ] do
      live "/", SignIn
    end

    live_session :email_otp_verify,
      session: {Web.Cookie.EmailOTP, :fetch_state, []},
      on_mount: [
        Web.LiveHooks.AllowEctoSandbox,
        Web.LiveHooks.FetchAccount,
        Web.LiveHooks.FetchSubject,
        Web.LiveHooks.RedirectIfAuthenticated
      ] do
      live "/sign_in/email_otp/:auth_provider_id", SignIn.Email
    end

    # OIDC auth entry point (placed after LiveView routes to avoid conflicts)
    get "/sign_in/:auth_provider_type/:auth_provider_id", OIDCController, :sign_in
  end

  # Client auth redirect routes (don't need portal session)
  scope "/:account_id_or_slug", Web do
    pipe_through [
      :public,
      Web.Plugs.FetchAccount
    ]

    get "/sign_in/client_redirect", SignInController, :client_redirect
    get "/sign_in/client_auth_error", SignInController, :client_auth_error
  end

  # Sign out route (needs portal session)
  scope "/:account_id_or_slug", Web do
    pipe_through [
      :public,
      Web.Plugs.FetchAccount,
      Web.Plugs.FetchSubject
    ]

    post "/sign_out", SignOutController, :sign_out
  end

  # Authenticated admin routes
  scope "/:account_id_or_slug", Web do
    pipe_through [
      :public,
      Web.Plugs.FetchAccount,
      Web.Plugs.FetchSubject,
      Web.Plugs.EnsureAuthenticated,
      Web.Plugs.EnsureAdmin
    ]

    live_session :ensure_authenticated,
      on_mount: [
        Web.LiveHooks.AllowEctoSandbox,
        Web.LiveHooks.FetchAccount,
        Web.LiveHooks.FetchSubject,
        Web.LiveHooks.EnsureAuthenticated,
        Web.LiveHooks.EnsureAdmin,
        Web.LiveHooks.SetCurrentUri
      ] do
      # Actors
      live "/actors", Actors
      live "/actors/add", Actors, :add
      live "/actors/add_user", Actors, :add_user
      live "/actors/add_service_account", Actors, :add_service_account
      live "/actors/:id/edit", Actors, :edit
      live "/actors/:id/add_token", Actors, :add_token
      live "/actors/:id", Actors, :show

      # Groups
      live "/groups", Groups
      live "/groups/add", Groups, :add
      live "/groups/:id/edit", Groups, :edit
      live "/groups/:id", Groups, :show

      scope "/clients", Clients do
        live "/", Index
        live "/:id", Show
        live "/:id/edit", Edit
      end

      scope "/sites", Sites do
        live "/", Index
        live "/new", New

        scope "/:id/gateways", Gateways do
          live "/", Index
        end

        live "/:id/new_token", NewToken
        live "/:id/edit", Edit
        live "/:id", Show
      end

      scope "/gateways", Gateways do
        live "/:id", Show
      end

      scope "/resources", Resources do
        live "/", Index
        live "/new", New
        live "/:id/edit", Edit
        live "/:id", Show
      end

      scope "/policies", Policies do
        live "/", Index
        live "/new", New
        live "/:id/edit", Edit
        live "/:id", Show
      end

      scope "/settings", Settings do
        scope "/account" do
          live "/", Account
          live "/edit", Account.Edit
          live "/notifications/edit", Account.Notifications.Edit
        end

        live "/billing", Billing

        scope "/api_clients", ApiClients do
          live "/beta", Beta
          live "/", Index
          live "/new", New
          live "/:id/new_token", NewToken
          live "/:id", Show
          live "/:id/edit", Edit
        end

        # AuthProviders
        scope "/authentication" do
          live "/", Authentication
          live "/select_type", Authentication, :select_type
          live "/:type/new", Authentication, :new
          live "/:type/:id/edit", Authentication, :edit
        end

        # Directories
        scope "/directory_sync" do
          live "/", DirectorySync
          live "/select_type", DirectorySync, :select_type
          live "/:type/new", DirectorySync, :new
          live "/:type/:id/edit", DirectorySync, :edit
        end

        live "/dns", DNS
      end
    end
  end
end

defmodule PortalWeb.Router do
  use PortalWeb, :router

  pipeline :public do
    plug :accepts, ["html", "xml"]
    plug :fetch_session
    plug :protect_from_forgery
    plug :fetch_live_flash
    plug :put_root_layout, html: {PortalWeb.Layouts, :root}
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

  scope "/browser", PortalWeb do
    pipe_through :public

    get "/config.xml", BrowserController, :config
  end

  scope "/", PortalWeb do
    pipe_through :public

    get "/", HomeController, :home
    get "/getting_started", HomeController, :getting_started
    get "/sign_in", HomeController, :sign_in_chooser
    post "/sign_in", HomeController, :redirect_to_sign_in
    post "/", HomeController, :redirect_to_sign_in
  end

  if Mix.env() in [:dev, :test] do
    scope "/dev" do
      pipe_through [:dev_tools]
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end

    scope "/error", PortalWeb do
      pipe_through [:public]

      get "/:code", ErrorController, :show
    end
  end

  scope "/", PortalWeb do
    pipe_through :public

    live_session :public_sign_up,
      on_mount: [
        PortalWeb.LiveHooks.PutDynamicRepo,
        PortalWeb.LiveHooks.AllowEctoSandbox
      ] do
      live "/sign_up", SignUp, :fill_form
      live "/verify_sign_up", SignUp, :verify
      live "/find_account", FindAccount
      # Maintained from the LaunchHN - show SignUp form
      live "/try", SignUp, :fill_form
    end
  end

  scope "/auth", PortalWeb do
    pipe_through :public

    get "/oidc/callback", OIDCController, :callback
  end

  scope "/verification", PortalWeb do
    pipe_through :public

    get "/oidc", VerificationController, :oidc
    get "/entra", VerificationController, :entra
  end

  # Legacy OIDC callback - must be outside RedirectIfAuthenticated scope
  # because IdP redirects don't include as=client param
  scope "/:account_id_or_slug", PortalWeb do
    pipe_through :public

    get "/sign_in/providers/:auth_provider_id/handle_callback", OIDCController, :callback
  end

  scope "/:account_id_or_slug", PortalWeb do
    pipe_through :public

    get "/", AccountLandingController, :redirect_to_sign_in
  end

  scope "/:account_id_or_slug", PortalWeb do
    pipe_through [
      :public,
      PortalWeb.Plugs.FetchAccount,
      PortalWeb.Plugs.FetchSubject,
      PortalWeb.Plugs.RedirectIfAuthenticated,
      PortalWeb.Plugs.AutoRedirectDefaultProvider
    ]

    # Email auth entry point
    post "/sign_in/email_otp/:auth_provider_id", EmailOTPController, :sign_in
    get "/sign_in/email_otp/:auth_provider_id/verify", EmailOTPController, :verify
    post "/sign_in/email_otp/:auth_provider_id/verify", EmailOTPController, :verify

    # Userpass auth entry point
    post "/sign_in/userpass/:auth_provider_id", UserpassController, :sign_in

    live_session :redirect_if_user_is_authenticated,
      on_mount: [
        PortalWeb.LiveHooks.PutDynamicRepo,
        PortalWeb.LiveHooks.AllowEctoSandbox,
        PortalWeb.LiveHooks.FetchAccount,
        PortalWeb.LiveHooks.FetchSubject,
        PortalWeb.LiveHooks.RedirectIfAuthenticated
      ] do
      live "/sign_in", SignIn
    end

    live_session :email_otp_verify,
      session: {PortalWeb.Cookie.EmailOTP, :fetch_state, []},
      on_mount: [
        PortalWeb.LiveHooks.PutDynamicRepo,
        PortalWeb.LiveHooks.AllowEctoSandbox,
        PortalWeb.LiveHooks.FetchAccount,
        PortalWeb.LiveHooks.FetchSubject,
        PortalWeb.LiveHooks.RedirectIfAuthenticated
      ] do
      live "/sign_in/email_otp/:auth_provider_id", SignIn.Email
    end

    # OIDC auth entry point (placed after LiveView routes to avoid conflicts)
    get "/sign_in/:auth_provider_type/:auth_provider_id", OIDCController, :sign_in
  end

  # Client auth redirect routes (don't need portal session)
  scope "/:account_id_or_slug", PortalWeb do
    pipe_through [
      :public,
      PortalWeb.Plugs.FetchAccount
    ]

    get "/sign_in/client_redirect", SignInController, :client_redirect
    get "/sign_in/client_auth_error", SignInController, :client_auth_error
    get "/sign_in/client_account_disabled", SignInController, :client_account_disabled
  end

  # Sign out route (needs portal session)
  scope "/:account_id_or_slug", PortalWeb do
    pipe_through [
      :public,
      PortalWeb.Plugs.FetchAccount,
      PortalWeb.Plugs.FetchSubject
    ]

    post "/sign_out", SignOutController, :sign_out
  end

  # Authenticated admin routes
  scope "/:account_id_or_slug", PortalWeb do
    pipe_through [
      :public,
      PortalWeb.Plugs.FetchAccount,
      PortalWeb.Plugs.FetchSubject,
      PortalWeb.Plugs.EnsureAuthenticated,
      PortalWeb.Plugs.EnsureAdmin
    ]

    live_session :ensure_authenticated,
      on_mount: [
        PortalWeb.LiveHooks.PutDynamicRepo,
        PortalWeb.LiveHooks.AllowEctoSandbox,
        PortalWeb.LiveHooks.FetchAccount,
        PortalWeb.LiveHooks.FetchSubject,
        PortalWeb.LiveHooks.EnsureAuthenticated,
        PortalWeb.LiveHooks.EnsureAdmin,
        PortalWeb.LiveHooks.SetCurrentUri
      ] do
      # People (non-service-account actors)
      live "/actors", Actors
      live "/actors/new", Actors, :new
      live "/actors/:id/edit", Actors, :edit
      live "/actors/:id", Actors, :show

      # Service Accounts
      live "/service_accounts", ServiceAccounts
      live "/service_accounts/new", ServiceAccounts, :new
      live "/service_accounts/:id/edit", ServiceAccounts, :edit
      live "/service_accounts/:id", ServiceAccounts, :show

      # Groups
      live "/groups", Groups
      live "/groups/new", Groups, :new
      live "/groups/:id/edit", Groups, :edit
      live "/groups/:id", Groups, :show

      # Clients
      live "/clients", Clients
      live "/clients/:id/edit", Clients, :edit
      live "/clients/:id", Clients, :show

      # Sites
      live "/sites", Sites
      live "/sites/new", Sites, :new
      live "/sites/:id/edit", Sites, :edit
      live "/sites/:id", Sites, :show

      # Resources
      live "/resources", Resources
      live "/resources/new", Resources, :new
      live "/resources/:id/edit", Resources, :edit
      live "/resources/:id", Resources, :show

      # Policies
      live "/policies", Policies
      live "/policies/new", Policies, :new
      live "/policies/:id/edit", Policies, :edit
      live "/policies/:id", Policies, :show

      scope "/settings", Settings do
        live "/profile", Profile
        live "/account", Account

        scope "/notifications" do
          live "/", Notifications
        end

        scope "/api_clients", ApiClients do
          live "/beta", Beta
          live "/", Index
          live "/new", Index, :new
          live "/:id/edit", Index, :edit
        end

        # AuthProviders
        scope "/authentication" do
          live "/", Authentication
          live "/new", Authentication, :select_type
          live "/:type/new", Authentication, :new
          live "/:type/:id/edit", Authentication, :edit
        end

        # Directories
        scope "/directory_sync" do
          live "/", DirectorySync
          live "/new", DirectorySync, :select_type
          live "/:type/new", DirectorySync, :new
          live "/:type/:id/edit", DirectorySync, :edit
        end

        scope "/dns" do
          live "/", DNS
          live "/edit", DNS, :edit
        end
      end
    end
  end
end

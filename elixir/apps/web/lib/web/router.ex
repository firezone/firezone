defmodule Web.Router do
  use Web, :router

  pipeline :public do
    plug :accepts, ["html", "xml"]

    plug :fetch_session

    plug :protect_from_forgery
    plug :fetch_live_flash
    plug :put_root_layout, html: {Web.Layouts, :root}
  end

  pipeline :dev_tools do
    plug :accepts, ["html"]
    plug :disable_csp
  end

  defp disable_csp(conn, _opts) do
    Plug.Conn.delete_resp_header(conn, "content-security-policy")
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

      # Adapter-specific routes
      ## Email
      # TODO: IDP REFACTOR
      # Remove this route once all accounts have migrated
      live "/sign_in/providers/email/:provider_id", SignIn.Email
      live "/sign_in/email_otp/:auth_provider_id", SignIn.Email
    end

    # OIDC auth entry point (placed after LiveView routes to avoid conflicts)
    get "/sign_in/:auth_provider_type/:auth_provider_id", OIDCController, :sign_in
  end

  # Sign in / out routes
  scope "/:account_id_or_slug", Web do
    pipe_through [
      :public,
      Web.Plugs.FetchAccount,
      Web.Plugs.FetchSubject
    ]

    get "/sign_in/client_redirect", SignInController, :client_redirect
    get "/sign_in/client_auth_error", SignInController, :client_auth_error

    scope "/sign_in/providers/:provider_id" do
      # UserPass
      post "/verify_credentials", AuthController, :verify_credentials

      # Email
      post "/request_email_otp", AuthController, :request_email_otp
      get "/verify_sign_in_token", AuthController, :verify_sign_in_token

      # IdP
      get "/redirect", AuthController, :redirect_to_idp
      get "/handle_callback", AuthController, :handle_idp_callback
    end

    get "/sign_out", AuthController, :sign_out
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
        Web.LiveHooks.SetActiveSidebarItem
      ] do
      scope "/actors", Actors do
        live "/", Index
        live "/new", New
        live "/:id", Show

        scope "/users", Users do
          live "/new", New
          live "/:id/new_identity", NewIdentity
        end

        scope "/service_accounts", ServiceAccounts do
          live "/new", New
          live "/:id/new_identity", NewIdentity
        end

        live "/:id/edit", Edit
        live "/:id/edit_groups", EditGroups
      end

      scope "/groups", Groups do
        live "/", Index

        live "/add", Index, :add
        live "/show/:id", Index, :show
        live "/edit/:id", Index, :edit

        # TODO: IDP REFACTOR
        # Remove the below routes after all accounts have migrated
        live "/new", New
        live "/:id/edit", Edit
        live "/:id/edit_actors", EditActors
        live "/:id", Show
      end

      scope "/clients", Clients do
        live "/", Index
        live "/:id", Show
        live "/:id/edit", Edit
      end

      scope "/relay_groups", RelayGroups do
        live "/", Index
        live "/new", New
        live "/:id/edit", Edit
        live "/:id/new_token", NewToken
        live "/:id", Show
      end

      scope "/relays", Relays do
        live "/:id", Show
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

        scope "/identity_providers", IdentityProviders do
          live "/", Index
          live "/new", New

          scope "/openid_connect", OpenIDConnect do
            live "/new", New
            live "/:provider_id", Show
            live "/:provider_id/edit", Edit

            # OpenID Connection
            get "/:provider_id/redirect", Connect, :redirect_to_idp
            get "/:provider_id/handle_callback", Connect, :handle_idp_callback
          end

          scope "/google_workspace", GoogleWorkspace do
            live "/new", New
            live "/:provider_id", Show
            live "/:provider_id/edit", Edit

            # OpenID Connection
            get "/:provider_id/redirect", Connect, :redirect_to_idp
            get "/:provider_id/handle_callback", Connect, :handle_idp_callback
          end

          scope "/microsoft_entra", MicrosoftEntra do
            live "/new", New
            live "/:provider_id", Show
            live "/:provider_id/edit", Edit

            # OpenID Connection
            get "/:provider_id/redirect", Connect, :redirect_to_idp
            get "/:provider_id/handle_callback", Connect, :handle_idp_callback
          end

          scope "/okta", Okta do
            live "/new", New
            live "/:provider_id", Show
            live "/:provider_id/edit", Edit

            # OpenID Connection
            get "/:provider_id/redirect", Connect, :redirect_to_idp
            get "/:provider_id/handle_callback", Connect, :handle_idp_callback
          end

          scope "/jumpcloud", JumpCloud do
            live "/new", New
            live "/:provider_id", Show
            live "/:provider_id/edit", Edit

            # OpenID Connection
            get "/:provider_id/redirect", Connect, :redirect_to_idp
            get "/:provider_id/handle_callback", Connect, :handle_idp_callback
          end

          scope "/mock", Mock do
            live "/new", New
            live "/:provider_id", Show
            live "/:provider_id/edit", Edit
          end

          scope "/system", System do
            live "/:provider_id", Show
          end
        end

        live "/dns", DNS
      end
    end
  end
end

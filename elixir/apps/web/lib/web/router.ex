defmodule Web.Router do
  use Web, :router
  import Web.Auth

  pipeline :public do
    plug :accepts, ["html", "xml"]
    plug :fetch_session
    plug :protect_from_forgery
    plug :fetch_live_flash
    plug :put_root_layout, html: {Web.Layouts, :root}
  end

  pipeline :account do
    plug :fetch_account
    plug :fetch_subject
  end

  pipeline :control_plane do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :protect_from_forgery
    plug :fetch_live_flash
    plug :put_root_layout, html: {Web.Layouts, :root}
  end

  pipeline :ensure_authenticated_admin do
    plug :ensure_authenticated
    plug :ensure_authenticated_actor_type, :account_admin_user
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
      pipe_through [:public]
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

  scope "/:account_id_or_slug", Web do
    pipe_through [:public, :account, :redirect_if_user_is_authenticated]

    live_session :redirect_if_user_is_authenticated,
      on_mount: [
        Web.Sandbox,
        {Web.Auth, :redirect_if_user_is_authenticated}
      ] do
      live "/", SignIn

      # Adapter-specific routes
      ## Email
      live "/sign_in/providers/email/:provider_id", SignIn.Email
    end
  end

  scope "/:account_id_or_slug", Web do
    pipe_through [:control_plane, :account]

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
  end

  scope "/:account_id_or_slug", Web do
    pipe_through [:control_plane, :account]

    get "/sign_out", AuthController, :sign_out
  end

  scope "/:account_id_or_slug", Web do
    pipe_through [:control_plane, :account, :ensure_authenticated_admin]

    live_session :ensure_authenticated,
      on_mount: [
        Web.Sandbox,
        {Web.Auth, :ensure_authenticated},
        {Web.Auth, :ensure_account_admin_user_actor},
        {Web.Auth, :mount_account},
        {Web.Nav, :set_active_sidebar_item}
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

      scope "/flows", Flows do
        live "/:id", Show
        get "/:id/activities.csv", DownloadActivities, :download
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
            live "/:provider_id/sync", Sync

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

defmodule PortalWeb.SignInHTML do
  use PortalWeb, :html
  alias PortalWeb.Components.AuthPage

  def client_redirect(assigns) do
    ~H"""
    <.document conn={@conn} page_title={assigns[:page_title]} refresh_url={@redirect_url}>
      <AuthPage.heading title="Signed in successfully" class="mb-6">
        You're signed in to <span class="font-medium text-fg">{@account.name}</span>.
      </AuthPage.heading>
      <p class="pt-4 border-t border-hair text-xs text-muted">
        You can now close this window and return to what you were doing.
      </p>
    </.document>
    """
  end

  def client_auth_error(assigns) do
    ~H"""
    <.document conn={@conn} page_title={assigns[:page_title]}>
      <div class="w-10 h-10 mb-6 flex items-center justify-center border border-attn text-attn">
        <Core.icon name="ri-error-warning-line" class="w-5 h-5" />
      </div>
      <AuthPage.heading title="Sign in error" class="mb-6">
        {@account.name}
      </AuthPage.heading>
      <p class="mb-8 text-sm text-fg">{@error}</p>
      <Navigation.link href={@retry_path} class={AuthPage.primary_button_class()}>
        Return to sign in
      </Navigation.link>
    </.document>
    """
  end

  def client_account_disabled(assigns) do
    ~H"""
    <.document conn={@conn} page_title={assigns[:page_title]}>
      <AuthPage.heading title="Account disabled" class="mb-6">
        <span class="font-medium text-fg">{@account.name}</span> has been disabled.
      </AuthPage.heading>
      <p class="pt-4 border-t border-hair text-xs text-muted">
        Please contact your Firezone administrator to enable this account.
      </p>
    </.document>
    """
  end

  def headless_client_signed_in(assigns) do
    assigns = Map.put(assigns, :api_url, PortalWeb.DeploymentURLs.api_url())

    ~H"""
    <.document conn={@conn} page_title={assigns[:page_title]} with_js width="max-w-lg">
      <div class="w-10 h-10 mb-6 flex items-center justify-center border border-rule text-fg">
        <Core.icon name="ri-check-line" class="w-5 h-5" />
      </div>
      <AuthPage.heading title="Signed in successfully">
        {@account.name}
      </AuthPage.heading>

      <div class="mb-8">
        <AuthPage.eyebrow>Session details</AuthPage.eyebrow>
        <dl class="text-sm">
          <div class="flex gap-4 py-2 border-b border-hair">
            <dt class="w-28 shrink-0 text-muted">Signed in as</dt>
            <dd class="text-fg font-medium">{@actor_name}</dd>
          </div>
          <div class="flex gap-4 py-2 border-b border-hair">
            <dt class="w-28 shrink-0 text-muted">Account</dt>
            <dd class="text-fg font-medium">{@account.name}</dd>
          </div>
          <div class="flex gap-4 py-2 border-b border-hair">
            <dt class="w-28 shrink-0 text-muted">Slug</dt>
            <dd class="text-fg font-mono">{@account.slug}</dd>
          </div>
          <div class="flex gap-4 py-2 border-b border-hair">
            <dt class="w-28 shrink-0 text-muted">Account ID</dt>
            <dd class="text-fg font-mono break-all">{@account.id}</dd>
          </div>
        </dl>
      </div>

      <div class="mb-8">
        <AuthPage.eyebrow>Your token</AuthPage.eyebrow>
        <div class="p-3 border border-rule bg-hover font-mono text-xs text-fg break-all select-all">
          <code id="token-value">{@token}</code>
        </div>
        <div class="mt-3 flex items-center justify-between gap-4">
          <p :if={@expires_at} class="text-xs text-muted">
            Expires
            <time datetime={DateTime.to_iso8601(@expires_at)} class="font-mono">
              {Calendar.strftime(@expires_at, "%Y-%m-%d %H:%M:%S UTC")}
            </time>
          </p>
          <button
            id="copy-button"
            type="button"
            data-copy-token-button
            data-copy-target="#token-value"
            class={[AuthPage.primary_button_class(), "ml-auto"]}
          >
            <Core.icon name="ri-file-copy-line" class="w-4 h-4" /> Copy to clipboard
          </button>
        </div>
      </div>

      <div class="pt-4 border-t border-hair">
        <p class="text-xs text-muted leading-relaxed">
          Paste this token in the prompt opened by the Firezone Client, or set it as the
          <code
            class="px-1 py-0.5 border border-hair bg-hover font-mono text-fg"
            phx-no-format
          >FIREZONE_TOKEN</code>
          environment variable.
        </p>
        <p
          :if={@api_url}
          id="api-url-hint"
          class="mt-2 text-xs text-muted leading-relaxed"
        >
          Also set
          <code
            class="px-1 py-0.5 border border-hair bg-hover font-mono text-fg"
            phx-no-format
          >FIREZONE_API_URL={@api_url}</code>
          so the Client connects to this portal.
        </p>
      </div>
    </.document>
    """
  end

  attr :conn, :any, required: true
  attr :page_title, :string, default: nil
  attr :refresh_url, :string, default: nil
  attr :with_js, :boolean, default: false
  attr :width, :string, default: "max-w-sm"
  slot :inner_block, required: true

  defp document(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en" class="scrollbar-gutter-stable">
      <head>
        <meta charset="utf-8" />
        <meta http-equiv="X-UA-Compatible" content="IE=edge" />
        <meta :if={@refresh_url} http-equiv="refresh" content={"0; url=#{@refresh_url}"} />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <link rel="icon" href={~p"/favicon.ico"} sizes="any" />
        <link rel="icon" href={~p"/images/favicon.svg"} type="image/svg+xml" />
        <link rel="apple-touch-icon" href={~p"/images/apple-touch-icon.png"} />
        <link rel="manifest" href={~p"/site.webmanifest"} />
        <meta name="theme-color" content="#FF7300" />
        <meta name="csrf-token" content={get_csrf_token()} />
        <.live_title suffix=" · Firezone">
          {@page_title || "Firezone"}
        </.live_title>
        <AuthPage.theme_script nonce={@conn.private[:csp_nonce]} />
        <link
          phx-track-static
          rel="stylesheet"
          nonce={@conn.private[:csp_nonce]}
          href={~p"/assets/app.css"}
        />
        <link
          phx-track-static
          rel="stylesheet"
          nonce={@conn.private[:csp_nonce]}
          href={~p"/assets/main.css"}
        />
        <script
          :if={@with_js}
          defer
          phx-track-static
          type="text/javascript"
          nonce={@conn.private[:csp_nonce]}
          src={~p"/assets/app.js"}
        >
        </script>
      </head>
      <body class="min-h-screen flex flex-col bg-bg text-fg">
        <div class="flex items-center gap-2.5 h-14 px-6 border-b border-hair shrink-0">
          <img src={~p"/images/logo.svg"} class="h-5 w-auto shrink-0" alt="Firezone Logo" />
          <span class="text-sm font-semibold tracking-tight">Firezone</span>
        </div>
        <main class="flex-1 flex items-center justify-center px-4 py-12">
          <div class={["w-full", @width]}>
            {render_slot(@inner_block)}
          </div>
        </main>
      </body>
    </html>
    """
  end
end

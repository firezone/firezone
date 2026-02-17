defmodule PortalWeb.SignInHTML do
  use PortalWeb, :html

  def client_redirect(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en" class="scrollbar-gutter-stable">
      <head>
        <meta charset="utf-8" />
        <meta http-equiv="X-UA-Compatible" content="IE=edge" />
        <meta http-equiv="refresh" content={"0; url=#{@redirect_url}"} />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <link rel="icon" href={~p"/favicon.ico"} sizes="any" />
        <link rel="icon" href={~p"/images/favicon.svg"} type="image/svg+xml" />
        <link rel="apple-touch-icon" href={~p"/images/apple-touch-icon.png"} />
        <link rel="manifest" href={~p"/site.webmanifest"} />
        <meta name="theme-color" content="#331700" />
        <meta name="csrf-token" content={get_csrf_token()} />
        <.live_title suffix=" · Firezone">
          {assigns[:page_title] || "Firezone"}
        </.live_title>
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
      </head>
      <body class="bg-[var(--surface)] min-h-screen flex items-center justify-center">
        <div class="w-full max-w-sm px-4 py-12 text-center">
          <div class="mx-auto mb-6 w-14 h-14 rounded-full bg-[var(--status-active-bg)] flex items-center justify-center">
            <svg
              class="w-7 h-7 text-[var(--status-active)]"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="2.5"
              stroke-linecap="round"
              stroke-linejoin="round"
            >
              <path d="M20 6L9 17l-5-5" />
            </svg>
          </div>
          <h1 class="text-xl font-semibold text-[var(--text-primary)] tracking-tight">
            Signed in successfully
          </h1>
          <p class="mt-2 text-sm text-[var(--text-secondary)]">
            You're signed in to <span class="font-medium text-[var(--text-primary)]">{@account.name}</span>.
          </p>
          <p class="mt-4 text-xs text-[var(--text-muted)]">
            You can now close this window and return to the Firezone client.
          </p>
        </div>
      </body>
    </html>
    """
  end

  def client_auth_error(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en" class="scrollbar-gutter-stable">
      <head>
        <meta charset="utf-8" />
        <meta http-equiv="X-UA-Compatible" content="IE=edge" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <link rel="icon" href={~p"/favicon.ico"} sizes="any" />
        <link rel="icon" href={~p"/images/favicon.svg"} type="image/svg+xml" />
        <link rel="apple-touch-icon" href={~p"/images/apple-touch-icon.png"} />
        <link rel="manifest" href={~p"/site.webmanifest"} />
        <meta name="theme-color" content="#331700" />
        <meta name="csrf-token" content={get_csrf_token()} />
        <.live_title suffix=" · Firezone">
          {assigns[:page_title] || "Firezone"}
        </.live_title>
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
      </head>
      <body class="bg-[var(--surface)] min-h-screen flex items-center justify-center">
        <div class="w-full max-w-sm px-6 py-12">
          <img src="/images/logo-text.svg" alt="Firezone" class="h-8 block mx-auto mb-8" />
          <div class="flex items-center gap-3 mb-8">
            <div class="w-11 h-11 rounded bg-red-50 dark:bg-red-950/30 border border-red-200 dark:border-red-800 flex items-center justify-center shrink-0">
              <svg
                class="w-5 h-5 text-red-500"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                stroke-width="1.5"
                stroke-linecap="round"
                stroke-linejoin="round"
              >
                <circle cx="12" cy="12" r="10" />
                <line x1="12" y1="8" x2="12" y2="12" />
                <line x1="12" y1="16" x2="12.01" y2="16" />
              </svg>
            </div>
            <div>
              <h1 class="text-xl font-bold text-[var(--text-primary)] tracking-tight">
                Sign in error
              </h1>
              <p class="text-xs text-[var(--text-tertiary)] mt-0.5">{@account.name}</p>
            </div>
          </div>
          <p class="text-sm text-center text-[var(--text-secondary)]">{@error}</p>
          <div class="flex justify-center">
            <.link
              href={@retry_path}
              class="inline-flex items-center justify-center rounded-sm bg-accent-500 px-4 py-2 text-sm font-medium text-white hover:bg-accent-700 focus:outline-hidden focus:ring-2 focus:ring-offset-2 focus:ring-accent-500"
            >
              Return to sign in
            </.link>
          </div>
        </div>
      </body>
    </html>
    """
  end

  def client_account_disabled(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en" class="scrollbar-gutter-stable">
      <head>
        <meta charset="utf-8" />
        <meta http-equiv="X-UA-Compatible" content="IE=edge" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <link rel="icon" href={~p"/favicon.ico"} sizes="any" />
        <link rel="icon" href={~p"/images/favicon.svg"} type="image/svg+xml" />
        <link rel="apple-touch-icon" href={~p"/images/apple-touch-icon.png"} />
        <link rel="manifest" href={~p"/site.webmanifest"} />
        <meta name="theme-color" content="#331700" />
        <meta name="csrf-token" content={get_csrf_token()} />
        <.live_title suffix=" · Firezone">
          {assigns[:page_title] || "Firezone"}
        </.live_title>
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
      </head>
      <body class="bg-[var(--surface)] min-h-screen flex items-center justify-center">
        <div class="w-full max-w-sm px-4 py-12 text-center">
          <div class="mx-auto mb-6 w-14 h-14 rounded-full bg-[var(--status-error-bg)] flex items-center justify-center">
            <svg
              class="w-7 h-7 text-[var(--status-error)]"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="2"
              stroke-linecap="round"
              stroke-linejoin="round"
            >
              <circle cx="12" cy="12" r="10" />
              <line x1="12" y1="8" x2="12" y2="12" />
              <line x1="12" y1="16" x2="12.01" y2="16" />
            </svg>
          </div>
          <h1 class="text-xl font-semibold text-[var(--text-primary)] tracking-tight">
            Account disabled
          </h1>
          <p class="mt-2 text-sm text-[var(--text-secondary)]">
            <span class="font-medium text-[var(--text-primary)]">{@account.name}</span>
            has been disabled.
          </p>
          <p class="mt-4 text-xs text-[var(--text-muted)]">
            Please contact your Firezone administrator to re-enable this account.
          </p>
        </div>
      </body>
    </html>
    """
  end

  def headless_client_token(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en" class="scrollbar-gutter-stable">
      <head>
        <meta charset="utf-8" />
        <meta http-equiv="X-UA-Compatible" content="IE=edge" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <link rel="icon" href={~p"/favicon.ico"} sizes="any" />
        <link rel="icon" href={~p"/images/favicon.svg"} type="image/svg+xml" />
        <link rel="apple-touch-icon" href={~p"/images/apple-touch-icon.png"} />
        <link rel="manifest" href={~p"/site.webmanifest"} />
        <meta name="theme-color" content="#331700" />
        <meta name="csrf-token" content={get_csrf_token()} />
        <.live_title suffix=" · Firezone">
          {assigns[:page_title] || "Firezone"}
        </.live_title>
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
          defer
          phx-track-static
          type="text/javascript"
          nonce={@conn.private[:csp_nonce]}
          src={~p"/assets/app.js"}
        >
        </script>
      </head>
      <body class="bg-[var(--surface)] min-h-screen flex items-center justify-center">
        <div class="w-full max-w-lg px-6 py-12">
          <img src="/images/logo-text.svg" alt="Firezone" class="h-8 block mx-auto mb-8" />
          <div class="flex items-center gap-3 mb-8">
            <div class="w-11 h-11 rounded bg-violet-50 dark:bg-violet-950/30 border border-violet-200 dark:border-violet-800 flex items-center justify-center shrink-0">
              <svg
                class="w-5 h-5 text-violet-500"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                stroke-width="1.5"
                stroke-linecap="round"
                stroke-linejoin="round"
              >
                <path d="M20 6L9 17l-5-5" />
              </svg>
            </div>
            <div>
              <h1 class="text-xl font-bold text-[var(--text-primary)] tracking-tight">
                Signed in successfully
              </h1>
              <p class="text-xs text-[var(--text-tertiary)] mt-0.5">{@account.name}</p>
            </div>
          </div>

          <div class="rounded border border-[var(--border)] bg-[var(--surface-raised)] p-4 mb-6">
            <p class="text-xs font-semibold text-[var(--text-secondary)] uppercase tracking-widest mb-3">
              Session details
            </p>
            <dl class="space-y-2">
              <div class="flex gap-2">
                <dt class="text-xs text-[var(--text-tertiary)] w-28 shrink-0 pt-0.5">Signed in as</dt>
                <dd class="text-xs text-[var(--text-primary)] font-medium">{@actor_name}</dd>
              </div>
              <div class="flex gap-2">
                <dt class="text-xs text-[var(--text-tertiary)] w-28 shrink-0 pt-0.5">Account</dt>
                <dd class="text-xs text-[var(--text-primary)]">{@account.name}</dd>
              </div>
              <div class="flex gap-2">
                <dt class="text-xs text-[var(--text-tertiary)] w-28 shrink-0 pt-0.5">Slug</dt>
                <dd class="text-xs text-[var(--text-primary)] font-mono">{@account.slug}</dd>
              </div>
              <div class="flex gap-2">
                <dt class="text-xs text-[var(--text-tertiary)] w-28 shrink-0 pt-0.5">Account ID</dt>
                <dd class="text-xs text-[var(--text-primary)] font-mono">{@account.id}</dd>
              </div>
            </dl>
          </div>

          <div class="space-y-3 mb-6">
            <p class="text-xs font-semibold text-[var(--text-secondary)] uppercase tracking-widest">
              Your token
            </p>
            <div class="rounded border border-[var(--border)] bg-[var(--surface-raised)] p-3 font-mono text-xs text-[var(--text-primary)] break-all select-all">
              <code id="token-value">{@token}</code>
            </div>
            <div class="flex items-center justify-between gap-4">
              <p :if={@expires_at} class="text-xs text-[var(--text-tertiary)]">
                Expires
                <time datetime={DateTime.to_iso8601(@expires_at)}>
                  {Calendar.strftime(@expires_at, "%Y-%m-%d %H:%M:%S UTC")}
                </time>
              </p>
              <button
                id="copy-button"
                type="button"
                data-copy-token-button
                data-copy-target="#token-value"
                class="px-4 py-2 rounded text-xs font-semibold bg-violet-600 text-white hover:bg-violet-700 transition-colors whitespace-nowrap"
              >
                Copy to clipboard
              </button>
            </div>
          </div>

          <div class="pt-5 border-t border-[var(--border)]">
            <p class="text-xs text-[var(--text-tertiary)] leading-relaxed">
              Paste this token in the prompt opened by the Firezone Client, or set it as the
              <code class="px-1 py-0.5 rounded border border-[var(--border)] bg-[var(--surface-raised)] font-mono">
                FIREZONE_TOKEN
              </code>
              environment variable.
            </p>
          </div>
        </div>
      </body>
    </html>
    """
  end
end

defmodule PortalWeb.ErrorHTML do
  use PortalWeb, :html
  alias PortalWeb.Components.AuthPage

  embed_templates "error_html/*"

  # The default is to render a plain text page based on
  # the template name. For example, "404.html" becomes
  # "Not Found".
  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end

  attr :conn, :any, required: true
  attr :code, :string, required: true
  attr :title, :string, required: true
  slot :inner_block, required: true
  slot :actions

  def error_page(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta http-equiv="X-UA-Compatible" content="IE=edge" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <link rel="icon" href={~p"/favicon.ico"} sizes="any" />
        <link rel="icon" href={~p"/images/favicon.svg"} type="image/svg+xml" />
        <link rel="apple-touch-icon" href={~p"/images/apple-touch-icon.png"} />
        <link rel="manifest" href={~p"/site.webmanifest"} />
        <meta name="theme-color" content="#FF7300" />
        <meta name="csrf-token" content={get_csrf_token()} />
        <title>{@code} {@title}</title>
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
          <div class="w-full max-w-md">
            <p class="font-mono text-[11px] font-semibold tracking-[.12em] uppercase text-muted">
              Error
            </p>
            <p class="mt-2 pb-6 border-b border-rule text-[120px] font-bold leading-none tracking-tighter tabular-nums">
              {@code}
            </p>
            <h1 class="mt-6 text-[26px] font-bold leading-tight tracking-tight">{@title}</h1>
            <p class="mt-3 text-sm leading-relaxed text-muted">{render_slot(@inner_block)}</p>
            <div class="mt-8 flex flex-wrap items-center gap-3">
              <a href={~p"/"} class={AuthPage.primary_button_class()}>
                <Core.icon name="ri-home-4-line" class="w-4 h-4" /> Go home
              </a>
              {render_slot(@actions)}
            </div>
          </div>
        </main>
      </body>
    </html>
    """
  end
end

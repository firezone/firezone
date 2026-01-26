defmodule PortalWeb.SignInHTML do
  use PortalWeb, :html

  def client_redirect(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en" style="scrollbar-gutter: stable;">
      <head>
        <meta charset="utf-8" />
        <meta http-equiv="X-UA-Compatible" content="IE=edge" />
        <meta http-equiv="refresh" content={"0; url=#{@redirect_url}"} />
        <meta name="viewport" content="width=client-width, initial-scale=1" />
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
      <body class="bg-neutral-50">
        <main class="h-auto pt-16">
          <section>
            <div class="flex flex-col items-center justify-center px-6 py-8 mx-auto lg:py-0">
              <.hero_logo text={@account.name} />

              <div class="w-full col-span-6 mx-auto bg-white rounded shadow md:mt-0 sm:max-w-lg xl:p-0">
                <div class="p-6 space-y-4 lg:space-y-6 sm:p-8">
                  <h1 class="text-xl text-center leading-tight tracking-tight text-neutral-900 sm:text-2xl">
                    <span>
                      Sign in successful.
                    </span>
                  </h1>
                  <p class="text-center">You may close this window.</p>
                </div>
              </div>
            </div>
          </section>
        </main>
      </body>
    </html>
    """
  end

  def client_auth_error(assigns) do
    ~H"""
    <main class="h-auto pt-16">
      <section>
        <div class="flex flex-col items-center justify-center px-6 py-8 mx-auto lg:py-0">
          <.hero_logo text={@account.name} />

          <div class="w-full col-span-6 mx-auto bg-white rounded shadow md:mt-0 sm:max-w-lg xl:p-0">
            <div class="p-6 space-y-4 lg:space-y-6 sm:p-8">
              <h1 class="text-xl text-center leading-tight tracking-tight text-neutral-900 sm:text-2xl">
                <span>
                  Sign in error!
                </span>
              </h1>
              <p class="text-center">Please close this window and start the sign in process again.</p>
            </div>
          </div>
        </div>
      </section>
    </main>
    """
  end

  def headless_client_token(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en" style="scrollbar-gutter: stable;">
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
        <script nonce={@conn.private[:csp_nonce]}>
          function copyToken() {
            const token = document.getElementById('token-value').textContent;

            if (!navigator.clipboard) {
              alert('Clipboard API not available. Please copy the token manually.');
              return;
            }

            navigator.clipboard.writeText(token).then(() => {
              const button = document.getElementById('copy-button');
              const originalText = button.textContent;
              button.textContent = 'Copied!';
              button.classList.add('bg-green-600');
              button.classList.remove('bg-accent-500', 'hover:bg-accent-700');
              setTimeout(() => {
                button.textContent = originalText;
                button.classList.remove('bg-green-600');
                button.classList.add('bg-accent-500', 'hover:bg-accent-700');
              }, 2000);
            }).catch(() => {
              alert('Failed to copy token. Please copy it manually.');
            });
          }
        </script>
      </head>
      <body class="bg-neutral-50">
        <main class="h-auto pt-16">
          <section>
            <div class="flex flex-col items-center justify-center px-6 py-8 mx-auto lg:py-0">
              <.hero_logo text={@account.name} />

              <div class="w-full col-span-6 mx-auto bg-white rounded shadow md:mt-0 sm:max-w-2xl xl:p-0">
                <div class="p-6 space-y-5 sm:p-8">
                  <h1 class="text-xl text-center leading-tight tracking-tight text-neutral-900 sm:text-2xl">
                    Sign in successful
                  </h1>

                  <dl class="text-sm text-neutral-700 space-y-1">
                    <div class="flex gap-2">
                      <dt class="font-medium text-neutral-500">Signed in as:</dt>
                      <dd>{@actor_name}</dd>
                    </div>
                    <div class="flex gap-2">
                      <dt class="font-medium text-neutral-500">Account name:</dt>
                      <dd>{@account.name}</dd>
                    </div>
                    <div class="flex gap-2">
                      <dt class="font-medium text-neutral-500">Account slug:</dt>
                      <dd class="font-mono">{@account.slug}</dd>
                    </div>
                    <div class="flex gap-2">
                      <dt class="font-medium text-neutral-500">Account ID:</dt>
                      <dd class="font-mono">{@account.id}</dd>
                    </div>
                  </dl>

                  <hr class="border-neutral-200" />

                  <div class="space-y-2">
                    <label class="block text-sm font-medium text-neutral-700">
                      Here is the token you requested:
                    </label>
                    <div class="p-3 bg-neutral-100 border border-neutral-300 rounded font-mono text-xs break-all select-all">
                      <code id="token-value">{@token}</code>
                    </div>
                    <div class="flex items-center justify-between">
                      <p :if={@expires_at} class="text-xs text-neutral-500">
                        Token expires at:
                        <time datetime={DateTime.to_iso8601(@expires_at)}>
                          {Calendar.strftime(@expires_at, "%Y-%m-%d %H:%M:%S UTC")}
                        </time>
                      </p>
                      <button
                        id="copy-button"
                        type="button"
                        onclick="copyToken()"
                        class="px-4 py-2 text-sm font-medium text-white bg-accent-500 rounded hover:bg-accent-700 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-accent-500 transition-colors"
                      >
                        Copy token to clipboard
                      </button>
                    </div>
                  </div>

                  <hr class="border-neutral-200" />

                  <div class="text-sm text-neutral-600 space-y-2">
                    <p class="font-medium text-neutral-700">Next:</p>
                    <p>
                      Paste this token in the prompt opened by the Firezone Client, or set it as the
                      <code class="px-1 py-0.5 bg-neutral-100 rounded text-xs font-mono">
                        FIREZONE_TOKEN
                      </code>
                      environment variable.
                    </p>
                  </div>
                </div>
              </div>
            </div>
          </section>
        </main>
      </body>
    </html>
    """
  end
end

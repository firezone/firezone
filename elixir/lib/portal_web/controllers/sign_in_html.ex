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
          nonce={@conn.private.csp_nonce}
          href={~p"/assets/app.css"}
        />
        <link
          phx-track-static
          rel="stylesheet"
          nonce={@conn.private.csp_nonce}
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
end

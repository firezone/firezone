defmodule PortalWeb.OAuthHTML do
  use PortalWeb, :html
  alias PortalWeb.Components.AuthPage

  def choose_account(assigns) do
    ~H"""
    <Page.oauth_client_header client={@client} />

    <Core.flash :if={@error} kind={:error}>{@error}</Core.flash>

    <p :if={@accounts != []} class="text-sm text-muted mb-6">
      Pick which Firezone account to connect
      <span class="font-semibold text-fg">{@client.client_name}</span>
      to:
    </p>

    <div :if={@accounts != []}>
      <AuthPage.eyebrow>Recently signed in</AuthPage.eyebrow>
      <div class="flex flex-col gap-2">
        <Page.account_button
          :for={account <- @accounts}
          account={account}
          href={~p"/#{account}/oauth/authorize?#{@query}"}
        />
      </div>
    </div>

    <AuthPage.separator :if={@accounts != []} />

    <Page.account_slug_form action={~p"/oauth/authorize?#{@query}"} autofocus={@accounts == []} />
    """
  end

  def error(assigns) do
    ~H"""
    <div role="alert">
      <div class="w-10 h-10 mb-6 flex items-center justify-center border border-attn text-attn">
        <Core.icon name="ri-close-line" class="w-5 h-5" />
      </div>
      <AuthPage.heading title="This request is not valid" class="mb-6">
        {@description}
      </AuthPage.heading>
      <p class="pt-4 border-t border-hair text-xs text-muted">
        Nothing was shared. Close this window and try connecting again from the app.
      </p>
    </div>
    """
  end
end

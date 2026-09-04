defmodule PortalWeb.OAuthHTML do
  use PortalWeb, :html

  def choose_account(assigns) do
    ~H"""
    <.oauth_client_header client={@client} />

    <.flash :if={@error} kind={:error}>{@error}</.flash>

    <p :if={@accounts != []} class="text-sm text-body mb-6">
      Pick which Firezone account to connect
      <span class="font-semibold text-heading">{@client.client_name}</span>
      to:
    </p>

    <div :if={@accounts != []}>
      <div class="flex items-center gap-3 mb-3">
        <div class="flex-1 h-px bg-border"></div>
        <span class="text-xs font-medium text-muted uppercase tracking-widest">
          Recently signed in
        </span>
        <div class="flex-1 h-px bg-border"></div>
      </div>
      <div class="flex flex-col gap-2 mb-6">
        <.account_button
          :for={account <- @accounts}
          account={account}
          href={~p"/#{account}/oauth/authorize?#{@query}"}
        />
      </div>
    </div>

    <div :if={@accounts != []} class="flex items-center gap-3 my-5">
      <div class="flex-1 h-px bg-border"></div>
      <span class="text-xs text-muted">or</span>
      <div class="flex-1 h-px bg-border"></div>
    </div>

    <.account_slug_form action={~p"/oauth/authorize?#{@query}"} autofocus={@accounts == []} />
    """
  end

  def error(assigns) do
    ~H"""
    <div class="text-center">
      <div class="w-12 h-12 rounded mx-auto mb-4 flex items-center justify-center bg-danger/10">
        <.icon name="ri-error-warning-line" class="w-7 h-7 text-danger" />
      </div>

      <h1 class="text-2xl font-bold text-heading tracking-tight">This request is not valid</h1>
      <p class="text-sm text-body mt-2">{@description}</p>
      <p class="text-xs text-subtle mt-6">
        Nothing was shared. Close this window and try connecting again from the app.
      </p>
    </div>
    """
  end
end

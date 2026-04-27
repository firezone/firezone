defmodule PortalWeb.Settings.ApiClients.Beta do
  use PortalWeb, :live_view

  defmodule Database do
    alias Portal.Safe

    @spec mark_rest_api_requested(Portal.Account.t(), any()) ::
            {:ok, Portal.Account.t()} | {:error, Ecto.Changeset.t()}
    def mark_rest_api_requested(account, subject) do
      account
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.put_embed(:metadata, %{rest_api_requested_at: DateTime.utc_now()})
      |> Safe.scoped(subject)
      |> Safe.update()
    end
  end

  def mount(_params, _session, socket) do
    if Portal.Account.rest_api_enabled?(socket.assigns.account) do
      {:ok, push_navigate(socket, to: ~p"/#{socket.assigns.account}/settings/api_clients")}
    else
      socket =
        assign(
          socket,
          page_title: "API Clients",
          requested: Portal.Account.rest_api_access_requested?(socket.assigns.account),
          api_url: Portal.Config.get_env(:portal, :api_external_url)
        )

      {:ok, socket}
    end
  end

  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-full">
      <.settings_nav account={@account} current_path={@current_path} />

      <div class="flex-1 flex flex-col overflow-hidden">
        <div class="flex items-center justify-between px-6 py-3 border-b border-[var(--border)] shrink-0">
          <div class="flex items-center gap-2">
            <h2 class="text-xs font-semibold text-[var(--text-primary)]">API Tokens</h2>
          </div>
          <div class="flex items-center gap-2">
            <.docs_action path="/reference/rest-api" />
          </div>
        </div>

        <div class="flex-1 overflow-auto flex flex-col items-center justify-center">
          <div class="flex flex-col items-center gap-3 text-[var(--text-tertiary)]">
            <.icon name="ri-lock-line" class="w-8 h-8" />
            <div class="flex flex-col items-center gap-1 text-center">
              <p class="text-sm font-medium text-[var(--text-primary)]">REST API is in closed beta</p>
              <p class="text-xs">
                API Tokens are used to manage Firezone via the <.link
                  navigate={"#{@api_url}/swaggerui"}
                  class="text-[var(--brand)] hover:underline"
                  target="_blank"
                >REST API</.link>.
              </p>
            </div>
            <button
              :if={@requested == false}
              id="beta-request"
              phx-click="request_access"
              class="flex items-center gap-1 px-2.5 py-1 rounded text-xs border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-emphasis)] bg-[var(--surface)] transition-colors"
            >
              Request access
            </button>
            <p :if={@requested == true} class="text-xs text-[var(--text-tertiary)]">
              Access request submitted.
            </p>
          </div>
        </div>
      </div>
    </div>
    """
  end

  def handle_event("request_access", _params, socket) do
    Portal.Mailer.BetaEmail.rest_api_beta_email(
      socket.assigns.account,
      socket.assigns.subject
    )
    |> Portal.Mailer.enqueue()

    case Database.mark_rest_api_requested(socket.assigns.account, socket.assigns.subject) do
      {:ok, account} ->
        {:noreply, assign(socket, account: account, requested: true)}

      {:error, _} ->
        {:noreply, assign(socket, requested: true)}
    end
  end
end

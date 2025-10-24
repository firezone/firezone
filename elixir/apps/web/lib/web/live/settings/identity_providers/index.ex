defmodule Web.Settings.IdentityProviders.Index do
  use Web, :live_view
  import Web.Settings.IdentityProviders.Components
  alias Domain.{Auth, Actors}
  require Logger

  def mount(_params, _session, socket) do
    with {:ok, identities_count_by_provider_id} <-
           Auth.fetch_identities_count_grouped_by_provider_id(socket.assigns.subject),
         {:ok, groups_count_by_provider_id} <-
           Actors.fetch_groups_count_grouped_by_provider_id(socket.assigns.subject) do
      legacy_providers = get_legacy_oidc_and_okta_providers(socket.assigns.subject)

      # Generate a unique verification token for each provider
      provider_tokens =
        Map.new(legacy_providers, fn provider ->
          token = Domain.Crypto.random_token(32)

          # Subscribe to verification PubSub topic for this provider
          if connected?(socket) do
            Domain.PubSub.subscribe("oidc-verification:#{token}")
          end

          {provider.id, token}
        end)

      # Build verification URLs for each provider
      {provider_verification_urls, provider_verifiers, provider_configs} =
        build_provider_verification_urls(
          legacy_providers,
          socket.assigns.subject.account,
          provider_tokens
        )

      socket =
        socket
        |> assign(
          migrated?: Domain.Migrator.migrated?(socket.assigns.subject.account),
          default_provider_changed: false,
          page_title: "Identity Providers",
          identities_count_by_provider_id: identities_count_by_provider_id,
          groups_count_by_provider_id: groups_count_by_provider_id,
          show_migrate_modal: false,
          migrate_step: 1,
          legacy_providers: legacy_providers,
          provider_verifications: %{},
          provider_verification_urls: provider_verification_urls,
          provider_tokens: provider_tokens,
          provider_verifiers: provider_verifiers,
          provider_configs: provider_configs
        )
        |> assign_live_table("providers",
          query_module: Auth.Provider.Query,
          sortable_fields: [
            {:providers, :name}
          ],
          callback: &handle_providers_update!/2
        )

      {:ok, socket}
    else
      _ -> raise Web.LiveErrors.NotFoundError
    end
  end

  def handle_params(params, uri, socket) do
    socket = handle_live_tables_params(socket, params, uri)
    {:noreply, socket}
  end

  def handle_providers_update!(socket, list_opts) do
    with {:ok, providers, metadata} <- Auth.list_providers(socket.assigns.subject, list_opts) do
      {:ok,
       assign(socket,
         providers: providers,
         providers_metadata: metadata
       )}
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/settings/identity_providers"}>
        Identity Providers Settings
      </.breadcrumb>
    </.breadcrumbs>
    <.section>
      <:title>
        Identity Providers
      </:title>
      <:action>
        <.docs_action path="/authenticate" />
      </:action>
      <:action>
        <.add_button navigate={~p"/#{@account}/settings/identity_providers/new"}>
          Add Identity Provider
        </.add_button>
      </:action>
      <:help>
        Identity providers authenticate and sync your users and groups with an external source.
      </:help>
      <:content>
        <.flash :if={not @migrated?} kind={:warning}>
          Your account needs to be migrated to the new authentication system. This process only takes a few minutes.
          <button
            phx-click="open_migrate_modal"
            class={link_style()}
          >
            Start migration now &#8594;
          </button>
        </.flash>
        <.flash_group flash={@flash} />

        <div class="pb-8 px-1">
          <div class="text-lg text-neutral-600 mb-4">
            Default Authentication Provider
          </div>
          <.default_provider_form
            providers={@providers}
            default_provider_changed={@default_provider_changed}
          />
        </div>

        <div class="text-lg text-neutral-600 mb-4 px-1">
          All Identity Providers
        </div>
        <.live_table
          id="providers"
          rows={@providers}
          row_id={&"providers-#{&1.id}"}
          filters={@filters_by_table_id["providers"]}
          filter={@filter_form_by_table_id["providers"]}
          ordered_by={@order_by_table_id["providers"]}
          metadata={@providers_metadata}
        >
          <:col :let={provider} field={{:providers, :name}} label="Name" class="w-3/12">
            <div class="flex flex-wrap">
              <.link navigate={view_provider(@account, provider)} class={[link_style()]}>
                {provider.name}
              </.link>
              <.assigned_default_badge provider={provider} />
            </div>
          </:col>
          <:col :let={provider} label="Type" class="w-2/12">
            {adapter_name(provider.adapter)}
          </:col>
          <:col :let={provider} label="Status" class="w-2/12">
            <.status provider={provider} />
          </:col>
          <:col :let={provider} label="Sync Status">
            <.sync_status
              account={@account}
              provider={provider}
              identities_count_by_provider_id={@identities_count_by_provider_id}
              groups_count_by_provider_id={@groups_count_by_provider_id}
            />
          </:col>
          <:empty>
            <div class="flex justify-center text-center text-neutral-500 p-4">
              <div class="w-auto">
                <div class="pb-4">
                  No identity providers to display
                </div>
                <.add_button navigate={~p"/#{@account}/settings/identity_providers/new"}>
                  Add Identity Provider
                </.add_button>
              </div>
            </div>
          </:empty>
        </.live_table>
      </:content>
    </.section>

    <.modal
      :if={not @migrated?}
      id="migrate-modal"
      show={@show_migrate_modal}
      on_back="migrate_prev_step"
      on_confirm={if @migrate_step == 3, do: "perform_migration", else: "migrate_next_step"}
      on_close="close_migrate_modal"
      confirm_type={if @migrate_step == 4, do: "submit", else: "button"}
      confirm_disabled={
        @migrate_step == 2 and not all_providers_verified?(@legacy_providers, @provider_verifications)
      }
    >
      <:title>
        <%= case @migrate_step do %>
          <% 1 -> %>
            Step 1: Welcome
          <% 2 -> %>
            Step 2: Configure
          <% 3 -> %>
            Step 3: Review
          <% 4 -> %>
            Complete
          <% _ -> %>
            Migration
        <% end %>
      </:title>
      <:body>
        <%= case @migrate_step do %>
          <% 1 -> %>
            <p>Welcome to the Identity Provider migration wizard.</p>
            <p>This will guide you through the migration process.</p>
          <% 2 -> %>
            <div class="space-y-4">
              <p class="text-sm text-gray-600">
                The following identity providers need to be re-verified before continuing:
              </p>
              <%= if Enum.empty?(@legacy_providers) do %>
                <p class="text-sm text-gray-500">No OIDC or Okta providers found.</p>
              <% else %>
                <ul class="space-y-2">
                  <%= for provider <- @legacy_providers do %>
                    <li class="flex items-center justify-between p-3 bg-gray-50 rounded">
                      <div class="flex items-center space-x-3">
                        <span class="text-sm font-medium">{provider.name}</span>
                        <span class="text-xs text-gray-500">({provider.adapter})</span>
                      </div>
                      <div class="flex items-center space-x-2">
                        <%= case Map.get(@provider_verifications, provider.id) do %>
                          <% :verified -> %>
                            <span class="text-green-600">
                              <svg class="h-5 w-5" fill="currentColor" viewBox="0 0 20 20">
                                <path
                                  fill-rule="evenodd"
                                  d="M10 18a8 8 0 100-16 8 8 0 000 16zm3.707-9.293a1 1 0 00-1.414-1.414L9 10.586 7.707 9.293a1 1 0 00-1.414 1.414l2 2a1 1 0 001.414 0l4-4z"
                                  clip-rule="evenodd"
                                />
                              </svg>
                            </span>
                          <% :failed -> %>
                            <span class="text-red-600 text-xs">Failed</span>
                            <%= if verification_url = Map.get(@provider_verification_urls, provider.id) do %>
                              <.link href={verification_url} target="_blank" class={[link_style()]}>
                                Retry
                              </.link>
                            <% end %>
                          <% _ -> %>
                            <%= if verification_url = Map.get(@provider_verification_urls, provider.id) do %>
                              <.link href={verification_url} target="_blank" class={[link_style()]}>
                                Verify
                              </.link>
                            <% else %>
                              <span class="text-xs text-red-600">Config Error</span>
                            <% end %>
                        <% end %>
                      </div>
                    </li>
                  <% end %>
                </ul>
              <% end %>
            </div>
          <% 3 -> %>
            <p>Review and confirm the migration.</p>
          <% 4 -> %>
            <p>Migration completed successfully!</p>
          <% _ -> %>
            <p>Unknown step</p>
        <% end %>
      </:body>
      <:back_button :if={@migrate_step > 1 and @migrate_step < 4}>Back</:back_button>
      <:confirm_button>
        <%= case @migrate_step do %>
          <% 1 -> %>
            Next
          <% 2 -> %>
            Next
          <% 3 -> %>
            Perform Migration
          <% 4 -> %>
            Sign in Again &#8594;
          <% _ -> %>
            Next
        <% end %>
      </:confirm_button>
    </.modal>
    """
  end

  attr :providers, :list, required: true
  attr :default_provider_changed, :boolean, required: true

  defp default_provider_form(assigns) do
    options =
      assigns.providers
      |> Enum.filter(fn provider ->
        provider.adapter not in [:email, :userpass]
      end)
      |> Enum.map(fn provider ->
        {provider.name, provider.id}
      end)

    options = [{"None", :none} | options]

    value =
      assigns.providers
      |> Enum.find(%{id: :none}, fn provider ->
        !is_nil(provider.assigned_default_at)
      end)
      |> Map.get(:id)

    assigns = assign(assigns, options: options, value: value)

    ~H"""
    <.form
      id="default-provider-form"
      phx-submit="default_provider_save"
      phx-change="default_provider_change"
      for={nil}
    >
      <div class="flex gap-2 items-center">
        <.input
          id="default-provider-select"
          name="provider_id"
          type="select"
          options={@options}
          value={@value}
        />
        <.submit_button
          phx-disable-with="Saving..."
          {if @default_provider_changed, do: [], else: [disabled: true, style: "disabled"]}
          icon="hero-identification"
        >
          Make Default
        </.submit_button>
      </div>
      <p class="text-xs text-neutral-500 mt-2">
        When selected, users signing in from the Firezone client will be taken directly to this provider for authentication.
      </p>
    </.form>
    """
  end

  def handle_event("open_migrate_modal", _params, socket) do
    {:noreply, assign(socket, show_migrate_modal: true, migrate_step: 1)}
  end

  def handle_event("migrate_next_step", _params, socket) do
    current_step = socket.assigns.migrate_step

    # If we're at step 4 (complete), redirect to account page
    if current_step == 4 do
      {:noreply, redirect(socket, to: ~p"/#{socket.assigns.account}")}
    else
      {:noreply, assign(socket, migrate_step: current_step + 1)}
    end
  end

  def handle_event("migrate_prev_step", _params, socket) do
    prev_step = max(socket.assigns.migrate_step - 1, 1)
    {:noreply, assign(socket, migrate_step: prev_step)}
  end

  def handle_event("close_migrate_modal", _params, socket) do
    # If migration is complete (step 4), redirect to account page
    if socket.assigns.migrate_step == 4 do
      {:noreply, redirect(socket, to: ~p"/#{socket.assigns.account}")}
    else
      {:noreply, assign(socket, show_migrate_modal: false, migrate_step: 1)}
    end
  end

  def handle_event("perform_migration", _params, socket) do
    socket = assign(socket, migrate_step: socket.assigns.migrate_step + 1)
    Domain.Migrator.up(socket.assigns.subject)
    {:noreply, socket}
  end

  def handle_event("default_provider_change", _params, socket) do
    {:noreply, assign(socket, default_provider_changed: true)}
  end

  def handle_event("default_provider_save", %{"provider_id" => provider_id}, socket) do
    assign_default_provider(provider_id, socket)
  end

  def handle_event(event, params, socket) when event in ["paginate", "order_by", "filter"],
    do: handle_live_table_event(event, params, socket)

  def handle_info({:oidc_verify, pid, code, state_token}, socket) do
    # state_token is the verification token we sent as the OIDC state parameter
    # Find the provider for this state token using secure compare
    provider =
      Enum.find(socket.assigns.legacy_providers, fn provider ->
        stored_token = Map.get(socket.assigns.provider_tokens, provider.id)
        stored_token && Plug.Crypto.secure_compare(stored_token, state_token)
      end)

    if provider do
      # Get the PKCE code_verifier that was generated for this state
      code_verifier = Map.get(socket.assigns.provider_verifiers, state_token)
      config = Map.get(socket.assigns.provider_configs, provider.id)
      callback_url = url(~p"/auth/oidc/callback")

      # Exchange authorization code for tokens using PKCE
      case Web.OIDC.exchange_code_with_config(config, code, code_verifier, callback_url) do
        {:ok, tokens} ->
          case Web.OIDC.verify_token_with_config(config, tokens["id_token"]) do
            {:ok, claims} ->
              issuer = Map.get(claims, "iss")
              Logger.info("Provider #{provider.id} verified with issuer: #{issuer}")

              # Mark provider as verified
              provider_verifications =
                Map.put(socket.assigns.provider_verifications, provider.id, :verified)

              # Send success to the verification LiveView
              send(pid, :success)

              {:noreply, assign(socket, provider_verifications: provider_verifications)}

            {:error, reason} ->
              Logger.warning("Failed to verify ID token: #{inspect(reason)}")
              send(pid, {:error, reason})

              provider_verifications =
                Map.put(socket.assigns.provider_verifications, provider.id, :failed)

              {:noreply, assign(socket, provider_verifications: provider_verifications)}
          end

        {:error, reason} ->
          Logger.warning("Failed to fetch tokens: #{inspect(reason)}")
          send(pid, {:error, reason})

          provider_verifications =
            Map.put(socket.assigns.provider_verifications, provider.id, :failed)

          {:noreply, assign(socket, provider_verifications: provider_verifications)}
      end
    else
      Logger.warning("No provider found for verification token or token mismatch")
      send(pid, {:error, :provider_not_found})
      {:noreply, socket}
    end
  end

  # Clear default provider
  defp assign_default_provider("none", socket) do
    with {_count, nil} <- Auth.clear_default_provider(socket.assigns.subject),
         {:ok, providers, _metadata} <- Auth.list_providers(socket.assigns.subject) do
      socket =
        socket
        |> put_flash(:info, "Default authentication provider cleared")
        |> assign(default_provider_changed: false, providers: providers)

      {:noreply, socket}
    else
      error ->
        Logger.warning("Failed to clear default auth provider",
          error: inspect(error)
        )

        socket =
          socket
          |> put_flash(
            :error,
            "Failed to update default auth provider. Contact support if this issue persists."
          )

        {:noreply, socket}
    end
  end

  defp assign_default_provider(provider_id, socket) do
    provider =
      socket.assigns.providers
      |> Enum.find(fn provider -> provider.id == provider_id end)

    with true <- provider.adapter not in [:email, :userpass],
         {:ok, _provider} <- Auth.assign_default_provider(provider, socket.assigns.subject),
         {:ok, providers, _metadata} <- Auth.list_providers(socket.assigns.subject) do
      socket =
        socket
        |> put_flash(:info, "Default authentication provider set to #{provider.name}")
        |> assign(default_provider_changed: false, providers: providers)

      {:noreply, socket}
    else
      error ->
        Logger.warning("Failed to set default auth provider",
          error: inspect(error)
        )

        socket =
          socket
          |> put_flash(
            :error,
            "Failed to update default auth provider. Contact support if this issue persists."
          )

        {:noreply, socket}
    end
  end

  defp get_legacy_oidc_and_okta_providers(subject) do
    Auth.Provider.Query.all()
    |> Auth.Provider.Query.by_account_id(subject.account.id)
    |> Auth.Provider.Query.by_adapter({:in, [:openid_connect, :okta]})
    |> Domain.Repo.all()
  end

  defp all_providers_verified?([], _provider_verifications), do: true

  defp all_providers_verified?(providers, provider_verifications) do
    Enum.all?(providers, fn provider ->
      Map.get(provider_verifications, provider.id) == :verified
    end)
  end

  defp build_provider_verification_urls(providers, _account, provider_tokens) do
    callback_url = url(~p"/auth/oidc/callback")

    {urls, verifiers, configs} =
      Enum.reduce(providers, {%{}, %{}, %{}}, fn provider,
                                                 {urls_acc, verifiers_acc, configs_acc} ->
        token = Map.get(provider_tokens, provider.id)
        state = "oidc-verification:#{token}"
        verifier = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
        challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

        config = %{
          client_id: get_in(provider.adapter_config, ["client_id"]),
          client_secret: get_in(provider.adapter_config, ["client_secret"]),
          discovery_document_uri: get_in(provider.adapter_config, ["discovery_document_uri"]),
          redirect_uri: callback_url,
          response_type: "code",
          scope: "openid email profile"
        }

        oidc_params = %{
          state: state,
          code_challenge_method: :S256,
          code_challenge: challenge
        }

        case OpenIDConnect.authorization_uri(config, callback_url, oidc_params) do
          {:ok, uri} ->
            {
              Map.put(urls_acc, provider.id, uri),
              Map.put(verifiers_acc, token, verifier),
              Map.put(configs_acc, provider.id, config)
            }

          {:error, reason} ->
            Logger.warning(
              "Failed to build auth URI for provider #{provider.id}: #{inspect(reason)}"
            )

            {
              Map.put(urls_acc, provider.id, nil),
              verifiers_acc,
              configs_acc
            }
        end
      end)

    {urls, verifiers, configs}
  end
end

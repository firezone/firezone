defmodule Web.Settings.IdentityProviders.IndexNew do
  @moduledoc """
    The new identity provider settings UI for accounts that have migrated to the new authentication system.
  """

  use Web, :live_view

  alias Domain.{
    EmailOTP,
    Userpass,
    OIDC,
    Entra,
    Google,
    Okta
  }

  require Logger

  def mount(_params, _session, socket) do
    auth_providers = auth_providers(socket.assigns.account)
    directories = directories(socket.assigns.account)

    {:ok,
     assign(socket,
       provider_type: nil,
       auth_providers: auth_providers,
       directories: directories,
       provider: nil,
       directory: nil,
       create_step: 1,
       verification_token: nil,
       verification_url: nil,
       code_verifier: nil,
       provider_config: nil,
       verified_at: nil,
       form: nil,
       verification_loading: false,
       verification_error: nil
     )}
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/settings/identity_providers"}>
        Identity Providers Settings
      </.breadcrumb>
    </.breadcrumbs>
    <.section>
      <:title>Identity Providers</:title>
      <:action><.docs_action path="/guides/settings/identity-providers" /></:action>
      <:help>
        Identity providers authenticate and sync your users and groups with an external source.
      </:help>
      <:content>
        <.flash_group flash={@flash} />
      </:content>
    </.section>
    <.section>
      <:title>Authentication Providers</:title>
      <:action>
        <.add_button patch={~p"/#{@account}/settings/identity_providers/auth_providers/new"}>
          Add Provider
        </.add_button>
      </:action>
      <:content>
        <%= for provider <- @auth_providers.email_otp do %>
          <.auth_provider_item
            provider={provider}
            edit_path={
              ~p"/#{@account}/settings/identity_providers/email_otp_auth_providers/#{provider}/edit"
            }
          />
        <% end %>
        <%= for provider <- @auth_providers.userpass do %>
          <.auth_provider_item
            provider={provider}
            edit_path={
              ~p"/#{@account}/settings/identity_providers/userpass_auth_providers/#{provider}/edit"
            }
          />
        <% end %>
        <%= for provider <- @auth_providers.oidc do %>
          <.auth_provider_item
            provider={provider}
            edit_path={
              ~p"/#{@account}/settings/identity_providers/oidc_auth_providers/#{provider}/edit"
            }
          />
        <% end %>
        <%= for provider <- @auth_providers.google do %>
          <.auth_provider_item
            provider={provider}
            edit_path={
              ~p"/#{@account}/settings/identity_providers/google_auth_providers/#{provider}/edit"
            }
          />
        <% end %>
        <%= for provider <- @auth_providers.entra do %>
          <.auth_provider_item
            provider={provider}
            edit_path={
              ~p"/#{@account}/settings/identity_providers/entra_auth_providers/#{provider}/edit"
            }
          />
        <% end %>
        <%= for provider <- @auth_providers.okta do %>
          <.auth_provider_item
            provider={provider}
            edit_path={
              ~p"/#{@account}/settings/identity_providers/okta_auth_providers/#{provider}/edit"
            }
          />
        <% end %>
      </:content>
    </.section>
    <.section>
      <:title>Directories</:title>
      <:action>
        <.add_button patch={~p"/#{@account}/settings/identity_providers/directories/new"}>
          Add Directory
        </.add_button>
      </:action>
      <:content>
        <%= for directory <- @directories.google_directories do %>
          <.directory_item
            directory={directory}
            edit_path={
              ~p"/#{@account}/settings/identity_providers/google_directories/#{directory}/edit"
            }
          />
        <% end %>
        <%= for directory <- @directories.entra_directories do %>
          <.directory_item
            directory={directory}
            edit_path={
              ~p"/#{@account}/settings/identity_providers/entra_directories/#{directory}/edit"
            }
          />
        <% end %>
        <%= for directory <- @directories.okta_directories do %>
          <.directory_item
            directory={directory}
            edit_path={
              ~p"/#{@account}/settings/identity_providers/okta_directories/#{directory}/edit"
            }
          />
        <% end %>
      </:content>
    </.section>

    <.modal
      :if={@live_action == :new_auth_provider}
      id="new-auth-provider-modal"
      show={true}
      on_close="close_modal"
      on_back="back_auth_provider"
      on_confirm={if @create_step == 1, do: "next_auth_provider", else: nil}
      phx_submit={if @create_step == 2, do: "create_auth_provider", else: nil}
      confirm_type={if @create_step == 2, do: "submit", else: "button"}
      confirm_disabled={
        (@create_step == 1 and is_nil(@provider_type)) or
          (@create_step == 2 and @provider_type in ["oidc", "google", "entra", "okta"] and
             is_nil(@verified_at))
      }
    >
      <:title>
        <%= if @create_step == 1 do %>
          Add Authentication Provider
        <% else %>
          Configure {String.capitalize(@provider_type || "Provider")} Provider
        <% end %>
      </:title>
      <:body>
        <%= if @create_step == 1 do %>
          <p>Select an authentication provider type to add:</p>
          <ul class="grid w-full gap-6 grid-cols-1">
            <li>
              <div
                phx-click="select_provider_type"
                phx-value-provider_type="google"
                class={provider_selection_classes(@provider_type == "google")}
              >
                <span class="w-1/3 flex items-center">
                  <.provider_icon type={:google} class="w-10 h-10 inline-block mr-2" />
                  <span class="font-medium">
                    Google
                  </span>
                </span>
                <span class="w-2/3">
                  Authenticate users against a Google Workspace account.
                </span>
              </div>
            </li>
            <li>
              <div
                phx-click="select_provider_type"
                phx-value-provider_type="entra"
                class={provider_selection_classes(@provider_type == "entra")}
              >
                <span class="w-1/3 flex items-center">
                  <.provider_icon type={:entra} class="w-10 h-10 inline-block mr-2" />
                  <span class="font-medium">
                    Entra
                  </span>
                </span>
                <span class="w-2/3">
                  Authenticate users against a Microsoft Entra account.
                </span>
              </div>
            </li>
            <li>
              <div
                phx-click="select_provider_type"
                phx-value-provider_type="okta"
                class={provider_selection_classes(@provider_type == "okta")}
              >
                <span class="w-1/3 flex items-center">
                  <.provider_icon type={:okta} class="w-10 h-10 inline-block mr-2" />
                  <span class="font-medium">
                    Okta
                  </span>
                </span>
                <span class="w-2/3">
                  Authenticate users against an Okta account.
                </span>
              </div>
            </li>
            <li>
              <div
                phx-click="select_provider_type"
                phx-value-provider_type="oidc"
                class={provider_selection_classes(@provider_type == "oidc")}
              >
                <span class="w-1/3 flex items-center">
                  <.provider_icon type={:oidc} class="w-10 h-10 inline-block mr-2" />
                  <span class="font-medium">
                    OpenID Connect
                  </span>
                </span>
                <span class="w-2/3">
                  Authenticate users against an OpenID Connect compliant identity provider.
                </span>
              </div>
            </li>
          </ul>
        <% else %>
          <.auth_provider_form
            type={@provider_type}
            form={@form}
            verified_at={@verified_at}
          />
          <%= if @provider_type in ["oidc", "google", "entra", "okta"] do %>
            <div class="mt-6 p-4 border-2 border-accent-200 bg-accent-50 rounded-lg">
              <%= if @verification_error do %>
                <.flash kind={:error} class="mb-4">
                  {@verification_error}
                </.flash>
              <% end %>

              <div class="flex items-center justify-between">
                <div class="flex-1">
                  <h3 class="text-base font-semibold text-gray-900">Provider Verification</h3>
                  <p class="mt-1 text-sm text-gray-600">
                    Verify your provider configuration by signing in with your {String.capitalize(
                      @provider_type
                    )} account.
                  </p>
                </div>
                <div class="ml-4">
                  <%= cond do %>
                    <% @verification_loading -> %>
                      <.button style="primary" disabled>
                        <.icon name="hero-arrow-path" class="h-5 w-5 mr-2 animate-spin" /> Loading...
                      </.button>
                    <% @verified_at -> %>
                      <div class="flex items-center text-green-700 bg-green-100 px-4 py-2 rounded-md">
                        <.icon name="hero-check-circle" class="h-5 w-5 mr-2" />
                        <span class="font-medium">Verified</span>
                      </div>
                    <% @verification_url -> %>
                      <.button
                        style="primary"
                        icon="hero-arrow-top-right-on-square"
                        href={@verification_url}
                        target="_blank"
                      >
                        Verify Now
                      </.button>
                    <% true -> %>
                      <span class="text-sm text-red-600 font-medium">Configuration Error</span>
                  <% end %>
                </div>
              </div>

              <%= if @provider_type == "google" do %>
                <div class="mt-4 pt-4 border-t border-accent-300 space-y-3">
                  <div class="flex justify-between items-center">
                    <label class="text-sm font-medium text-neutral-700">Issuer</label>
                    <p class="text-base font-semibold text-neutral-900">
                      <%= if @form_fields[:issuer] in [nil, ""] do %>
                        {if @verified_at, do: "None", else: "Awaiting verification..."}
                      <% else %>
                        {@form_fields[:issuer]}
                      <% end %>
                    </p>
                  </div>
                  <div class="flex justify-between items-center">
                    <label class="text-sm font-medium text-neutral-700">Hosted Domain</label>
                    <div class="text-right">
                      <p class="text-base font-semibold text-neutral-900">
                        <%= if @form_fields[:hosted_domain] in [nil, ""] do %>
                          {if @verified_at, do: "None", else: "Awaiting verification..."}
                        <% else %>
                          {@form_fields[:hosted_domain]}
                        <% end %>
                      </p>
                      <% extracted_errors = extract_verification_errors(@form_errors) %>
                      <%= if extracted_errors[:hosted_domain] do %>
                        <p class="mt-1 text-sm text-red-600">
                          {extracted_errors[:hosted_domain]}
                        </p>
                      <% end %>
                    </div>
                  </div>
                </div>
              <% end %>
            </div>
          <% end %>
        <% end %>
      </:body>
      <:back_button :if={@create_step == 2}>
        Back
      </:back_button>
      <:confirm_button>
        <%= if @create_step == 1 do %>
          Next
        <% else %>
          Create
        <% end %>
      </:confirm_button>
    </.modal>

    <.modal
      :if={@live_action == :new_directory}
      id="new-directory-modal"
      show={true}
      on_close="close_modal"
    >
      <:title>Add Directory Provider</:title>
      <:body>
        <p>Select a directory provider type to add:</p>
        {# TODO: Add directory provider selection UI }
      </:body>
    </.modal>

    <.modal
      :if={
        @live_action in [
          :edit_email_otp_auth_provider,
          :edit_userpass_auth_provider,
          :edit_oidc_auth_provider,
          :edit_google_auth_provider,
          :edit_entra_auth_provider,
          :edit_okta_auth_provider
        ] && @provider
      }
      id="edit-auth-provider-modal"
      show={true}
      on_close="close_modal"
    >
      <:title>Edit {@provider.name}</:title>
      <:body>
        <p>Edit authentication provider form will go here</p>
        {# TODO: Add provider edit form }
      </:body>
    </.modal>

    <.modal
      :if={
        @live_action in [:edit_google_directory, :edit_entra_directory, :edit_okta_directory] &&
          @directory
      }
      id="edit-directory-modal"
      show={true}
      on_close="close_modal"
    >
      <:title>Edit {@directory.name}</:title>
      <:body>
        <p>Edit directory provider form will go here</p>
        {# TODO: Add directory edit form }
      </:body>
    </.modal>
    """
  end

  def handle_params(
        %{"provider_id" => provider_id},
        _url,
        %{assigns: %{live_action: live_action}} = socket
      ) do
    provider =
      case live_action do
        :edit_email_otp_auth_provider ->
          case EmailOTP.fetch_auth_provider_by_id(provider_id, socket.assigns.subject) do
            {:ok, provider} -> provider
            {:error, _} -> raise Web.LiveErrors.NotFoundError
          end

        :edit_userpass_auth_provider ->
          case Userpass.fetch_auth_provider_by_id(provider_id, socket.assigns.subject) do
            {:ok, provider} -> provider
            {:error, _} -> raise Web.LiveErrors.NotFoundError
          end

        :edit_oidc_auth_provider ->
          case OIDC.fetch_auth_provider_by_id(provider_id, socket.assigns.subject) do
            {:ok, provider} -> provider
            {:error, _} -> raise Web.LiveErrors.NotFoundError
          end

        :edit_google_auth_provider ->
          case Google.fetch_auth_provider_by_id(provider_id, socket.assigns.subject) do
            {:ok, provider} -> provider
            {:error, _} -> raise Web.LiveErrors.NotFoundError
          end

        :edit_entra_auth_provider ->
          case Entra.fetch_auth_provider_by_id(provider_id, socket.assigns.subject) do
            {:ok, provider} -> provider
            {:error, _} -> raise Web.LiveErrors.NotFoundError
          end

        :edit_okta_auth_provider ->
          case Okta.fetch_auth_provider_by_id(provider_id, socket.assigns.subject) do
            {:ok, provider} -> provider
            {:error, _} -> raise Web.LiveErrors.NotFoundError
          end

        _ ->
          raise Web.LiveErrors.NotFoundError
      end

    {:noreply, assign(socket, provider: provider)}
  end

  def handle_params(
        %{"directory_id" => directory_id},
        _url,
        %{assigns: %{live_action: live_action}} = socket
      ) do
    directory =
      case live_action do
        :edit_google_directory ->
          case Google.fetch_directory_by_id(directory_id, socket.assigns.subject) do
            {:ok, directory} -> directory
            {:error, _} -> raise Web.LiveErrors.NotFoundError
          end

        :edit_entra_directory ->
          case Entra.fetch_directory_by_id(directory_id, socket.assigns.subject) do
            {:ok, directory} -> directory
            {:error, _} -> raise Web.LiveErrors.NotFoundError
          end

        :edit_okta_directory ->
          case Okta.fetch_directory_by_id(directory_id, socket.assigns.subject) do
            {:ok, directory} -> directory
            {:error, _} -> raise Web.LiveErrors.NotFoundError
          end

        _ ->
          raise Web.LiveErrors.NotFoundError
      end

    {:noreply, assign(socket, directory: directory)}
  end

  def handle_params(_params, _url, socket) do
    {:noreply, assign(socket, provider: nil, directory: nil)}
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/settings/identity_providers")}
  end

  def handle_event("select_provider_type", %{"provider_type" => "google"}, socket) do
    changeset = Google.new_auth_provider()
    form = to_form(changeset)

    socket = assign(socket, provider_type: "google", form: form)
    {:noreply, socket}
  end

  def handle_event("select_provider_type", %{"provider_type" => provider_type}, socket) do
    socket = assign(socket, provider_type: provider_type, form: nil)
    {:noreply, socket}
  end

  def handle_event("update_context", %{"context" => context}, socket) do
    # Update the form_fields to track the current context for UI state
    form_fields = Map.put(socket.assigns.form_fields, :context, context)
    {:noreply, assign(socket, form_fields: form_fields)}
  end

  def handle_event("next_auth_provider", _params, socket) do
    # Move from step 1 (selection) to step 2 (form)
    # For OIDC providers, setup verification asynchronously
    if socket.assigns.provider_type in ["oidc", "google", "entra", "okta"] do
      # Set loading state immediately
      send(self(), :setup_verification)
      {:noreply, assign(socket, verification_loading: true, create_step: 2)}
    else
      {:noreply, assign(socket, create_step: 2)}
    end
  end

  def handle_event("back_auth_provider", _params, socket) do
    # Go back from step 2 (form) to step 1 (selection)
    {:noreply, assign(socket, create_step: 1, provider_type: nil, verified_at: nil)}
  end

  def handle_event("create_auth_provider", params, socket) do
    # Create the provider (only enabled after verification for OIDC)
    socket = create_provider(params, socket)
    {:noreply, socket}
  end

  defp provider_selection_classes(selected?) do
    [
      "component bg-white rounded p-4 flex items-center cursor-pointer",
      "border transition-colors",
      selected? && "border-accent-500 bg-accent-50",
      !selected? && "border-neutral-300 hover:border-neutral-400 hover:bg-neutral-50"
    ]
  end

  defp auth_provider_item(assigns) do
    ~H"""
    <div class="flex items-center justify-between py-2 border-b">
      <span>{@provider.name}</span>
      <.button size="xs" icon="hero-pencil" patch={@edit_path}>
        Edit
      </.button>
    </div>
    """
  end

  defp directory_item(assigns) do
    ~H"""
    <div class="flex items-center justify-between py-2 border-b">
      <span>{@directory.name}</span>
      <.button size="xs" icon="hero-pencil" patch={@edit_path}>
        Edit
      </.button>
    </div>
    """
  end

  defp auth_providers(account) do
    %{
      email_otp: EmailOTP.all_auth_providers_for_account!(account),
      userpass: Userpass.all_auth_providers_for_account!(account),
      oidc: OIDC.all_auth_providers_for_account!(account),
      entra: Entra.all_auth_providers_for_account!(account),
      google: Google.all_auth_providers_for_account!(account),
      okta: Okta.all_auth_providers_for_account!(account)
    }
  end

  defp directories(account) do
    %{
      entra_directories: Entra.all_directories_for_account!(account),
      google_directories: Google.all_directories_for_account!(account),
      okta_directories: Okta.all_directories_for_account!(account)
    }
  end

  defp auth_provider_form(%{type: "google"} = assigns) do
    assigns =
      assigns
      |> assign(:portal_only?, assigns.form[:context].value == "portal_only")
      |> assign_new(:verified_at, fn -> nil end)

    ~H"""
    <div class="space-y-4">
      <p class="text-sm text-gray-600">
        Configure your Google Workspace authentication provider. Users will sign in using their Google Workspace accounts.
      </p>

      <.input field={@form[:name]} type="text" label="Name" autocomplete="off" required />

      <div>
        <.input
          field={@form[:context]}
          type="select"
          label="Context"
          phx-change="update_context"
          options={[
            {"Clients and Portal", "clients_and_portal"},
            {"Clients Only", "clients_only"},
            {"Portal Only", "portal_only"}
          ]}
          required
        />
        <p class="mt-1 text-xs text-gray-500">
          Choose where this provider can be used for authentication
        </p>
      </div>

      <div>
        <.input
          field={@form[:assigned_default_at]}
          type="checkbox"
          name="default"
          label="Set as default provider"
          disabled={@portal_only?}
          class={@portal_only? && "cursor-not-allowed"}
        />
        <p class="mt-1 text-xs text-gray-500">
          <%= if @portal_only? do %>
            Portal-only providers cannot be set as default
          <% else %>
            When selected, users signing in from the Firezone client will be taken directly to this provider for authentication.
          <% end %>
        </p>
      </div>
    </div>
    """
  end

  defp auth_provider_form(%{type: "entra"} = assigns) do
    ~H"""
    <p>Entra Provider Form Goes Here</p>
    """
  end

  defp auth_provider_form(%{type: "okta"} = assigns) do
    ~H"""
    <p>Okta Provider Form Goes Here</p>
    """
  end

  defp auth_provider_form(%{type: "oidc"} = assigns) do
    ~H"""
    <p>OIDC Provider Form Goes Here</p>
    """
  end

  defp initialize_form_fields("google") do
    %{
      name: "Google",
      context: "clients_and_portal",
      hosted_domain: nil,
      issuer: nil,
      default: false
    }
  end

  defp initialize_form_fields("okta") do
    %{
      name: "Okta",
      org_domain: nil,
      client_id: nil,
      client_secret: nil
    }
  end

  defp initialize_form_fields("entra") do
    %{
      name: "Entra",
      tenant_id: nil
    }
  end

  defp initialize_form_fields("oidc") do
    %{
      name: "OpenID Connect",
      client_id: nil,
      client_secret: nil,
      discovery_document_uri: nil
    }
  end

  defp initialize_form_fields(_), do: %{}

  defp extract_form_errors(nil), do: %{}

  defp extract_form_errors(changeset) do
    changeset.errors
    |> Enum.into(%{})
    |> Map.new(fn {field, {msg, opts}} ->
      # Handle unique constraint errors with more context
      case Keyword.get(opts, :constraint) do
        :unique ->
          case Keyword.get(opts, :constraint_name) do
            "google_auth_providers_account_id_issuer_hosted_domain_index" ->
              {field, "A Google provider with this issuer and hosted domain already exists"}

            _ ->
              {field, msg}
          end

        _ ->
          {field, msg}
      end
    end)
  end

  defp extract_verification_errors(nil), do: %{}
  defp extract_verification_errors(changeset), do: extract_form_errors(changeset)

  defp setup_oidc_verification(socket) do
    callback_url = url(~p"/auth/oidc/callback")

    verification =
      Web.OIDC.setup_verification(
        socket.assigns.provider_type,
        callback_url,
        connected?: connected?(socket)
      )

    assign(socket,
      verification_token: verification.token,
      verification_url: verification.url,
      code_verifier: verification.verifier,
      provider_config: verification.config
    )
  end

  defp create_provider(params, %{assigns: %{provider_type: "google"}} = socket) do
    is_default = params["default"] == "true"

    attrs = %{
      name: params["name"],
      hosted_domain: socket.assigns.form_fields.hosted_domain,
      issuer: socket.assigns.form_fields.issuer,
      context: String.to_existing_atom(params["context"]),
      assigned_default_at: if(is_default, do: DateTime.utc_now(), else: nil)
    }

    case Domain.Google.create_auth_provider(attrs, socket.assigns.subject) do
      {:ok, provider} ->
        socket
        |> put_flash(:info, "#{provider.name} created successfully")
        |> push_patch(to: ~p"/#{socket.assigns.account}/settings/identity_providers")

      {:error, changeset} ->
        Logger.error("Failed to create provider. Changeset errors: #{inspect(changeset.errors)}")
        Logger.error("Full changeset: #{inspect(changeset)}")
        assign(socket, :form_errors, changeset)
    end
  end

  defp create_provider(_params, socket) do
    # For other provider types
    socket
    |> put_flash(:error, "Provider type not yet implemented")
  end

  def handle_info(:setup_verification, socket) do
    try do
      socket = setup_oidc_verification(socket)
      {:noreply, assign(socket, verification_loading: false, verification_error: nil)}
    rescue
      error ->
        Logger.error("Failed to setup OIDC verification: #{inspect(error)}")

        {:noreply,
         assign(socket,
           verification_loading: false,
           verification_error: "Failed to setup verification. Please try again."
         )}
    end
  end

  def handle_info({:oidc_verify, pid, code, state_token}, socket) do
    # Verify the state token matches
    stored_token = socket.assigns.verification_token

    if stored_token && Plug.Crypto.secure_compare(stored_token, state_token) do
      code_verifier = socket.assigns.code_verifier
      config = socket.assigns.provider_config
      callback_url = url(~p"/auth/oidc/callback")

      case Web.OIDC.verify_callback(config, code, code_verifier, callback_url) do
        {:ok, claims} ->
          Logger.info("Provider verified successfully")
          send(pid, :success)

          socket =
            socket
            |> assign(verified_at: DateTime.utc_now())
            |> assign(form_errors: nil)

          # Extract provider-specific fields from claims
          socket =
            case socket.assigns.provider_type do
              "google" ->
                form_fields =
                  socket.assigns.form_fields
                  |> Map.put(:hosted_domain, claims["hd"])
                  |> Map.put(:issuer, claims["iss"])

                assign(socket, form_fields: form_fields)

              _ ->
                socket
            end

          {:noreply, socket}

        {:error, reason} ->
          Logger.warning("Failed to verify provider: #{inspect(reason)}")
          send(pid, {:error, reason})
          {:noreply, socket}
      end
    else
      Logger.warning("Verification token mismatch")
      send(pid, {:error, :token_mismatch})
      {:noreply, socket}
    end
  end
end

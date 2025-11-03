defmodule Web.Settings.DirectorySync do
  use Web, :live_view

  alias Domain.{
    Entra,
    Google,
    Okta,
    Safe
  }

  import Ecto.Changeset

  require Logger

  @modules %{
    "entra" => Entra.Directory,
    "google" => Google.Directory,
    "okta" => Okta.Directory
  }

  @types Map.keys(@modules)

  @common_fields ~w[name issuer is_verified]a

  @fields %{
    Entra.Directory => @common_fields ++ ~w[tenant_id]a,
    Google.Directory => @common_fields ++ ~w[hosted_domain impersonation_email]a,
    Okta.Directory => @common_fields ++ ~w[okta_domain client_id private_key_jwk kid]a
  }

  def mount(_params, _session, socket) do
    {:ok, init(socket)}
  end

  defp init(socket) do
    subject = socket.assigns.subject

    directories =
      [
        Safe.scoped(subject) |> Safe.all(Entra.Directory),
        Safe.scoped(subject) |> Safe.all(Google.Directory),
        Safe.scoped(subject) |> Safe.all(Okta.Directory)
      ]
      |> List.flatten()

    assign(socket, directories: directories, verification_error: nil)
  end

  # New Directory
  def handle_params(%{"type" => type}, _url, %{assigns: %{live_action: :new}} = socket)
      when type in @types do
    schema = Map.get(@modules, type)
    struct = struct(schema)
    attrs = %{}
    changeset = changeset(struct, attrs)

    {:noreply, assign(socket, type: type, verifying: false, form: to_form(changeset))}
  end

  # Edit Directory
  def handle_params(
        %{"type" => type, "id" => id},
        _url,
        %{assigns: %{live_action: :edit}} = socket
      )
      when type in @types do
    schema = Map.get(@modules, type)
    directory = get_directory!(schema, id, socket.assigns.subject)
    changeset = changeset(directory, %{is_verified: true})

    {:noreply,
     assign(socket,
       directory_name: directory.name,
       verifying: false,
       type: type,
       form: to_form(changeset)
     )}
  end

  def handle_params(%{"type" => _type}, _url, _socket) do
    raise Web.LiveErrors.NotFoundError
  end

  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/settings/directory_sync")}
  end

  def handle_event("validate", %{"directory" => attrs}, socket) do
    changeset =
      socket.assigns.form.source
      |> clear_verification_if_trigger_fields_changed()
      |> apply_changes()
      |> changeset(attrs)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("start_verification", _params, %{assigns: %{type: "entra"}} = socket) do
    start_verification(socket)
  end

  def handle_event("start_verification", _params, socket) do
    send(self(), :do_verification)
    {:noreply, assign(socket, verifying: true)}
  end

  def handle_event("reset_verification", _params, socket) do
    changeset =
      socket.assigns.form.source
      |> delete_change(:is_verified)
      |> delete_change(:issuer)
      |> delete_change(:hosted_domain)
      |> delete_change(:tenant_id)
      |> apply_changes()
      |> changeset(%{
        "is_verified" => false,
        "issuer" => nil,
        "hosted_domain" => nil,
        "tenant_id" => nil
      })

    {:noreply, assign(socket, verification_error: nil, form: to_form(changeset))}
  end

  def handle_event("submit_directory", _params, socket) do
    submit_directory(socket)
  end

  def handle_event("delete_directory", %{"id" => id}, socket) do
    directory = socket.assigns.directories |> Enum.find(fn d -> d.id == id end)

    case delete_directory(directory, socket.assigns.subject) do
      {:ok, _directory} ->
        {:noreply,
         socket
         |> init()
         |> put_flash(:info, "Directory deleted successfully.")
         |> push_patch(to: ~p"/#{socket.assigns.account}/settings/directory_sync")}

      {:error, reason} ->
        Logger.error("Failed to delete directory: #{inspect(reason)}")
        {:noreply, put_flash(socket, :error, "Failed to delete directory.")}
    end
  end

  def handle_event("toggle_directory", %{"id" => id}, socket) do
    directory = socket.assigns.directories |> Enum.find(fn d -> d.id == id end)
    new_disabled_state = not directory.is_disabled

    # Set disabled_reason when disabling
    disabled_reason = if new_disabled_state, do: "Disabled by admin", else: nil

    changeset =
      directory
      |> Ecto.Changeset.change(is_disabled: new_disabled_state, disabled_reason: disabled_reason)

    case Safe.scoped(socket.assigns.subject) |> Safe.update(changeset) do
      {:ok, _directory} ->
        action = if new_disabled_state, do: "disabled", else: "enabled"

        {:noreply,
         socket
         |> init()
         |> put_flash(:info, "Directory #{action} successfully.")}

      {:error, reason} ->
        Logger.error("Failed to toggle directory: #{inspect(reason)}")
        {:noreply, put_flash(socket, :error, "Failed to update directory.")}
    end
  end

  def handle_info(:do_verification, socket) do
    start_verification(socket)
  end

  def handle_info({:entra_admin_consent, pid, tenant_id, state_token}, socket) do
    require Logger
    Logger.info("DirectorySync received entra_admin_consent: #{state_token}")

    :ok = Domain.PubSub.unsubscribe("entra-admin-consent:#{state_token}")

    stored_token = socket.assigns.verification.token
    Logger.info("Stored token: #{inspect(stored_token)}, Received token: #{state_token}")

    # Verify the state token matches
    if stored_token && Plug.Crypto.secure_compare(stored_token, state_token) do
      Logger.info("Token matches! Sending :success to pid #{inspect(pid)}")
      result = send(pid, :success)
      Logger.info("Send result: #{inspect(result)}")

      # After admin consent, verify we can actually access the directory using client credentials
      config = Domain.Config.fetch_env!(:domain, Entra.APIClient)
      client_id = config[:client_id]

      # Build issuer URL from tenant_id
      issuer = "https://login.microsoftonline.com/#{tenant_id}/v2.0"

      with {:ok, %Req.Response{status: 200, body: %{"access_token" => access_token}}} <-
             Entra.APIClient.get_access_token(tenant_id),
           {:ok, %Req.Response{status: 200, body: %{"value" => [service_principal | _]}}} <-
             Entra.APIClient.get_service_principal(access_token, client_id),
           {:ok, %Req.Response{status: 200, body: %{"value" => _assignments}}} <-
             Entra.APIClient.list_app_role_assignments(
               access_token,
               service_principal["id"]
             ) do
        attrs = %{
          "is_verified" => true,
          "issuer" => issuer,
          "tenant_id" => tenant_id
        }

        changeset =
          socket.assigns.form.source
          |> apply_changes()
          |> changeset(attrs)

        {:noreply, assign(socket, form: to_form(changeset), verification_error: nil)}
      else
        error ->
          msg = parse_entra_verification_error(error)
          {:noreply, assign(socket, verification_error: msg)}
      end
    else
      send(pid, {:error, :token_mismatch})
      error = "Failed to verify directory: token mismatch"
      {:noreply, assign(socket, verification_error: error)}
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/settings/directory_sync"}>
        Directory Sync Settings
      </.breadcrumb>
    </.breadcrumbs>
    <.section>
      <:title>Directories</:title>
      <:action><.docs_action path="/guides/settings/directory-sync" /></:action>
      <:action>
        <.add_button patch={~p"/#{@account}/settings/directory_sync/select_type"}>
          Add Directory
        </.add_button>
      </:action>
      <:help>
        Directories sync users and groups from an external source.
      </:help>
      <:content>
        <.flash_group flash={@flash} />
      </:content>
      <:content>
        <div class="flex flex-wrap gap-4">
          <%= for directory <- @directories do %>
            <.directory_card
              type={directory_type(directory)}
              account={@account}
              directory={directory}
            />
          <% end %>
        </div>
      </:content>
    </.section>

    <!-- Select Directory Type Modal -->
    <.modal :if={@live_action == :select_type} id="select-directory-type-modal" on_close="close_modal">
      <:title>Select Directory Type</:title>
      <:body>
        <p class="mb-4 text-base text-neutral-700">
          Select a directory type to add:
        </p>
        <ul class="grid w-full gap-4 grid-cols-1">
          <li>
            <.link
              patch={~p"/#{@account}/settings/directory_sync/google/new"}
              class={select_type_classes()}
            >
              <span class="w-1/3 flex items-center">
                <.provider_icon type="google" class="w-10 h-10 inline-block mr-2" />
                <span class="font-medium"> Google </span>
              </span>
              <span class="w-2/3"> Sync users and groups from Google Workspace. </span>
            </.link>
          </li>
          <li>
            <.link
              patch={~p"/#{@account}/settings/directory_sync/entra/new"}
              class={select_type_classes()}
            >
              <span class="w-1/3 flex items-center">
                <.provider_icon type="entra" class="w-10 h-10 inline-block mr-2" />
                <span class="font-medium"> Entra </span>
              </span>
              <span class="w-2/3"> Sync users and groups from Microsoft Entra ID. </span>
            </.link>
          </li>
          <li>
            <.link
              patch={~p"/#{@account}/settings/directory_sync/okta/new"}
              class={select_type_classes()}
            >
              <span class="w-1/3 flex items-center">
                <.provider_icon type="okta" class="w-10 h-10 inline-block mr-2" />
                <span class="font-medium">Okta</span>
              </span>
              <span class="w-2/3">Sync users and groups from Okta. </span>
            </.link>
          </li>
        </ul>
      </:body>
    </.modal>

    <!-- New Directory Modal -->
    <.modal
      :if={@live_action == :new}
      id="new-directory-modal"
      on_close="close_modal"
      confirm_disabled={not @form.source.valid?}
    >
      <:title icon={@type}>Add {titleize(@type)} Directory</:title>
      <:body>
        <.directory_form
          verification_error={@verification_error}
          verifying={assigns[:verifying] || false}
          form={@form}
          type={@type}
          submit_event="submit_directory"
        />
      </:body>
      <:confirm_button form="directory-form" type="submit">Create</:confirm_button>
    </.modal>

    <!-- Edit Directory Modal -->
    <.modal
      :if={@live_action == :edit}
      id="edit-directory-modal"
      on_close="close_modal"
      confirm_disabled={not @form.source.valid? or Enum.empty?(@form.source.changes)}
    >
      <:title icon={@type}>Edit {@directory_name}</:title>
      <:body>
        <.directory_form
          verification_error={@verification_error}
          verifying={assigns[:verifying] || false}
          form={@form}
          type={@type}
          submit_event="submit_directory"
        />
      </:body>
      <:confirm_button
        form="directory-form"
        type="submit"
      >
        Save
      </:confirm_button>
    </.modal>
    """
  end

  defp directory_card(assigns) do
    ~H"""
    <div class="flex flex-col bg-neutral-50 rounded-lg p-4 w-96">
      <div class="flex items-center justify-between mb-3">
        <div class="flex items-center flex-1 min-w-0">
          <.provider_icon type={@type} class="w-7 h-7 mr-2 flex-shrink-0" />
          <span class="font-normal text-lg truncate" title={@directory.name}>
            {@directory.name}
          </span>
        </div>
        <div class="flex items-center">
          <.button_with_confirmation
            id={"toggle-directory-#{@directory.id}"}
            on_confirm="toggle_directory"
            on_confirm_id={@directory.id}
            class="p-0 border-0 bg-transparent shadow-none hover:bg-transparent"
          >
            <.toggle
              id={"directory-toggle-#{@directory.id}"}
              checked={not @directory.is_disabled}
            />
            <:dialog_title>
              {if @directory.is_disabled, do: "Enable", else: "Disable"} Directory
            </:dialog_title>
            <:dialog_content>
              <p>
                Are you sure you want to {if @directory.is_disabled, do: "enable", else: "disable"} <strong>{@directory.name}</strong>?
              </p>
              <%= if not @directory.is_disabled do %>
                <p class="mt-2">
                  This directory will no longer sync while disabled.
                </p>
              <% end %>
            </:dialog_content>
            <:dialog_confirm_button>
              {if @directory.is_disabled, do: "Enable", else: "Disable"}
            </:dialog_confirm_button>
            <:dialog_cancel_button>Cancel</:dialog_cancel_button>
          </.button_with_confirmation>
          <.popover placement="bottom" trigger="click">
            <:target>
              <button
                type="button"
                class="p-1 text-neutral-500 hover:text-neutral-700 rounded"
              >
                <.icon name="hero-ellipsis-horizontal" class="text-neutral-800 w-5 h-5" />
              </button>
            </:target>
            <:content>
              <div class="flex flex-col py-1">
                <.link
                  patch={~p"/#{@account}/settings/directory_sync/#{@type}/#{@directory.id}/edit"}
                  class="px-4 py-2 text-sm text-neutral-800 rounded-lg hover:bg-neutral-100 flex items-center gap-2"
                >
                  <.icon name="hero-pencil" class="w-4 h-4" /> Edit
                </.link>
                <.button_with_confirmation
                  id={"delete-directory-#{@directory.id}"}
                  on_confirm="delete_directory"
                  on_confirm_id={@directory.id}
                  class="w-full px-4 py-2 text-sm text-red-600 rounded-lg flex items-center gap-2 text-left border-0 bg-transparent"
                >
                  <.icon name="hero-trash" class="w-4 h-4" /> Delete
                  <:dialog_title>Delete Directory</:dialog_title>
                  <:dialog_content>
                    Are you sure you want to delete <strong>{@directory.name}</strong>?
                    This action cannot be undone.
                  </:dialog_content>
                  <:dialog_confirm_button>Delete</:dialog_confirm_button>
                  <:dialog_cancel_button>Cancel</:dialog_cancel_button>
                </.button_with_confirmation>
              </div>
            </:content>
          </.popover>
        </div>
      </div>

      <div class="mt-auto bg-white rounded-lg p-3 space-y-3 text-sm text-neutral-600">
        <div :if={Map.get(@directory, :issuer)} class="flex items-center gap-2 min-w-0">
          <.icon name="hero-identification" class="w-5 h-5 flex-shrink-0" title="Issuer" />
          <span class="truncate font-medium" title={@directory.issuer}>{@directory.issuer}</span>
        </div>

        <div class="flex items-center gap-2">
          <.icon name="hero-clock" class="w-5 h-5" />
          <span class="font-medium">
            updated <.relative_datetime datetime={@directory.updated_at} />
          </span>
        </div>
      </div>
    </div>
    """
  end

  defp directory_form(assigns) do
    ~H"""
    <.form
      id="directory-form"
      for={@form}
      phx-change="validate"
      phx-submit={@submit_event}
    >
      <div class="space-y-6">
        <div>
          <.input
            field={@form[:name]}
            type="text"
            label="Name"
            autocomplete="off"
            phx-debounce="300"
            data-1p-ignore
            required
          />
          <p class="mt-1 text-xs text-neutral-600">
            Enter a name to identify this directory.
          </p>
        </div>

        <div :if={@type == "google"}>
          <.input
            field={@form[:impersonation_email]}
            type="text"
            label="Impersonation Email"
            autocomplete="off"
            phx-debounce="300"
            data-1p-ignore
            required
          />
          <p class="mt-1 text-xs text-neutral-600">
            Enter the admin email address to impersonate for directory sync.
          </p>
        </div>

        <div :if={@type == "okta"}>
          <.input
            field={@form[:okta_domain]}
            type="text"
            label="Okta Domain"
            autocomplete="off"
            phx-debounce="300"
            data-1p-ignore
            required
          />
          <p class="mt-1 text-xs text-neutral-600">
            Enter your fully-qualified Okta organization domain (e.g., example.okta.com).
          </p>
        </div>

        <div :if={@type == "okta"}>
          <.input
            field={@form[:client_id]}
            type="text"
            label="Client ID"
            autocomplete="off"
            phx-debounce="300"
            data-1p-ignore
            required
          />
          <p class="mt-1 text-xs text-neutral-600">
            Enter the Client ID from your Okta application settings.
          </p>
        </div>

        <div
          :if={@type in ["google", "entra", "okta"]}
          class="p-4 border-2 border-accent-200 bg-accent-50 rounded-lg"
        >
          <.flash :if={@verification_error} kind={:error}>
            {@verification_error}
          </.flash>
          <div class="flex items-center justify-between">
            <div class="flex-1">
              <h3 class="text-base font-semibold text-neutral-900">Directory Verification</h3>
              <p class="mt-1 text-sm text-neutral-600">
                {verification_help_text(@form, @type)}
              </p>
            </div>
            <div class="ml-4">
              <.verification_status_badge
                id="verify-button"
                form={@form}
                verifying={@verifying}
                type={@type}
              />
            </div>
          </div>

          <div class="mt-4 pt-4 border-t border-accent-300 space-y-3">
            <.verification_fields_status type={@type} form={@form} />
            <.reset_verification_button form={@form} />
          </div>
        </div>
      </div>
    </.form>
    """
  end

  defp verification_help_text(form, type) do
    if verified?(form) do
      "This directory has been successfully verified."
    else
      "Verify your directory configuration by signing in with your #{titleize(type)} account."
    end
  end

  defp verification_status_badge(assigns) do
    # Entra opens a new window, so show the arrow icon and use OpenURL hook
    # Google/Okta are server-side only, no icon or hook needed
    button_attrs =
      if assigns.type == "entra" do
        [icon: "hero-arrow-top-right-on-square", "phx-hook": "OpenURL"]
      else
        []
      end

    assigns = assign(assigns, :button_attrs, button_attrs)

    ~H"""
    <div
      :if={verified?(@form)}
      class="flex items-center text-green-700 bg-green-100 px-4 py-2 rounded-md"
    >
      <.icon name="hero-check-circle" class="h-5 w-5 mr-2" />
      <span class="font-medium">Verified</span>
    </div>
    <.button
      :if={not verified?(@form) and ready_to_verify?(@form) and not @verifying}
      type="button"
      id={@id <> "-verify-button"}
      style="primary"
      phx-click="start_verification"
      {@button_attrs}
    >
      Verify Now
    </.button>
    <.button
      :if={not verified?(@form) and @verifying}
      type="button"
      style="primary"
      disabled
    >
      Verifying...
    </.button>
    <.button
      :if={not verified?(@form) and not ready_to_verify?(@form)}
      type="button"
      style="primary"
      disabled
    >
      Verify Now
    </.button>
    """
  end

  defp verification_fields_status(assigns) do
    fields =
      case assigns.type do
        "google" -> [:issuer, :hosted_domain]
        "entra" -> [:issuer, :tenant_id]
        "okta" -> [:issuer]
      end

    assigns = assign(assigns, :fields, fields)

    ~H"""
    <%= for field <- @fields do %>
      <div class="flex justify-between items-center">
        <label class="text-sm font-medium text-neutral-700">{Phoenix.Naming.humanize(field)}</label>
        <div class="text-right">
          <p class="text-sm font-semibold text-neutral-900">
            {verification_field_display(@form.source, field)}
          </p>
        </div>
      </div>
    <% end %>
    """
  end

  defp verification_field_display(changeset, field) do
    if get_field(changeset, :is_verified) do
      get_field(changeset, field)
    else
      "Awaiting verification..."
    end
  end

  defp reset_verification_button(assigns) do
    ~H"""
    <div :if={verified?(@form)} class="text-right">
      <button
        type="button"
        phx-click="reset_verification"
        class="text-sm text-neutral-600 hover:text-neutral-700 underline"
        title="Reset verification to reverify credentials"
      >
        Reset verification
      </button>
    </div>
    """
  end

  defp verified?(form) do
    get_field(form.source, :is_verified) == true
  end

  defp ready_to_verify?(form) do
    Enum.all?(form.source.errors, fn
      {excluded, _errors} when excluded in [:is_verified, :issuer, :hosted_domain, :tenant_id] ->
        true

      {_field, _errors} ->
        false
    end)
  end

  defp select_type_classes do
    ~w[
      component bg-white rounded-lg p-4 flex items-center cursor-pointer
      border-2 transition-all duration-150
      border-neutral-200 hover:border-accent-300 hover:bg-neutral-50 hover:shadow-sm
    ]
  end

  defp titleize("google"), do: "Google"
  defp titleize("entra"), do: "Microsoft Entra"
  defp titleize("okta"), do: "Okta"

  defp directory_type(module) do
    cond do
      module.__struct__ == Entra.Directory -> "entra"
      module.__struct__ == Google.Directory -> "google"
      module.__struct__ == Okta.Directory -> "okta"
      true -> "unknown"
    end
  end

  defp submit_directory(%{assigns: %{live_action: :new, form: %{source: changeset}}} = socket) do
    Safe.scoped(socket.assigns.subject)
    |> Safe.insert(changeset)
    |> handle_submit(socket)
  end

  defp submit_directory(%{assigns: %{live_action: :edit, form: %{source: changeset}}} = socket) do
    Safe.scoped(socket.assigns.subject)
    |> Safe.update(changeset)
    |> handle_submit(socket)
  end

  defp handle_submit({:ok, _directory}, socket) do
    {:noreply,
     socket
     |> init()
     |> put_flash(:info, "Directory saved successfully.")
     |> push_patch(to: ~p"/#{socket.assigns.account}/settings/directory_sync")}
  end

  defp handle_submit({:error, changeset}, socket) do
    verification_error = verification_errors(changeset)
    {:noreply, assign(socket, verification_error: verification_error, form: to_form(changeset))}
  end

  defp verification_errors(changeset) do
    changeset.errors
    |> Enum.filter(fn {field, _error} -> field in [:hosted_domain, :issuer, :tenant_id] end)
    |> Enum.map(fn {_field, {message, _opts}} -> message end)
    |> Enum.join(" ")
  end

  defp delete_directory(directory, subject) do
    Safe.scoped(subject) |> Safe.delete(directory)
  end

  defp get_directory!(schema, id, subject) do
    import Ecto.Query

    query = from(d in schema, where: d.id == ^id)
    Safe.scoped(subject) |> Safe.one!(query)
  end

  defp start_verification(%{assigns: %{type: "google"}} = socket) do
    changeset = socket.assigns.form.source
    impersonation_email = get_field(changeset, :impersonation_email)

    with {:ok, %Req.Response{status: 200, body: %{"access_token" => access_token}}} <-
           Google.APIClient.get_access_token(impersonation_email),
         {:ok, %Req.Response{status: 200, body: body}} <-
           Google.APIClient.get_customer(access_token) do
      changeset =
        changeset
        |> put_change(:hosted_domain, body["customerDomain"])
        |> put_change(:issuer, "https://accounts.google.com")
        |> put_change(:is_verified, true)

      {:noreply,
       assign(socket, form: to_form(changeset), verification_error: nil, verifying: false)}
    else
      error ->
        msg = parse_google_verification_error(error)
        {:noreply, assign(socket, verification_error: msg, verifying: false)}
    end
  end

  defp start_verification(%{assigns: %{type: "entra"}} = socket) do
    # For Entra directory sync, we use the admin consent endpoint which pre-checks
    # "Consent on behalf of your organization" and grants application permissions:
    # - Directory.Read.All: Read users, groups, and directory data
    # - Application.Read.All: Read service principal and app role assignments (for group assignment)

    token = Domain.Crypto.random_token(32)
    state = "entra-admin-consent:#{token}"

    config = Domain.Config.fetch_env!(:domain, Entra.APIClient)
    client_id = config[:client_id]

    # Build admin consent URL
    # Note: We use "organizations" which works for any organizational tenant
    redirect_uri = url(~p"/verification")

    # Admin consent endpoint requires scope parameter with the permissions we're requesting
    scope =
      "https://graph.microsoft.com/Directory.Read.All https://graph.microsoft.com/Application.Read.All"

    params = %{
      client_id: client_id,
      state: state,
      redirect_uri: redirect_uri,
      scope: scope
    }

    query_string = URI.encode_query(params)

    admin_consent_url =
      "https://login.microsoftonline.com/organizations/v2.0/adminconsent?#{query_string}"

    :ok = Domain.PubSub.subscribe("entra-admin-consent:#{token}")

    verification = %{token: token, url: admin_consent_url}

    {:noreply,
     socket
     |> assign(verification: verification)
     |> push_event("open_url", %{url: admin_consent_url})}
  end

  defp start_verification(%{assigns: %{type: "okta"}} = socket) do
    {:noreply, assign(socket, verifying: false)}
  end

  defp clear_verification_if_trigger_fields_changed(changeset) do
    fields = [:impersonation_email, :okta_domain, :client_id, :tenant_id]

    if Enum.any?(fields, &get_change(changeset, &1)) do
      put_change(changeset, :is_verified, false)
    else
      changeset
    end
  end

  defp changeset(struct, attrs) do
    schema = struct.__struct__

    cast(struct, attrs, Map.get(@fields, schema))
    |> schema.changeset()
  end

  defp generate_okta_keypair do
    keypair = Domain.Crypto.JWK.generate_jwk_and_jwks()
    %{"private_key_jwk" => keypair.jwk, "kid" => keypair.kid}
  end

  defp parse_google_verification_error({:ok, %Req.Response{status: 401, body: body}}) do
    body["error_description"] ||
      "HTTP 401 error during verification. Ensure all scopes are granted for the service account."
  end

  defp parse_google_verification_error({:ok, %Req.Response{status: 403, body: body}}) do
    get_in(body, ["error", "message"]) ||
      "HTTP 403 error during verification. Ensure the service account has admin privileges and the admin SDK API is enabled."
  end

  defp parse_google_verification_error({:ok, %Req.Response{status: status}})
       when status >= 500 do
    "Google service is currently unavailable (HTTP #{status}). Please try again later."
  end

  defp parse_google_verification_error(error) do
    Logger.error("Unknown Google verification error", error: inspect(error))

    "Unknown error during verification. Please try again. If the problem persists, contact support."
  end

  defp parse_entra_verification_error({:ok, %Req.Response{status: 401, body: body}}) do
    # OAuth token endpoint error format
    error_description = body["error_description"] || body["error"] || "Unauthorized"

    "HTTP 401 error during verification: #{error_description}. Ensure the client credentials are correct."
  end

  defp parse_entra_verification_error({:ok, %Req.Response{status: 403, body: body}}) do
    # Microsoft Graph API error format
    error_message = get_in(body, ["error", "message"]) || "Forbidden"
    "HTTP 403 error during verification: #{error_message}"
  end

  defp parse_entra_verification_error({:ok, %Req.Response{status: status}})
       when status >= 500 do
    "Microsoft service is currently unavailable (HTTP #{status}). Please try again later."
  end

  defp parse_entra_verification_error(error) do
    Logger.error("Unknown Entra verification error", error: inspect(error))

    "Unknown error during verification. Please try again. If the problem persists, contact support."
  end
end

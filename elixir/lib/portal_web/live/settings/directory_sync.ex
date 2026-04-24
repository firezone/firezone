defmodule PortalWeb.Settings.DirectorySync do
  use PortalWeb, :live_view

  alias Portal.{
    Crypto.JWK,
    Entra,
    Google,
    Okta,
    PubSub
  }

  alias __MODULE__.Database

  import Ecto.Changeset

  require Logger

  @modules %{
    "entra" => Entra.Directory,
    "google" => Google.Directory,
    "okta" => Okta.Directory
  }

  @types Map.keys(@modules)

  @select_type_classes [
    "flex items-center w-full p-4 rounded border transition-colors cursor-pointer",
    "border-[var(--border)] bg-[var(--surface)]",
    "hover:bg-[var(--surface-raised)] hover:border-[var(--border-emphasis)]"
  ]

  @common_fields ~w[name is_disabled disabled_reason is_verified error_message]a

  @fields %{
    Entra.Directory => @common_fields ++ ~w[tenant_id sync_all_groups email_field]a,
    Google.Directory =>
      @common_fields ++ ~w[domain impersonation_email group_sync_mode orgunit_sync_enabled]a,
    Okta.Directory => @common_fields ++ ~w[okta_domain client_id private_key_jwk kid]a
  }

  # Fields set programmatically (not via HTML form inputs) that must be
  # preserved across validate events so they aren't lost on each keystroke.
  @programmatic_fields ~w[is_verified private_key_jwk kid tenant_id domain]a

  def mount(_params, _session, socket) do
    socket = assign(socket, page_title: "Directory Sync")

    if connected?(socket) do
      :ok = PubSub.Changes.subscribe(socket.assigns.subject.account.id)
    end

    {:ok, init(socket, new: true)}
  end

  defp init(socket, opts \\ []) do
    new = Keyword.get(opts, :new, false)
    directories = Database.list_all_directories(socket.assigns.subject)

    if new do
      socket
      |> assign_new(:directories, fn -> directories end)
      |> assign_new(:verification_error, fn -> nil end)
    else
      assign(socket, directories: directories, verification_error: nil)
    end
  end

  # New Directory
  def handle_params(%{"type" => type}, _url, %{assigns: %{live_action: :new}} = socket)
      when type in @types do
    schema = Map.get(@modules, type)
    struct = struct(schema)
    attrs = %{}
    changeset = changeset(struct, attrs)

    {:noreply,
     assign(socket,
       type: type,
       verification_error: nil,
       verifying: false,
       form: to_form(changeset),
       public_jwk: nil
     )}
  end

  # Edit Directory
  def handle_params(
        %{"type" => type, "id" => id},
        _url,
        %{assigns: %{live_action: :edit}} = socket
      )
      when type in @types do
    schema = Map.get(@modules, type)
    directory = Database.get_directory!(schema, id, socket.assigns.subject)
    changeset = changeset(directory, %{})

    # Extract public key if this is an Okta directory with a keypair
    public_jwk =
      if type == "okta" && directory.private_key_jwk do
        JWK.extract_public_key_components(directory.private_key_jwk)
      else
        nil
      end

    # Check if this is a legacy Google directory (has legacy_service_account_key)
    is_legacy =
      type == "google" && directory.legacy_service_account_key != nil

    {:noreply,
     assign(socket,
       directory: directory,
       directory_name: directory.name,
       verifying: false,
       type: type,
       form: to_form(changeset),
       public_jwk: public_jwk,
       is_legacy: is_legacy
     )}
  end

  def handle_params(%{"type" => _type}, _url, _socket) do
    raise PortalWeb.LiveErrors.NotFoundError
  end

  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  def handle_event("close_panel", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/settings/directory_sync")}
  end

  def handle_event("handle_keydown", %{"key" => "Escape"}, socket)
      when socket.assigns.live_action in [:select_type, :new, :edit] do
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/settings/directory_sync")}
  end

  def handle_event("handle_keydown", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("validate", %{"directory" => attrs}, socket) do
    changeset = socket.assigns.form.source
    attrs = preserve_programmatic_fields(changeset, attrs)

    # EDIT: .data (original directory) so changes are relative to DB values (UPDATE semantics).
    # NEW: apply_changes() to capture all current values (INSERT semantics).
    base =
      if socket.assigns.live_action == :edit do
        changeset.data
      else
        apply_changes(changeset)
      end

    changeset =
      base
      |> changeset(attrs)
      |> clear_verification_if_trigger_fields_changed()
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("generate_keypair", _params, socket) do
    # Generate the keypair
    keypair = JWK.generate_jwk_and_jwks()

    # Update the changeset with the private key JWK and kid
    changeset =
      socket.assigns.form.source
      |> apply_changes()
      |> changeset(%{
        "private_key_jwk" => keypair.jwk,
        "kid" => keypair.kid
      })

    # Extract the public key for display
    public_jwk = JWK.extract_public_key_components(keypair.jwk)

    {:noreply, assign(socket, form: to_form(changeset), public_jwk: public_jwk)}
  end

  def handle_event("start_verification", _params, %{assigns: %{type: "entra"}} = socket) do
    start_verification(socket)
  end

  def handle_event("start_verification", _params, socket) do
    send(self(), :do_verification)
    {:noreply, assign(socket, verifying: true)}
  end

  def handle_event("reset_verification", _params, socket) do
    # For EDIT: Use .data (original directory) so changes are tracked relative to DB values.
    # For NEW: Use apply_changes to preserve programmatically set fields (like Okta's keypair).
    changeset = socket.assigns.form.source

    base =
      if socket.assigns.live_action == :edit do
        changeset.data
      else
        apply_changes(changeset)
      end

    # Start with current changes, drop verification fields, add verification resets.
    # This preserves programmatic fields (like Okta's keypair) and form field changes.
    attrs =
      changeset.changes
      |> Map.drop([:is_verified, :domain, :tenant_id, :okta_domain])
      |> Map.put(:is_verified, false)
      |> Map.put(:domain, nil)
      |> Map.put(:tenant_id, nil)
      |> Map.put(:okta_domain, nil)
      |> Map.new(fn {k, v} -> {to_string(k), v} end)

    changeset = changeset(base, attrs)

    {:noreply, assign(socket, verification_error: nil, form: to_form(changeset))}
  end

  def handle_event("submit_directory", _params, socket) do
    submit_directory(socket)
  end

  def handle_event("delete_directory", %{"id" => id}, socket) do
    directory = socket.assigns.directories |> Enum.find(fn d -> d.id == id end)

    case Database.delete_directory(directory, socket.assigns.subject) do
      {:ok, _directory} ->
        {:noreply,
         socket
         |> init()
         |> put_flash(:success, "Directory deleted successfully.")
         |> push_patch(to: ~p"/#{socket.assigns.account}/settings/directory_sync")}

      {:error, reason} ->
        Logger.info("Failed to delete directory: #{inspect(reason)}")
        {:noreply, put_flash(socket, :error, "Failed to delete directory.")}
    end
  end

  def handle_event("toggle_directory", %{"id" => id}, socket) do
    directory = socket.assigns.directories |> Enum.find(fn d -> d.id == id end)
    new_disabled_state = not directory.is_disabled
    account = socket.assigns.account

    # Check if trying to enable a directory without the IDP_SYNC feature
    if new_disabled_state == false && not account.features.idp_sync do
      {:noreply,
       put_flash(
         socket,
         :error,
         "Directory sync is available on the Enterprise plan. Please upgrade your plan."
       )}
    else
      changeset = toggle_directory_changeset(directory, new_disabled_state)
      action = if(new_disabled_state, do: "disabled", else: "enabled")

      case Database.update_directory(changeset, socket.assigns.subject) do
        {:ok, _directory} ->
          {:noreply,
           socket
           |> init()
           |> put_flash(:success, "Directory #{action} successfully.")}

        {:error, reason} ->
          Logger.info("Failed to toggle directory: #{inspect(reason)}")
          {:noreply, put_flash(socket, :error, "Failed to update directory.")}
      end
    end
  end

  def handle_event("sync_directory", %{"id" => id, "type" => type}, socket) do
    sync_module =
      case type do
        "entra" -> Portal.Entra.Sync
        "google" -> Portal.Google.Sync
        "okta" -> Portal.Okta.Sync
        _ -> raise "Unsupported directory type for sync: #{type}"
      end

    case Oban.insert(sync_module.new(%{"directory_id" => id})) do
      {:ok, _job} ->
        socket =
          socket
          |> init()
          |> put_flash(:success, "Directory sync has been queued successfully.")

        {:noreply, socket}

      {:error, reason} ->
        Logger.info("Failed to enqueue #{type} sync job", id: id, reason: inspect(reason))
        {:noreply, put_flash(socket, :error, "Failed to queue directory sync.")}
    end
  end

  defp toggle_directory_changeset(directory, true) do
    changeset(directory, %{
      "is_disabled" => true,
      "disabled_reason" => "Disabled by admin"
    })
  end

  defp toggle_directory_changeset(directory, false) do
    if directory.is_verified do
      changeset(directory, %{
        "is_disabled" => false,
        "disabled_reason" => nil,
        "error_email_count" => 0,
        "error_message" => nil,
        "errored_at" => nil
      })
    else
      changeset(directory, %{})
      |> Ecto.Changeset.add_error(
        :is_verified,
        "Directory must be verified before enabling"
      )
    end
  end

  def handle_info(:do_verification, socket) do
    start_verification(socket)
  end

  # Sent directly by the Entra directory_sync verification controller
  def handle_info({:entra_directory_sync_complete, tenant_id, ack_to}, socket) do
    # For EDIT: Use .data (original directory) so changes are tracked relative to DB values.
    # For NEW: Entra has no programmatically set fields, so .data works here too.
    changeset = socket.assigns.form.source

    attrs =
      changeset.changes
      |> Map.put(:is_verified, true)
      |> Map.put(:tenant_id, tenant_id)

    changeset = changeset(changeset.data, attrs)
    maybe_send_verification_ack(ack_to)

    {:noreply, assign(socket, form: to_form(changeset), verification_error: nil)}
  end

  def handle_info({:entra_directory_sync_complete, tenant_id}, socket) do
    handle_info({:entra_directory_sync_complete, tenant_id, nil}, socket)
  end

  # Sent directly by the verification controller on any failure
  def handle_info({:verification_failed, reason}, socket) do
    {:noreply, assign(socket, verification_error: format_verification_error_reason(reason))}
  end

  def handle_info(:directories_changed, socket) do
    {:noreply, init(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp maybe_send_verification_ack({pid, ref}) when is_pid(pid) do
    send(pid, {:verification_ack, ref})
    :ok
  end

  defp maybe_send_verification_ack(_), do: :ok

  defp format_verification_error_reason(reason) when is_binary(reason), do: reason
  defp format_verification_error_reason(reason), do: inspect(reason)

  defp verification_start_error_message({status, _body}) when is_integer(status) do
    "Failed to fetch discovery document (HTTP #{status}). Please verify your provider configuration."
  end

  defp verification_start_error_message(%Req.TransportError{reason: reason}) do
    "Unable to fetch discovery document: #{inspect(reason)}."
  end

  defp verification_start_error_message(reason) when is_binary(reason), do: reason
  defp verification_start_error_message(_reason), do: "Failed to start verification."

  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-full">
      <.settings_nav account={@account} current_path={@current_path} />

      <%= if Portal.Account.idp_sync_enabled?(@account) do %>
        <div class="flex-1 flex flex-col overflow-hidden">
          <div class="flex items-center justify-between px-6 py-3 border-b border-[var(--border)] shrink-0">
            <div class="flex items-center gap-2">
              <h2 class="text-xs font-semibold text-[var(--text-primary)]">Directories</h2>
              <span class="text-xs text-[var(--text-tertiary)] tabular-nums">
                {length(@directories)}
              </span>
            </div>
            <div class="flex items-center gap-2">
              <.docs_action path="/directory-sync" />
              <.link
                patch={~p"/#{@account}/settings/directory_sync/new"}
                class="flex items-center gap-1 px-2.5 py-1 rounded text-xs border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-emphasis)] bg-[var(--surface)] transition-colors"
              >
                <.icon name="ri-add-line" class="w-3 h-3" /> Add
              </.link>
            </div>
          </div>

          <div class="flex-1 overflow-auto">
            <%= if Enum.empty?(@directories) do %>
              <div class="flex flex-col items-center justify-center h-full gap-3 text-[var(--text-tertiary)]">
                <p class="text-sm">No directories configured.</p>
                <.link
                  patch={~p"/#{@account}/settings/directory_sync/new"}
                  class="flex items-center gap-1 px-2.5 py-1 rounded text-xs border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-emphasis)] bg-[var(--surface)] transition-colors"
                >
                  <.icon name="ri-add-line" class="w-3 h-3" /> Add a directory
                </.link>
              </div>
            <% else %>
              <table class="w-full text-sm border-collapse">
                <thead class="sticky top-0 z-10 bg-[var(--surface-raised)]">
                  <tr class="border-b border-[var(--border-strong)]">
                    <th class="px-6 py-2.5 text-left text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)] w-64">
                      Directory
                    </th>
                    <th class="px-6 py-2.5 text-left text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)] w-28">
                      Status
                    </th>
                    <th class="px-6 py-2.5 text-left text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)] w-48">
                      Tenant
                    </th>
                    <th class="px-6 py-2.5 text-left text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)] w-28">
                      Identities
                    </th>
                    <th class="px-6 py-2.5 text-left text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)] w-28">
                      Groups
                    </th>
                    <th class="px-6 py-2.5 text-left text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)] w-40">
                      Last Synced
                    </th>
                    <th class="px-6 py-2.5 w-14"></th>
                  </tr>
                </thead>
                <tbody>
                  <.directory_row
                    :for={directory <- @directories}
                    type={directory_type(directory)}
                    account={@account}
                    directory={directory}
                    subject={@subject}
                    most_recent_job={directory.most_recent_job}
                  />
                </tbody>
              </table>
            <% end %>
          </div>
        </div>

    <!-- Add Directory Panel -->
        <div
          id="add-directory-panel"
          class={[
            "fixed top-14 right-0 bottom-0 z-20 flex flex-col w-full lg:w-3/4 xl:w-1/2",
            "bg-[var(--surface-overlay)] border-l border-[var(--border-strong)]",
            "shadow-[-4px_0px_20px_rgba(0,0,0,0.07)]",
            "transition-transform duration-200 ease-in-out",
            (@live_action in [:select_type, :new] && "translate-x-0") || "translate-x-full"
          ]}
          phx-window-keydown="handle_keydown"
          phx-key="Escape"
        >
          <!-- Select Directory Type -->
          <div :if={@live_action == :select_type} class="flex flex-col h-full overflow-hidden">
            <div class="shrink-0 flex items-center justify-between px-5 py-4 border-b border-[var(--border)]">
              <h2 class="text-sm font-semibold text-[var(--text-primary)]">Select Directory Type</h2>
              <button
                phx-click="close_panel"
                class="flex items-center justify-center w-7 h-7 rounded text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors"
                title="Close (Esc)"
              >
                <.icon name="ri-close-line" class="w-4 h-4" />
              </button>
            </div>
            <div class="flex-1 overflow-y-auto px-5 py-4">
              <p class="mb-4 text-xs text-[var(--text-tertiary)]">
                Select a directory type to add:
              </p>
              <ul class="flex flex-col gap-2">
                <li>
                  <.link
                    patch={~p"/#{@account}/settings/directory_sync/google/new"}
                    class={select_type_classes()}
                  >
                    <span class="flex items-center gap-3 w-2/5 shrink-0">
                      <.provider_icon type="google" class="w-7 h-7 shrink-0" />
                      <span class="text-sm font-medium text-[var(--text-primary)]">Google</span>
                    </span>
                    <span class="text-xs text-[var(--text-secondary)]">
                      Sync users and groups from Google Workspace.
                    </span>
                  </.link>
                </li>
                <li>
                  <.link
                    patch={~p"/#{@account}/settings/directory_sync/entra/new"}
                    class={select_type_classes()}
                  >
                    <span class="flex items-center gap-3 w-2/5 shrink-0">
                      <.provider_icon type="entra" class="w-7 h-7 shrink-0" />
                      <span class="text-sm font-medium text-[var(--text-primary)]">Entra</span>
                    </span>
                    <span class="text-xs text-[var(--text-secondary)]">
                      Sync users and groups from Microsoft Entra ID.
                    </span>
                  </.link>
                </li>
                <li>
                  <.link
                    patch={~p"/#{@account}/settings/directory_sync/okta/new"}
                    class={select_type_classes()}
                  >
                    <span class="flex items-center gap-3 w-2/5 shrink-0">
                      <.provider_icon type="okta" class="w-7 h-7 shrink-0" />
                      <span class="text-sm font-medium text-[var(--text-primary)]">Okta</span>
                    </span>
                    <span class="text-xs text-[var(--text-secondary)]">
                      Sync users and groups from Okta.
                    </span>
                  </.link>
                </li>
              </ul>
            </div>
          </div>

    <!-- New Directory Form -->
          <div
            :if={@live_action == :new and assigns[:form] != nil}
            class="flex flex-col h-full overflow-hidden"
          >
            <div class="shrink-0 flex items-center justify-between px-5 py-4 border-b border-[var(--border)]">
              <div class="flex items-center gap-2">
                <.link
                  patch={~p"/#{@account}/settings/directory_sync/new"}
                  class="flex items-center justify-center w-6 h-6 rounded text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors"
                  title="Back"
                >
                  <.icon name="ri-arrow-left-line" class="w-4 h-4" />
                </.link>
                <div class="flex items-center gap-2">
                  <.provider_icon type={@type} class="w-5 h-5 shrink-0" />
                  <h2 class="text-sm font-semibold text-[var(--text-primary)]">
                    Add {titleize(@type)} Directory
                  </h2>
                  <.docs_action path={"/directory-sync/#{@type}"} />
                </div>
              </div>
              <button
                phx-click="close_panel"
                class="flex items-center justify-center w-7 h-7 rounded text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors"
                title="Close (Esc)"
              >
                <.icon name="ri-close-line" class="w-4 h-4" />
              </button>
            </div>
            <div class="flex-1 overflow-y-auto px-5 py-4">
              <.directory_form
                verification_error={@verification_error}
                verifying={assigns[:verifying] || false}
                form={@form}
                type={@type}
                submit_event="submit_directory"
                public_jwk={assigns[:public_jwk]}
              />
            </div>
            <div class="shrink-0 flex items-center justify-end gap-2 px-5 py-4 border-t border-[var(--border)]">
              <button
                phx-click="close_panel"
                class="px-3 py-1.5 text-sm rounded border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-emphasis)] bg-[var(--surface)] transition-colors"
              >
                Cancel
              </button>
              <button
                form="directory-form"
                type="submit"
                disabled={not @form.source.valid?}
                class="px-3 py-1.5 text-sm rounded bg-[var(--brand)] text-white hover:bg-[var(--brand-hover)] disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
              >
                Create
              </button>
            </div>
          </div>
        </div>

    <!-- Edit Directory Panel -->
        <div
          id="edit-directory-panel"
          class={[
            "fixed top-14 right-0 bottom-0 z-20 flex flex-col w-full lg:w-3/4 xl:w-1/2",
            "bg-[var(--surface-overlay)] border-l border-[var(--border-strong)]",
            "shadow-[-4px_0px_20px_rgba(0,0,0,0.07)]",
            "transition-transform duration-200 ease-in-out",
            (@live_action == :edit && assigns[:form] != nil && "translate-x-0") || "translate-x-full"
          ]}
          phx-window-keydown="handle_keydown"
          phx-key="Escape"
        >
          <div
            :if={@live_action == :edit and assigns[:form] != nil}
            class="flex flex-col h-full overflow-hidden"
          >
            <div class="shrink-0 flex items-center justify-between px-5 py-4 border-b border-[var(--border)]">
              <div class="flex items-center gap-2">
                <.provider_icon type={@type} class="w-5 h-5 shrink-0" />
                <h2 class="text-sm font-semibold text-[var(--text-primary)]">
                  Edit {assigns[:directory_name]}
                </h2>
                <.docs_action path={"/directory-sync/#{@type}"} />
              </div>
              <button
                phx-click="close_panel"
                class="flex items-center justify-center w-7 h-7 rounded text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors"
                title="Close (Esc)"
              >
                <.icon name="ri-close-line" class="w-4 h-4" />
              </button>
            </div>
            <div class="flex-1 overflow-y-auto px-5 py-4">
              <.flash :if={assigns[:is_legacy]} kind={:warning_inline} class="mb-4">
                This directory uses legacy credentials and needs to be updated to use Firezone's shared service account.
                <.website_link path="/kb/">Read the docs</.website_link>
                to setup domain-wide delegation, then click <strong>Verify Now</strong>
                and <strong>Save</strong>
                below.
              </.flash>
              <.directory_form
                verification_error={@verification_error}
                verifying={assigns[:verifying] || false}
                form={@form}
                type={@type}
                submit_event="submit_directory"
                public_jwk={assigns[:public_jwk]}
              />
            </div>
            <div class="shrink-0 flex items-center justify-end gap-2 px-5 py-4 border-t border-[var(--border)]">
              <button
                phx-click="close_panel"
                class="px-3 py-1.5 text-sm rounded border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-emphasis)] bg-[var(--surface)] transition-colors"
              >
                Cancel
              </button>
              <button
                form="directory-form"
                type="submit"
                disabled={
                  not @form.source.valid? or Enum.empty?(@form.source.changes) or not verified?(@form)
                }
                class="px-3 py-1.5 text-sm rounded bg-[var(--brand)] text-white hover:bg-[var(--brand-hover)] disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
              >
                Save
              </button>
            </div>
          </div>
        </div>
      <% else %>
        <div class="flex-1 flex flex-col overflow-hidden">
          <div class="flex items-center justify-between px-6 py-3 border-b border-[var(--border)] shrink-0">
            <div class="flex items-center gap-2">
              <h2 class="text-xs font-semibold text-[var(--text-primary)]">Directories</h2>
            </div>
            <div class="flex items-center gap-2">
              <.docs_action path="/directory-sync" />
            </div>
          </div>

          <div class="flex-1 overflow-hidden relative">
            <div class="blur-xs pointer-events-none select-none opacity-60">
              <table class="w-full text-sm border-collapse">
                <thead class="bg-[var(--surface-raised)]">
                  <tr class="border-b border-[var(--border-strong)]">
                    <th class="px-6 py-2.5 text-left text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)] w-64">
                      Directory
                    </th>
                    <th class="px-6 py-2.5 text-left text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)] w-28">
                      Status
                    </th>
                    <th class="px-6 py-2.5 text-left text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)] w-48">
                      Tenant
                    </th>
                    <th class="px-6 py-2.5 text-left text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)] w-28">
                      Identities
                    </th>
                    <th class="px-6 py-2.5 text-left text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)] w-28">
                      Groups
                    </th>
                    <th class="px-6 py-2.5 text-left text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)] w-40">
                      Last Synced
                    </th>
                    <th class="px-6 py-2.5 w-14"></th>
                  </tr>
                </thead>
                <tbody>
                  <tr class="border-b border-[var(--border)]">
                    <td class="px-6 py-3">
                      <div class="flex items-center gap-3">
                        <.provider_icon type="google" class="w-6 h-6 shrink-0" />
                        <div class="min-w-0">
                          <span class="text-sm font-medium text-[var(--text-primary)]">
                            Google Workspace
                          </span>
                          <span class="block text-xs text-[var(--text-tertiary)] font-mono">
                            acme.com
                          </span>
                        </div>
                      </div>
                    </td>
                    <td class="px-6 py-3 w-28">
                      <span class="inline-flex items-center px-1.5 py-0.5 rounded text-xs font-medium bg-green-100 text-green-800 dark:bg-green-900/30 dark:text-green-400">
                        Active
                      </span>
                    </td>
                    <td class="px-6 py-3 w-48">
                      <span class="text-sm text-[var(--text-secondary)] font-mono">acme.com</span>
                    </td>
                    <td class="px-6 py-3 w-28 text-sm text-[var(--text-primary)] tabular-nums">42</td>
                    <td class="px-6 py-3 w-28 text-sm text-[var(--text-primary)] tabular-nums">8</td>
                    <td class="px-6 py-3 w-40 text-xs text-[var(--text-secondary)]">2 hours ago</td>
                    <td class="px-6 py-3 w-14"></td>
                  </tr>
                  <tr class="border-b border-[var(--border)]">
                    <td class="px-6 py-3">
                      <div class="flex items-center gap-3">
                        <.provider_icon type="entra" class="w-6 h-6 shrink-0" />
                        <div class="min-w-0">
                          <span class="text-sm font-medium text-[var(--text-primary)]">
                            Microsoft Entra
                          </span>
                          <span class="block text-xs text-[var(--text-tertiary)] font-mono">
                            contoso.onmicrosoft.com
                          </span>
                        </div>
                      </div>
                    </td>
                    <td class="px-6 py-3 w-28">
                      <span class="inline-flex items-center px-1.5 py-0.5 rounded text-xs font-medium bg-green-100 text-green-800 dark:bg-green-900/30 dark:text-green-400">
                        Active
                      </span>
                    </td>
                    <td class="px-6 py-3 w-48">
                      <span class="text-sm text-[var(--text-secondary)] font-mono truncate block">
                        contoso.onmicrosoft.com
                      </span>
                    </td>
                    <td class="px-6 py-3 w-28 text-sm text-[var(--text-primary)] tabular-nums">
                      128
                    </td>
                    <td class="px-6 py-3 w-28 text-sm text-[var(--text-primary)] tabular-nums">15</td>
                    <td class="px-6 py-3 w-40 text-xs text-[var(--text-secondary)]">1 hour ago</td>
                    <td class="px-6 py-3 w-14"></td>
                  </tr>
                </tbody>
              </table>
            </div>

            <div class="absolute inset-0 flex items-end justify-center pb-[20%]">
              <div class="flex flex-col items-center gap-3 bg-[var(--surface-overlay)] border border-[var(--border)] rounded-lg shadow-lg px-8 py-6 text-[var(--text-tertiary)]">
                <.icon name="ri-loop-left-line" class="w-8 h-8" />
                <div class="flex flex-col items-center gap-1 text-center">
                  <p class="text-sm font-medium text-[var(--text-primary)]">
                    Automate User & Group Management
                  </p>
                  <p class="text-xs">
                    Connect your identity provider to automatically sync users and groups.
                  </p>
                </div>
                <.button
                  style="primary"
                  icon="ri-sparkling-fill"
                  navigate={~p"/#{@account}/settings/account"}
                >
                  Upgrade to Unlock
                </.button>
              </div>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  attr :type, :string, required: true
  attr :account, :any, required: true
  attr :directory, :any, required: true
  attr :subject, :any, required: true
  attr :most_recent_job, :map, default: nil

  defp directory_row(assigns) do
    is_legacy = assigns.type == "google" && assigns.directory.legacy_service_account_key != nil
    toggle_disabled = assigns.directory.is_disabled and not assigns.account.features.idp_sync
    assigns = assign(assigns, is_legacy: is_legacy, toggle_disabled: toggle_disabled)

    ~H"""
    <tr class="border-b border-[var(--border)] hover:bg-[var(--surface-raised)]">
      <td class="px-6 py-3">
        <div class="flex items-center gap-3">
          <.provider_icon type={@type} class="w-6 h-6 shrink-0" />
          <div class="min-w-0">
            <div class="flex items-center gap-2">
              <span
                class="text-sm font-medium text-[var(--text-primary)] truncate"
                title={@directory.name}
              >
                {@directory.name}
              </span>
              <.badge :if={@is_legacy} type="warning">LEGACY</.badge>
            </div>
            <span class="text-xs text-[var(--text-tertiary)] font-mono">{@directory.id}</span>
          </div>
        </div>
      </td>
      <td class="px-6 py-3 w-28">
        <.directory_status_badge directory={@directory} />
      </td>
      <td class="px-6 py-3 w-48">
        <span class="text-sm text-[var(--text-secondary)] font-mono truncate block">
          {directory_identifier(@type, @directory) || "—"}
        </span>
      </td>
      <td class="px-6 py-3 w-28 text-sm text-[var(--text-primary)] tabular-nums">
        <.link
          navigate={~p"/#{@account}/actors?actors_filter[directory_id]=#{@directory.id}"}
          class="hover:underline"
        >
          {@directory.actors_count}
        </.link>
      </td>
      <td class="px-6 py-3 w-28 text-sm text-[var(--text-primary)] tabular-nums">
        <.link
          navigate={~p"/#{@account}/groups?groups_filter[directory_id]=#{@directory.id}"}
          class="hover:underline"
        >
          {@directory.groups_count}
        </.link>
      </td>
      <td class="px-6 py-3 w-40">
        <%= case @most_recent_job do %>
          <% %{state: "executing"} = job -> %>
            <span class="flex items-center gap-1.5 text-xs text-[var(--brand)]">
              <.icon name="ri-loop-left-line" class="w-3.5 h-3.5 animate-spin" />
              syncing ({format_duration(job.elapsed_seconds)})
            </span>
          <% %{state: state} when state in ["available", "scheduled"] -> %>
            <span class="flex items-center gap-1.5 text-xs text-[var(--text-tertiary)]">
              <.icon name="ri-time-line" class="w-3.5 h-3.5" /> queued
            </span>
          <% %{state: "completed"} = job -> %>
            <span class="text-xs text-[var(--text-secondary)]">
              <.relative_datetime datetime={job.completed_at} />
            </span>
          <% _ -> %>
            <%= if @directory.synced_at do %>
              <span class="text-xs text-[var(--text-secondary)]">
                <.relative_datetime datetime={@directory.synced_at} />
              </span>
            <% else %>
              <span class="text-xs text-[var(--text-tertiary)]">Never</span>
            <% end %>
        <% end %>
      </td>
      <td class="px-6 py-3 w-14">
        <div class="flex justify-end">
          <.popover placement="bottom" trigger="click">
            <:target>
              <button
                type="button"
                class="flex items-center justify-center w-7 h-7 rounded text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors"
              >
                <.icon name="ri-more-2-line" class="w-4 h-4" />
              </button>
            </:target>
            <:content>
              <div class="flex flex-col py-1 w-44">
                <.link
                  patch={~p"/#{@account}/settings/directory_sync/#{@type}/#{@directory.id}/edit"}
                  class="flex items-center gap-2.5 w-full px-3 py-2 text-xs text-left hover:bg-[var(--surface-raised)] transition-colors text-[var(--text-secondary)]"
                >
                  <.icon name="ri-pencil-line" class="w-3.5 h-3.5 shrink-0" /> Edit
                </.link>
                <button
                  type="button"
                  phx-click="sync_directory"
                  phx-value-id={@directory.id}
                  phx-value-type={@type}
                  disabled={@directory.is_disabled or @directory.has_active_job}
                  class="flex items-center gap-2.5 w-full px-3 py-2 text-xs text-left hover:bg-[var(--surface-raised)] transition-colors text-[var(--text-secondary)] disabled:opacity-50 disabled:cursor-not-allowed"
                >
                  <.icon name="ri-loop-left-line" class="w-3.5 h-3.5 shrink-0" /> Sync Now
                </button>
                <div class="my-1 border-t border-[var(--border)]"></div>
                <.button_with_confirmation
                  id={"toggle-directory-#{@directory.id}"}
                  on_confirm="toggle_directory"
                  on_confirm_id={@directory.id}
                  class="flex justify-start items-center gap-2.5 w-full px-3 py-2 text-xs text-left hover:bg-[var(--surface-raised)] transition-colors text-[var(--text-secondary)] border-0 bg-transparent"
                >
                  <.icon
                    name={
                      if @directory.is_disabled,
                        do: "ri-checkbox-circle-line",
                        else: "ri-close-circle-line"
                    }
                    class="w-3.5 h-3.5 shrink-0"
                  />
                  {if @directory.is_disabled, do: "Enable", else: "Disable"}
                  <:dialog_title>
                    {if @directory.is_disabled, do: "Enable", else: "Disable"} Directory
                  </:dialog_title>
                  <:dialog_content>
                    <p>
                      Are you sure you want to {if @directory.is_disabled,
                        do: "enable",
                        else: "disable"} <strong>{@directory.name}</strong>?
                    </p>
                    <%= if not @directory.is_disabled do %>
                      <p class="mt-2">This directory will no longer sync while disabled.</p>
                    <% end %>
                  </:dialog_content>
                  <:dialog_confirm_button>
                    {if @directory.is_disabled, do: "Enable", else: "Disable"}
                  </:dialog_confirm_button>
                  <:dialog_cancel_button>Cancel</:dialog_cancel_button>
                </.button_with_confirmation>
                <div class="my-1 border-t border-[var(--border)]"></div>
                <.button_with_confirmation
                  id={"delete-directory-#{@directory.id}"}
                  on_confirm="delete_directory"
                  on_confirm_id={@directory.id}
                  class="flex justify-start items-center gap-2.5 w-full px-3 py-2 text-xs text-left hover:bg-[var(--surface-raised)] transition-colors text-[var(--status-error)] border-0 bg-transparent"
                >
                  <.icon name="ri-delete-bin-line" class="w-3.5 h-3.5 shrink-0" /> Delete
                  <:dialog_title>Delete Directory</:dialog_title>
                  <:dialog_content>
                    <.deletion_stats directory={@directory} subject={@subject} />
                  </:dialog_content>
                  <:dialog_confirm_button>Delete</:dialog_confirm_button>
                  <:dialog_cancel_button>Cancel</:dialog_cancel_button>
                </.button_with_confirmation>
              </div>
            </:content>
          </.popover>
        </div>
      </td>
    </tr>
    """
  end

  attr :directory, :any, required: true

  defp directory_status_badge(assigns) do
    ~H"""
    <%= cond do %>
      <% @directory.is_disabled and @directory.disabled_reason == "Sync error" -> %>
        <span class="inline-flex items-center text-[10px] font-semibold px-1.5 py-0.5 rounded bg-red-100 text-red-700">
          Error
        </span>
      <% @directory.is_disabled -> %>
        <span class="inline-flex items-center text-[10px] font-semibold px-1.5 py-0.5 rounded bg-[var(--surface-raised)] text-[var(--text-tertiary)]">
          Disabled
        </span>
      <% @directory.errored_at -> %>
        <span class="inline-flex items-center text-[10px] font-semibold px-1.5 py-0.5 rounded bg-yellow-100 text-yellow-700">
          Warning
        </span>
      <% @directory.is_verified -> %>
        <span class="inline-flex items-center text-[10px] font-semibold px-1.5 py-0.5 rounded bg-green-100 text-green-700">
          Active
        </span>
      <% true -> %>
        <span class="inline-flex items-center text-[10px] font-semibold px-1.5 py-0.5 rounded bg-[var(--surface-raised)] text-[var(--text-tertiary)]">
          Unverified
        </span>
    <% end %>
    """
  end

  defp format_duration(nil), do: "-"
  defp format_duration(seconds) when seconds < 60, do: "#{seconds}s"

  defp format_duration(seconds) do
    minutes = div(seconds, 60)
    remaining_seconds = rem(seconds, 60)

    if remaining_seconds > 0 do
      "#{minutes}m #{remaining_seconds}s"
    else
      "#{minutes}m"
    end
  end

  attr :directory, :any, required: true
  attr :subject, :any, required: true

  defp deletion_stats(assigns) do
    stats = Database.count_deletion_stats(assigns.directory, assigns.subject)
    total = stats.actors + stats.identities + stats.groups + stats.policies
    assigns = assign(assigns, stats: stats, total: total)

    ~H"""
    <div>
      <p class="text-[var(--text-secondary)]">
        Are you sure you want to delete <strong>{@directory.name}</strong>?
      </p>
      <%= if @total > 0 do %>
        <p class="mt-3 text-[var(--text-secondary)]">
          This will permanently delete:
        </p>
        <ul class="list-disc list-inside mt-2 text-[var(--text-secondary)] space-y-1">
          <li :if={@stats.actors > 0}>
            <strong>{@stats.actors}</strong> {ngettext("actor", "actors", @stats.actors)}
          </li>
          <li :if={@stats.identities > 0}>
            <strong>{@stats.identities}</strong> {ngettext(
              "identity",
              "identities",
              @stats.identities
            )}
          </li>
          <li :if={@stats.groups > 0}>
            <strong>{@stats.groups}</strong> {ngettext("group", "groups", @stats.groups)}
          </li>
          <li :if={@stats.policies > 0}>
            <strong>{@stats.policies}</strong> {ngettext("policy", "policies", @stats.policies)}
          </li>
        </ul>
      <% else %>
        <p class="mt-2 text-[var(--text-secondary)]">This action cannot be undone.</p>
      <% end %>
    </div>
    """
  end

  attr :form, :any, required: true
  attr :type, :string, required: true
  attr :submit_event, :string, required: true
  attr :verification_error, :any, default: nil
  attr :verifying, :boolean, default: false
  attr :public_jwk, :any, default: nil

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
          <label
            for={@form[:name].id}
            class="block text-xs font-medium text-[var(--text-secondary)] mb-1.5"
          >
            Name <span class="text-[var(--status-error)]">*</span>
          </label>
          <.input
            field={@form[:name]}
            type="text"
            autocomplete="off"
            phx-debounce="300"
            data-1p-ignore
            required
          />
          <p class="mt-1 text-xs text-[var(--text-tertiary)]">
            Enter a name to identify this directory.
          </p>
        </div>

        <fieldset :if={@type == "entra"}>
          <legend class="block text-xs font-medium text-[var(--text-secondary)] mb-3">
            Group sync mode
          </legend>
          <% sync_all_groups = get_field(@form.source, :sync_all_groups) %>
          <div class="grid gap-3 md:grid-cols-2">
            <label class={[
              "flex flex-col p-3 border rounded cursor-pointer transition-all",
              if(sync_all_groups == false,
                do: "border-[var(--brand)] bg-[var(--surface-raised)]",
                else: "border-[var(--border)] hover:border-[var(--border-emphasis)]"
              )
            ]}>
              <input
                type="radio"
                name={@form[:sync_all_groups].name}
                value="false"
                checked={sync_all_groups == false}
                class="sr-only"
              />
              <span class="text-sm font-semibold text-[var(--text-primary)] mb-1">
                Assigned groups only
              </span>
              <span class="text-xs text-[var(--text-secondary)]">
                Only groups assigned to the
                <code class="text-xs"><strong>Firezone Authentication</strong></code>
                managed application will be synced. Requires Entra ID P1/P2 or higher.
                <strong class="block mt-1">Recommended for most users.</strong>
              </span>
            </label>

            <label class={[
              "flex flex-col p-3 border rounded cursor-pointer transition-all",
              if(sync_all_groups == true,
                do: "border-[var(--brand)] bg-[var(--surface-raised)]",
                else: "border-[var(--border)] hover:border-[var(--border-emphasis)]"
              )
            ]}>
              <input
                type="radio"
                name={@form[:sync_all_groups].name}
                value="true"
                checked={sync_all_groups == true}
                class="sr-only"
              />
              <span class="text-sm font-semibold text-[var(--text-primary)] mb-1">
                All groups
              </span>
              <span class="text-xs text-[var(--text-secondary)]">
                All groups from your directory will be synced. Use this for Entra ID Free or to sync all groups without managing assignments.
              </span>
            </label>
          </div>
        </fieldset>

        <div :if={@type == "entra"}>
          <.input
            field={@form[:email_field]}
            type="select"
            label="Email Field"
            options={[
              {"User Principal Name (userPrincipalName)", "userPrincipalName"},
              {"Mail (mail)", "mail"}
            ]}
            required
          />
          <p class="mt-1 text-xs text-neutral-600">
            The Microsoft Graph user field to use as the primary email during directory sync.
          </p>
        </div>

        <div :if={@type == "google"}>
          <label
            for={@form[:impersonation_email].id}
            class="block text-xs font-medium text-[var(--text-secondary)] mb-1.5"
          >
            Impersonation Email <span class="text-[var(--status-error)]">*</span>
          </label>
          <.input
            field={@form[:impersonation_email]}
            type="text"
            autocomplete="off"
            phx-debounce="300"
            data-1p-ignore
            required
          />
          <p class="mt-1 text-xs text-[var(--text-tertiary)]">
            Enter the admin email address to impersonate for directory sync.
          </p>
        </div>

        <fieldset :if={@type == "google"}>
          <legend class="block text-xs font-medium text-[var(--text-secondary)] mb-3">
            Group sync mode
          </legend>
          <% group_sync_mode = get_field(@form.source, :group_sync_mode) %>
          <div class="grid gap-3 md:grid-cols-3">
            <label class={[
              "flex flex-col p-3 border rounded cursor-pointer transition-all",
              if(group_sync_mode == :all,
                do: "border-[var(--brand)] bg-[var(--surface-raised)]",
                else: "border-[var(--border)] hover:border-[var(--border-emphasis)]"
              )
            ]}>
              <input
                type="radio"
                name={@form[:group_sync_mode].name}
                value="all"
                checked={group_sync_mode == :all}
                class="sr-only"
              />
              <span class="text-sm font-semibold text-[var(--text-primary)] mb-1">
                All groups
              </span>
              <span class="text-xs text-[var(--text-secondary)]">
                All groups from your directory will be synced.
                <strong class="block mt-1">Default.</strong>
              </span>
            </label>

            <label class={[
              "flex flex-col p-3 border rounded cursor-pointer transition-all",
              if(group_sync_mode == :filtered,
                do: "border-[var(--brand)] bg-[var(--surface-raised)]",
                else: "border-[var(--border)] hover:border-[var(--border-emphasis)]"
              )
            ]}>
              <input
                type="radio"
                name={@form[:group_sync_mode].name}
                value="filtered"
                checked={group_sync_mode == :filtered}
                class="sr-only"
              />
              <span class="text-sm font-semibold text-[var(--text-primary)] mb-1">
                Filtered groups
              </span>
              <span class="text-xs text-[var(--text-secondary)]">
                Only groups whose name starts with
                <code class="text-xs"><strong>[firezone-sync]</strong></code>
                or email starts with <code class="text-xs"><strong>firezone-sync</strong></code>
                will be synced.
              </span>
            </label>

            <label class={[
              "flex flex-col p-3 border rounded cursor-pointer transition-all",
              if(group_sync_mode == :disabled,
                do: "border-[var(--brand)] bg-[var(--surface-raised)]",
                else: "border-[var(--border)] hover:border-[var(--border-emphasis)]"
              )
            ]}>
              <input
                type="radio"
                name={@form[:group_sync_mode].name}
                value="disabled"
                checked={group_sync_mode == :disabled}
                class="sr-only"
              />
              <span class="text-sm font-semibold text-[var(--text-primary)] mb-1">
                Disabled
              </span>
              <span class="text-xs text-[var(--text-secondary)]">
                No groups will be synced from your directory.
              </span>
            </label>
          </div>
        </fieldset>

        <div :if={@type == "google"} class="mt-4">
          <label class="flex items-center gap-3 cursor-pointer">
            <input type="hidden" name={@form[:orgunit_sync_enabled].name} value="false" />
            <input
              type="checkbox"
              name={@form[:orgunit_sync_enabled].name}
              value="true"
              checked={get_field(@form.source, :orgunit_sync_enabled)}
              class="w-4 h-4 text-[var(--brand)] border-[var(--border)] rounded"
            />
            <span class="text-sm font-medium text-[var(--text-primary)]">
              Sync Organization Units
            </span>
          </label>
          <p class="mt-1 ml-7 text-xs text-[var(--text-tertiary)]">
            Sync Google Workspace organizational units as groups. <strong>Note:</strong>
            When enabled, all org units and active users will be synced.
          </p>
        </div>

        <div :if={@type == "okta"}>
          <label
            for={@form[:okta_domain].id}
            class="block text-xs font-medium text-[var(--text-secondary)] mb-1.5"
          >
            Okta Domain <span class="text-[var(--status-error)]">*</span>
          </label>
          <.input
            field={@form[:okta_domain]}
            type="text"
            autocomplete="off"
            phx-debounce="300"
            data-1p-ignore
            required
          />
          <p class="mt-1 text-xs text-[var(--text-tertiary)]">
            Enter your fully-qualified Okta organization domain (e.g., example.okta.com).
          </p>
        </div>

        <div :if={@type == "okta"}>
          <label
            for={@form[:client_id].id}
            class="block text-xs font-medium text-[var(--text-secondary)] mb-1.5"
          >
            Client ID <span class="text-[var(--status-error)]">*</span>
          </label>
          <.input
            field={@form[:client_id]}
            type="text"
            autocomplete="off"
            phx-debounce="300"
            data-1p-ignore
            required
          />
          <p class="mt-1 text-xs text-[var(--text-tertiary)]">
            Enter the Client ID from your Okta application settings.
          </p>
        </div>

        <div
          :if={@type == "okta"}
          class="p-4 border border-[var(--border)] bg-[var(--surface-raised)] rounded"
        >
          <div class="flex items-center justify-between mb-4">
            <div class="flex-1">
              <h3 class="text-sm font-semibold text-[var(--text-primary)]">Public Key (JWK)</h3>
              <p class="mt-1 text-xs text-[var(--text-secondary)]">
                Generate a keypair and copy the public key to your Okta application settings.
              </p>
            </div>
            <div class="ml-4">
              <.button
                type="button"
                phx-click="generate_keypair"
                icon="ri-key-line"
                style="primary"
                size="sm"
              >
                Generate Keypair
              </.button>
            </div>
          </div>

          <%= if Map.get(assigns, :public_jwk) do %>
            <% kid = get_in(@public_jwk, ["keys", Access.at(0), "kid"]) %>
            <div class="mt-4">
              <div id={"okta-public-jwk-wrapper-#{kid}"} phx-hook="FormatJSON">
                <.code_block
                  id="okta-public-jwk"
                  class="text-xs rounded-md [&_code]:h-72 [&_code]:overflow-y-auto [&_code]:whitespace-pre-wrap [&_code]:break-all [&_code]:p-2"
                >
                  {JSON.encode!(@public_jwk)}
                </.code_block>
              </div>
              <p class="mt-2 text-xs text-[var(--text-tertiary)]">
                Copy this public key and add it to your Okta application's JWKS configuration.
              </p>
            </div>
          <% else %>
            <p class="text-sm text-[var(--text-tertiary)] italic">
              No keypair generated yet. Click "Generate Keypair" to create one.
            </p>
          <% end %>
        </div>

        <div
          :if={@type in ["google", "entra", "okta"]}
          class="p-4 border border-[var(--border)] bg-[var(--surface-raised)] rounded"
        >
          <.flash :if={@verification_error} kind={:error}>
            {@verification_error}
          </.flash>
          <div class="flex items-center justify-between">
            <div class="flex-1">
              <h3 class="text-sm font-semibold text-[var(--text-primary)]">Directory Verification</h3>
              <p class="mt-1 text-xs text-[var(--text-secondary)]">
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

          <div class="mt-4 pt-4 border-t border-[var(--border)] space-y-3">
            <.verification_fields_status type={@type} form={@form} />
            <.reset_verification_button form={@form} />
          </div>
        </div>
      </div>
    </.form>
    """
  end

  defp verification_help_text(form, _type) do
    if verified?(form) do
      "This directory has been successfully verified."
    else
      "Verify your directory configuration by clicking \"Verify Now\"."
    end
  end

  attr :id, :string, required: true
  attr :form, :any, required: true
  attr :verifying, :boolean, required: true
  attr :type, :string, required: true

  defp verification_status_badge(assigns) do
    # Entra opens a new window, so show the arrow icon and use OpenURL hook
    # Google/Okta are server-side only, no icon or hook needed
    button_attrs =
      if assigns.type == "entra" do
        [icon: "ri-external-link-line", "phx-hook": "OpenURL"]
      else
        []
      end

    assigns = assign(assigns, :button_attrs, button_attrs)

    ~H"""
    <div
      :if={verified?(@form)}
      class="flex items-center text-green-700 bg-green-100 px-4 py-2 rounded-sm"
    >
      <.icon name="ri-checkbox-circle-line" class="h-5 w-5 mr-2" />
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
    field =
      case assigns.type do
        "google" -> :domain
        "entra" -> :tenant_id
        "okta" -> :okta_domain
      end

    assigns = assign(assigns, :field, field)

    ~H"""
    <div class="flex justify-between items-center">
      <label class="text-xs font-medium text-[var(--text-secondary)]">
        {Phoenix.Naming.humanize(@field)}
      </label>
      <div class="text-right">
        <p class="text-xs font-semibold text-[var(--text-primary)]">
          {verification_field_display(@form.source, @field)}
        </p>
      </div>
    </div>
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
        class="text-xs text-[var(--text-secondary)] hover:text-[var(--text-primary)] underline"
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
      {excluded, _errors}
      when excluded in [:is_verified, :domain, :tenant_id, :okta_domain] ->
        true

      {_field, _errors} ->
        false
    end)
  end

  defp select_type_classes, do: @select_type_classes

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

  defp put_directory_assoc(changeset, socket) do
    schema = changeset.data.__struct__
    account_id = socket.assigns.subject.account.id

    type =
      case schema do
        Google.Directory -> :google
        Entra.Directory -> :entra
        Okta.Directory -> :okta
      end

    directory_id = Ecto.UUID.generate()

    directory_changeset =
      %Portal.Directory{}
      |> Ecto.Changeset.change(%{
        id: directory_id,
        account_id: account_id,
        type: type
      })

    changeset
    |> put_change(:id, directory_id)
    |> put_assoc(:directory, directory_changeset)
  end

  defp submit_directory(%{assigns: %{live_action: :new, form: %{source: changeset}}} = socket) do
    changeset = put_directory_assoc(changeset, socket)

    changeset
    |> Database.insert_directory(socket.assigns.subject)
    |> handle_submit(socket)
  end

  defp submit_directory(
         %{assigns: %{live_action: :edit, form: %{source: changeset}, directory: directory}} =
           socket
       ) do
    # If directory was disabled due to sync error and is now verified, clear error state and enable it
    changeset =
      if directory.disabled_reason == "Sync error" and get_field(changeset, :is_verified) == true do
        changeset
        |> put_change(:is_disabled, false)
        |> put_change(:disabled_reason, nil)
        |> put_change(:error_message, nil)
        |> put_change(:errored_at, nil)
        |> put_change(:error_email_count, 0)
      else
        changeset
      end

    # Clear legacy_service_account_key for Google directories on save
    changeset =
      if changeset.data.__struct__ == Google.Directory do
        put_change(changeset, :legacy_service_account_key, nil)
      else
        changeset
      end

    changeset
    |> Database.update_directory(socket.assigns.subject)
    |> handle_submit(socket)
  end

  defp handle_submit({:ok, _directory}, socket) do
    {:noreply,
     socket
     |> init()
     |> put_flash(:success, "Directory saved successfully.")
     |> push_patch(to: ~p"/#{socket.assigns.account}/settings/directory_sync")}
  end

  defp handle_submit({:error, changeset}, socket) do
    verification_error = verification_errors(changeset)
    {:noreply, assign(socket, verification_error: verification_error, form: to_form(changeset))}
  end

  defp verification_errors(changeset) do
    changeset.errors
    |> Enum.filter(fn {field, _error} ->
      field in [:domain, :tenant_id, :okta_domain]
    end)
    |> Enum.map_join(" ", fn {_field, {message, _opts}} -> message end)
  end

  defp start_verification(%{assigns: %{type: "google"}} = socket) do
    changeset = socket.assigns.form.source
    impersonation_email = get_field(changeset, :impersonation_email)
    config = Portal.Config.fetch_env!(:portal, Google.APIClient)

    result =
      with key_json when is_binary(key_json) <- config[:service_account_key],
           key = JSON.decode!(key_json),
           {:ok, %Req.Response{status: 200, body: %{"access_token" => access_token}}} <-
             Google.APIClient.get_access_token(impersonation_email, key),
           {:ok, %Req.Response{status: 200, body: body}} <-
             Google.APIClient.get_customer(access_token),
           :ok <- Google.APIClient.test_connection(access_token, body["customerDomain"]) do
        {:ok, body["customerDomain"]}
      else
        nil -> {:error, :service_account_not_configured}
        other -> other
      end

    case result do
      {:ok, domain} when is_binary(domain) ->
        # Merge existing changes with new verification data and re-run validation
        # This preserves form changes (like name, impersonation_email) while adding domain
        attrs =
          changeset.changes
          |> Map.put(:domain, domain)
          |> Map.put(:is_verified, true)
          |> Map.new(fn {k, v} -> {to_string(k), v} end)

        changeset =
          changeset
          |> apply_changes()
          |> changeset(attrs)

        {:noreply,
         assign(socket, form: to_form(changeset), verification_error: nil, verifying: false)}

      error ->
        msg = parse_google_verification_error(error)
        {:noreply, assign(socket, verification_error: msg, verifying: false)}
    end
  end

  defp start_verification(%{assigns: %{type: "entra"}} = socket) do
    with {:ok, %{config: config}} <- PortalWeb.OIDC.setup_verification("entra_directory_sync", []),
         lv_pid_string = self() |> :erlang.pid_to_list() |> to_string(),
         state_token <-
           PortalWeb.OIDC.sign_verification_state(
             lv_pid_string,
             PortalWeb.OIDC.verification_state_type("entra_directory_sync")
           ),
         {:ok, uri} <-
           PortalWeb.OIDC.build_verification_uri(
             "entra_directory_sync",
             config,
             "",
             state_token
           ) do
      {:noreply, push_event(socket, "open_url", %{url: uri})}
    else
      {:error, reason} ->
        {:noreply, assign(socket, verification_error: verification_start_error_message(reason))}
    end
  end

  defp start_verification(%{assigns: %{type: "okta"}} = socket) do
    changeset = socket.assigns.form.source
    okta_domain = get_field(changeset, :okta_domain)
    client_id = get_field(changeset, :client_id)
    private_key_jwk = get_field(changeset, :private_key_jwk)
    kid = get_field(changeset, :kid)

    client = Okta.APIClient.new(okta_domain, client_id, private_key_jwk, kid)

    result =
      with {:ok, access_token} <- Okta.APIClient.fetch_access_token(client),
           :ok <- Okta.APIClient.test_connection(client, access_token) do
        :ok
      end

    case result do
      :ok ->
        changeset = put_change(changeset, :is_verified, true)

        {:noreply,
         assign(socket, form: to_form(changeset), verification_error: nil, verifying: false)}

      error ->
        msg = parse_okta_verification_error(error)
        {:noreply, assign(socket, verification_error: msg, verifying: false)}
    end
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

  defp preserve_programmatic_fields(changeset, attrs) do
    Enum.reduce(@programmatic_fields, attrs, fn field, acc ->
      case Map.fetch(changeset.changes, field) do
        {:ok, value} -> Map.put(acc, to_string(field), value)
        :error -> acc
      end
    end)
  end

  defp parse_google_verification_error({:ok, %Req.Response{status: 400, body: body}}) do
    error_type = body["error"]
    error_description = body["error_description"]

    case {error_type, error_description} do
      {"invalid_grant", "Invalid email or User ID"} ->
        "Invalid service account email or user ID. Please check your service account configuration and ensure the email address is correct."

      {"invalid_grant", description} when is_binary(description) ->
        "Authentication failed: #{description}"

      {_, description} when is_binary(description) ->
        description

      _ ->
        "HTTP 400 Bad Request. Please check your configuration."
    end
  end

  defp parse_google_verification_error({:ok, %Req.Response{status: 401, body: body}}) do
    body["error_description"] ||
      "HTTP 401 error during verification. Ensure all scopes are granted for the service account."
  end

  defp parse_google_verification_error({:ok, %Req.Response{status: 403, body: body}}) do
    get_in(body, ["error", "message"]) ||
      "HTTP 403 error during verification. Ensure the service account has admin privileges and the admin SDK API is enabled."
  end

  defp parse_google_verification_error({:ok, %Req.Response{status: 404, body: body}}) do
    error_message = get_in(body, ["error", "message"])

    if error_message do
      "Resource not found: #{error_message}"
    else
      "HTTP 404 Not Found. The requested Google API resource or endpoint was not found. Please verify your configuration."
    end
  end

  defp parse_google_verification_error({:ok, %Req.Response{status: status}})
       when status >= 500 do
    "Google service is currently unavailable (HTTP #{status}). Please try again later."
  end

  defp parse_google_verification_error({:error, %Req.TransportError{reason: reason}}) do
    Logger.info("Transport error while verifying Google directory", error: inspect(reason))

    "Transport error while attempting to connect to Google.  We're looking into this"
  end

  defp parse_google_verification_error({:error, :service_account_not_configured}) do
    "No service account key is configured for this deployment. Please contact your administrator."
  end

  defp parse_google_verification_error({:error, reason}) when is_exception(reason) do
    "Failed to verify directory access: #{Exception.message(reason)}"
  end

  defp parse_google_verification_error({:error, reason}) do
    "Failed to verify directory access: #{inspect(reason)}"
  end

  defp parse_google_verification_error(error) do
    Logger.error("Unknown Google verification error", error: inspect(error))

    "Unknown error during verification. Please try again. If the problem persists, contact support."
  end

  # Standard HTTP errors - delegate to ErrorCodes
  defp parse_okta_verification_error({:error, %Req.Response{status: status, body: body}})
       when is_map(body) and map_size(body) > 0 do
    Portal.Okta.ErrorCodes.format_error(status, body)
  end

  # Special case: 403 with empty body has error in WWW-Authenticate header
  defp parse_okta_verification_error(
         {:error, %Req.Response{status: 403, body: "", headers: headers}}
       ) do
    headers
    |> extract_www_authenticate_header()
    |> parse_www_authenticate_error()
  end

  defp parse_okta_verification_error({:error, %Req.Response{status: status}}) do
    Portal.Okta.ErrorCodes.format_error(status, nil)
  end

  defp parse_okta_verification_error({:error, :empty, resource})
       when resource in [:apps, :users, :groups] do
    Portal.Okta.ErrorCodes.empty_resource_message(resource)
  end

  defp parse_okta_verification_error({:error, %Req.TransportError{} = error}) do
    Logger.info(Portal.DirectorySync.ErrorHandler.format_transport_error(error))
    "Transport error while contacting Okta API.  Please try again"
  end

  defp parse_okta_verification_error({:error, reason}) when is_exception(reason) do
    "Failed to verify directory access: #{Exception.message(reason)}"
  end

  defp parse_okta_verification_error({:error, reason}) do
    "Failed to verify directory access: #{inspect(reason)}"
  end

  defp parse_okta_verification_error(error) do
    Logger.error("Unknown Okta verification error", error: inspect(error))
    "Unknown error during verification. Please try again."
  end

  defp directory_identifier("google", directory) do
    directory.domain
  end

  defp directory_identifier("entra", directory) do
    directory.tenant_id
  end

  defp directory_identifier("okta", directory) do
    directory.okta_domain
  end

  defp extract_www_authenticate_header(headers) do
    headers
    |> Map.get("www-authenticate", [])
    |> List.first("")
    |> parse_www_authenticate_params()
  end

  defp parse_www_authenticate_params(header_value) do
    header_value
    |> String.split(",", trim: true)
    |> Enum.map(&split_kv/1)
    |> Map.new()
  end

  defp parse_www_authenticate_error(%{"error" => "insufficient_scope"}) do
    "The access token does not contain the required scopes."
  end

  defp parse_www_authenticate_error(%{"error_description" => description})
       when is_binary(description) do
    description
  end

  defp parse_www_authenticate_error(_) do
    "An unknown error occurred"
  end

  defp split_kv(item) do
    [key, value] = String.split(item, "=", parts: 2)

    clean_value =
      value
      |> String.trim()
      |> String.trim_leading("\"")
      |> String.trim_trailing("\"")

    {String.trim(key), clean_value}
  end

  defmodule Database do
    alias Portal.{Entra, Google, Okta, Safe}
    import Ecto.Query

    def list_all_directories(subject) do
      [
        Entra.Directory |> Safe.scoped(subject, :replica) |> Safe.all(),
        Google.Directory |> Safe.scoped(subject, :replica) |> Safe.all(),
        Okta.Directory |> Safe.scoped(subject, :replica) |> Safe.all()
      ]
      |> List.flatten()
      |> enrich_with_job_status()
      |> enrich_with_sync_stats(subject)
    end

    def get_directory!(schema, id, subject) do
      from(d in schema, where: d.id == ^id)
      |> Safe.scoped(subject, :replica)
      |> Safe.one!(fallback_to_primary: true)
    end

    def insert_directory(changeset, subject) do
      changeset
      |> Safe.scoped(subject)
      |> Safe.insert()
    end

    def update_directory(changeset, subject) do
      changeset
      |> Safe.scoped(subject)
      |> Safe.update()
    end

    def delete_directory(directory, subject) do
      # Delete the parent Portal.Directory, which will CASCADE delete the child
      parent =
        from(d in Portal.Directory, where: d.id == ^directory.id)
        |> Safe.scoped(subject, :replica)
        |> Safe.one!(fallback_to_primary: true)

      parent |> Safe.scoped(subject) |> Safe.delete()
    end

    def count_deletion_stats(directory, subject) do
      directory_id = directory.id

      actors_count =
        from(a in Portal.Actor,
          where: a.created_by_directory_id == ^directory_id
        )
        |> Safe.scoped(subject, :replica)
        |> Safe.aggregate(:count)

      identities_count =
        from(ei in Portal.ExternalIdentity,
          where: ei.directory_id == ^directory_id
        )
        |> Safe.scoped(subject, :replica)
        |> Safe.aggregate(:count)

      groups_count =
        from(g in Portal.Group,
          where: g.directory_id == ^directory_id
        )
        |> Safe.scoped(subject, :replica)
        |> Safe.aggregate(:count)

      policies_count =
        from(p in Portal.Policy,
          join: g in Portal.Group,
          on: p.group_id == g.id and p.account_id == g.account_id,
          where: g.directory_id == ^directory_id
        )
        |> Safe.scoped(subject, :replica)
        |> Safe.aggregate(:count)

      %{
        actors: actors_count,
        identities: identities_count,
        groups: groups_count,
        policies: policies_count
      }
    end

    def reload(nil, _subject), do: nil

    def reload(directory, subject) do
      # Reload the directory with fresh data
      schema = directory.__struct__

      from(d in schema, where: d.id == ^directory.id)
      |> Safe.scoped(subject, :replica)
      |> Safe.one()
    end

    defp enrich_with_job_status(directories) do
      # Get all directory IDs
      directory_ids = Enum.map(directories, & &1.id)

      # Query for active sync jobs for all directory types
      # Note: Oban.Job doesn't have account_id - security is ensured by
      # filtering on directory_ids which are already scoped to the account
      active_jobs =
        from(j in Oban.Job,
          where: j.worker in ["Portal.Entra.Sync", "Portal.Google.Sync", "Portal.Okta.Sync"],
          where: j.state in ["available", "executing", "scheduled"],
          where: fragment("?->>'directory_id'", j.args) in ^directory_ids,
          order_by: [desc: j.inserted_at]
        )
        |> Safe.unscoped(:replica)
        |> Safe.all()
        |> Enum.map(fn job -> {job.args["directory_id"], job} end)
        |> Map.new()

      # Query for most recent completed job per directory
      completed_jobs =
        from(j in Oban.Job,
          where: j.worker in ["Portal.Entra.Sync", "Portal.Google.Sync", "Portal.Okta.Sync"],
          where: j.state in ["completed", "discarded", "cancelled", "retryable"],
          where: fragment("?->>'directory_id'", j.args) in ^directory_ids,
          order_by: [desc: j.completed_at]
        )
        |> Safe.unscoped(:replica)
        |> Safe.all()
        |> Enum.uniq_by(& &1.args["directory_id"])
        |> Enum.map(fn job -> {job.args["directory_id"], job} end)
        |> Map.new()

      # Add has_active_job, is_legacy, and most_recent_job fields
      # most_recent_job is the active job if one exists, otherwise the last completed job
      Enum.map(directories, fn dir ->
        active_job = Map.get(active_jobs, dir.id)
        completed_job = Map.get(completed_jobs, dir.id)
        most_recent_job = active_job || completed_job

        dir
        |> Map.put(:has_active_job, active_job != nil)
        |> Map.put(:is_legacy, Map.get(dir, :legacy_service_account_key) != nil)
        |> Map.put(:most_recent_job, job_to_map(most_recent_job))
      end)
    end

    defp job_to_map(nil), do: nil

    defp job_to_map(job) do
      now = DateTime.utc_now()
      seconds = DateTime.diff(job.completed_at || now, job.inserted_at, :second)

      %{
        directory_id: job.args["directory_id"],
        state: job.state,
        completed_at: job.completed_at,
        inserted_at: job.inserted_at,
        elapsed_seconds: seconds,
        errors: job.errors
      }
    end

    defp enrich_with_sync_stats(directories, subject) do
      directory_ids = Enum.map(directories, & &1.id)

      # Count actors per directory (actors that have identities from this directory)
      actors_counts =
        from(ei in Portal.ExternalIdentity,
          where: ei.directory_id in ^directory_ids,
          group_by: ei.directory_id,
          select: {ei.directory_id, count(ei.actor_id, :distinct)}
        )
        |> Safe.scoped(subject, :replica)
        |> Safe.all()
        |> Map.new()

      # Count groups per directory
      groups_counts =
        from(g in Portal.Group,
          where: g.directory_id in ^directory_ids,
          group_by: g.directory_id,
          select: {g.directory_id, count(g.id)}
        )
        |> Safe.scoped(subject, :replica)
        |> Safe.all()
        |> Map.new()

      Enum.map(directories, fn dir ->
        dir
        |> Map.put(:actors_count, Map.get(actors_counts, dir.id, 0))
        |> Map.put(:groups_count, Map.get(groups_counts, dir.id, 0))
      end)
    end
  end
end

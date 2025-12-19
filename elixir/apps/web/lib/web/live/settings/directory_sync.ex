defmodule Web.Settings.DirectorySync do
  use Web, :live_view

  alias Domain.{
    Crypto.JWK,
    Entra,
    Google,
    Okta,
    PubSub
  }

  alias __MODULE__.DB

  import Ecto.Changeset

  require Logger

  @modules %{
    "entra" => Entra.Directory,
    "google" => Google.Directory,
    "okta" => Okta.Directory
  }

  @types Map.keys(@modules)

  @common_fields ~w[name is_disabled disabled_reason is_verified error_message]a

  @fields %{
    Entra.Directory => @common_fields ++ ~w[tenant_id sync_all_groups]a,
    Google.Directory => @common_fields ++ ~w[domain impersonation_email]a,
    Okta.Directory => @common_fields ++ ~w[okta_domain client_id private_key_jwk kid]a
  }

  def mount(_params, _session, socket) do
    socket = assign(socket, page_title: "Directory Sync")

    if connected?(socket) do
      :ok = PubSub.Account.subscribe(socket.assigns.subject.account.id)
    end

    {:ok, init(socket, new: true)}
  end

  defp init(socket, opts \\ []) do
    new = Keyword.get(opts, :new, false)
    directories = DB.list_all_directories(socket.assigns.subject)

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
    directory = DB.get_directory!(schema, id, socket.assigns.subject)
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
    raise Web.LiveErrors.NotFoundError
  end

  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/settings/directory_sync")}
  end

  def handle_event("validate", %{"directory" => attrs}, socket) do
    # Preserve is_verified from the current form state
    current = apply_changes(socket.assigns.form.source)
    attrs = Map.put(attrs, "is_verified", current.is_verified)

    changeset =
      current
      |> changeset(attrs)
      |> clear_verification_if_trigger_fields_changed()
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("generate_keypair", _params, socket) do
    # Generate the keypair
    keypair = JWK.generate_jwk_and_jwks()

    # Update the changeset with the prevate key JWK and kid
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
    changeset =
      socket.assigns.form.source
      |> delete_change(:is_verified)
      |> delete_change(:domain)
      |> delete_change(:tenant_id)
      |> delete_change(:okta_domain)
      |> apply_changes()
      |> changeset(%{
        "is_verified" => false,
        "domain" => nil,
        "tenant_id" => nil,
        "okta_domain" => nil
      })

    {:noreply, assign(socket, verification_error: nil, form: to_form(changeset))}
  end

  def handle_event("submit_directory", _params, socket) do
    submit_directory(socket)
  end

  def handle_event("delete_directory", %{"id" => id}, socket) do
    directory = socket.assigns.directories |> Enum.find(fn d -> d.id == id end)

    case DB.delete_directory(directory, socket.assigns.subject) do
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
      # Set disabled_reason when disabling, clear error state when enabling
      changeset =
        if new_disabled_state do
          # Disabling - set reason
          changeset(directory, %{
            "is_disabled" => true,
            "disabled_reason" => "Disabled by admin"
          })
        else
          # Enabling - check if directory is verified first
          if directory.is_verified do
            # Clear error state when enabling
            changeset(directory, %{
              "is_disabled" => false,
              "disabled_reason" => nil,
              "error_email_count" => 0,
              "error_message" => nil,
              "errored_at" => nil
            })
          else
            # Can't enable unverified directory
            changeset(directory, %{})
            |> Ecto.Changeset.add_error(
              :is_verified,
              "Directory must be verified before enabling"
            )
          end
        end

      case DB.update_directory(changeset, socket.assigns.subject) do
        {:ok, _directory} ->
          action = if new_disabled_state, do: "disabled", else: "enabled"

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
        "entra" -> Domain.Entra.Sync
        "google" -> Domain.Google.Sync
        "okta" -> Domain.Okta.Sync
        _ -> raise "Unsupported directory type for sync: #{type}"
      end

    case Oban.insert(sync_module.new(%{"directory_id" => id})) do
      {:ok, _job} ->
        {:noreply, put_flash(socket, :success, "Directory sync has been queued successfully.")}

      {:error, reason} ->
        Logger.info("Failed to enqueue #{type} sync job", id: id, reason: inspect(reason))
        {:noreply, put_flash(socket, :error, "Failed to queue directory sync.")}
    end
  end

  def handle_info(:do_verification, socket) do
    start_verification(socket)
  end

  def handle_info({:entra_admin_consent, pid, _issuer, tenant_id, state_token}, socket) do
    :ok = Domain.PubSub.unsubscribe("entra-admin-consent:#{state_token}")
    stored_token = socket.assigns.verification.token

    # Verify the state token matches
    if stored_token && Plug.Crypto.secure_compare(stored_token, state_token) do
      send(pid, :success)

      # Verification was already done in verification.ex before broadcasting
      attrs = %{
        "is_verified" => true,
        "tenant_id" => tenant_id
      }

      changeset =
        socket.assigns.form.source
        |> apply_changes()
        |> changeset(attrs)

      {:noreply, assign(socket, form: to_form(changeset), verification_error: nil)}
    else
      send(pid, {:error, :token_mismatch})
      error = "Failed to verify directory: token mismatch"
      {:noreply, assign(socket, verification_error: error)}
    end
  end

  def handle_info(:directories_changed, socket) do
    {:noreply, init(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/settings/directory_sync"}>
        Directory Sync Settings
      </.breadcrumb>
    </.breadcrumbs>

    <%= if Domain.Account.idp_sync_enabled?(@account) do %>
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
          <div class="flex flex-wrap gap-4">
            <%= for directory <- @directories do %>
              <.directory_card
                type={directory_type(directory)}
                account={@account}
                directory={directory}
                subject={@subject}
                is_legacy={directory.is_legacy}
              />
            <% end %>
          </div>
        </:content>
      </.section>
    <% else %>
      <.section>
        <:title>Directories</:title>
        <:action><.docs_action path="/guides/settings/directory-sync" /></:action>
        <:content>
          <div class="relative">
            <!-- Blurred preview content -->
            <div class="blur-sm pointer-events-none select-none opacity-60">
              <div class="flex flex-wrap gap-4">
                <div class="flex flex-col bg-neutral-50 rounded-lg p-4" style="width: 28rem;">
                  <div class="flex items-center justify-between mb-3">
                    <div class="flex items-center flex-1 min-w-0">
                      <.provider_icon type="google" class="w-7 h-7 mr-2 flex-shrink-0" />
                      <div class="flex flex-col min-w-0">
                        <span class="font-medium text-xl truncate">Google Workspace</span>
                        <span class="text-xs text-neutral-500 font-mono">Example directory</span>
                      </div>
                    </div>
                  </div>
                  <div class="mt-auto bg-white rounded-lg p-3 space-y-3 text-sm text-neutral-600">
                    <div class="flex items-center gap-2">
                      <.icon name="hero-user-group" class="w-5 h-5 flex-shrink-0" />
                      <span class="font-medium">42 users synced</span>
                    </div>
                    <div class="flex items-center gap-2">
                      <.icon name="hero-arrow-path" class="w-5 h-5 flex-shrink-0" />
                      <span class="font-medium">Auto-syncs every hour</span>
                    </div>
                  </div>
                </div>
                <div class="flex flex-col bg-neutral-50 rounded-lg p-4" style="width: 28rem;">
                  <div class="flex items-center justify-between mb-3">
                    <div class="flex items-center flex-1 min-w-0">
                      <.provider_icon type="entra" class="w-7 h-7 mr-2 flex-shrink-0" />
                      <div class="flex flex-col min-w-0">
                        <span class="font-medium text-xl truncate">Microsoft Entra</span>
                        <span class="text-xs text-neutral-500 font-mono">Example directory</span>
                      </div>
                    </div>
                  </div>
                  <div class="mt-auto bg-white rounded-lg p-3 space-y-3 text-sm text-neutral-600">
                    <div class="flex items-center gap-2">
                      <.icon name="hero-user-group" class="w-5 h-5 flex-shrink-0" />
                      <span class="font-medium">128 users synced</span>
                    </div>
                    <div class="flex items-center gap-2">
                      <.icon name="hero-arrow-path" class="w-5 h-5 flex-shrink-0" />
                      <span class="font-medium">Auto-syncs every hour</span>
                    </div>
                  </div>
                </div>
              </div>
            </div>
            <!-- Marketing overlay -->
            <div class="absolute inset-0 flex items-center justify-center">
              <div class="bg-white rounded-xl shadow-lg p-6 max-w-md text-center border border-neutral-200">
                <div class="mb-4">
                  <.icon name="hero-arrow-path" class="w-10 h-10 text-accent-500 mx-auto" />
                </div>
                <h3 class="text-xl font-semibold text-neutral-900 mb-2">
                  Automate User & Group Management
                </h3>
                <p class="text-base text-neutral-600 mb-4">
                  Connect your identity provider to automatically sync users and groups.
                </p>
                <ul class="text-left text-base text-neutral-700 mb-4 space-y-2">
                  <li class="flex items-center gap-2">
                    <.icon name="hero-check-circle" class="w-5 h-5 text-green-500 flex-shrink-0" />
                    Sync from Google, Entra, or Okta
                  </li>
                  <li class="flex items-center gap-2">
                    <.icon name="hero-check-circle" class="w-5 h-5 text-green-500 flex-shrink-0" />
                    Automatic hourly synchronization
                  </li>
                  <li class="flex items-center gap-2">
                    <.icon name="hero-check-circle" class="w-5 h-5 text-green-500 flex-shrink-0" />
                    Instant deprovisioning
                  </li>
                </ul>
                <.button
                  style="primary"
                  icon="hero-sparkles-solid"
                  navigate={~p"/#{@account}/settings/billing"}
                >
                  Upgrade to Unlock
                </.button>
              </div>
            </div>
          </div>
        </:content>
      </.section>
    <% end %>

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
          public_jwk={assigns[:public_jwk]}
        />
      </:body>
      <:confirm_button form="directory-form" type="submit">Create</:confirm_button>
    </.modal>

    <!-- Edit Directory Modal -->
    <.modal
      :if={@live_action == :edit}
      id="edit-directory-modal"
      on_close="close_modal"
      confirm_disabled={
        not @form.source.valid? or Enum.empty?(@form.source.changes) or not verified?(@form)
      }
    >
      <:title icon={@type}>Edit {@directory_name}</:title>
      <:body>
        <.flash :if={assigns[:is_legacy]} kind={:warning_inline}>
          This directory uses legacy credentials and needs to be updated to use Firezone's shared service account.
          <.website_link path="/kb/">
            Read the docs
          </.website_link>
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

  attr :type, :string, required: true
  attr :account, :any, required: true
  attr :directory, :any, required: true
  attr :subject, :any, required: true
  attr :is_legacy, :boolean, default: false

  defp directory_card(assigns) do
    # Determine if toggle should be disabled (when directory is disabled and account lacks feature)
    toggle_disabled = assigns.directory.is_disabled and not assigns.account.features.idp_sync
    assigns = assign(assigns, :toggle_disabled, toggle_disabled)

    ~H"""
    <div class="flex flex-col bg-neutral-50 rounded-lg p-4" style="width: 28rem;">
      <div class="flex items-center justify-between mb-3">
        <div class="flex items-center flex-1 min-w-0">
          <.provider_icon type={@type} class="w-7 h-7 mr-2 flex-shrink-0" />
          <div class="flex flex-col min-w-0">
            <div class="flex items-center gap-2">
              <span class="font-medium text-xl truncate" title={@directory.name}>
                {@directory.name}
              </span>
              <.badge :if={@is_legacy} type="warning">LEGACY</.badge>
            </div>
            <span class="text-xs text-neutral-500 font-mono">
              ID: {@directory.id}
            </span>
          </div>
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
              disabled={@toggle_disabled}
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
                    <.deletion_stats directory={@directory} subject={@subject} />
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
        <%= if @directory.is_disabled and @directory.disabled_reason == "Sync error" do %>
          <.flash kind={:error_inline}>
            <p class="font-semibold">Sync has been disabled due to an error</p>
            <%= if @directory.error_message do %>
              <p class="mt-1 text-sm">{@directory.error_message}</p>
            <% end %>
            <p class="mt-2 text-sm">
              <.link
                patch={~p"/#{@account}/settings/directory_sync/#{@type}/#{@directory.id}/edit"}
                class="underline font-medium"
              >
                Edit the directory
              </.link>
              and re-verify to enable syncing.
            </p>
          </.flash>
        <% else %>
          <%= if @directory.is_disabled do %>
            <div class="flex items-center gap-2">
              <.icon
                name="hero-no-symbol"
                class="w-5 h-5 flex-shrink-0 text-red-600"
                title="Disabled"
              />
              <span class="font-medium text-red-600">
                Disabled
                <%= if @directory.disabled_reason do %>
                  - {@directory.disabled_reason}
                <% end %>
              </span>
            </div>
          <% end %>
        <% end %>

        <div class="flex items-center gap-2">
          <.icon name="hero-identification" class="w-5 h-5 flex-shrink-0" title="Tenant" />
          <span class="font-medium">
            {directory_identifier(@type, @directory)}
          </span>
        </div>

        <%= if @type == "entra" do %>
          <div class="flex items-center gap-2">
            <.icon name="hero-user-group" class="w-5 h-5 flex-shrink-0" title="Group Sync Mode" />
            <span class="font-medium">
              <%= if @directory.sync_all_groups do %>
                All groups
              <% else %>
                Assigned groups only
              <% end %>
            </span>
          </div>
        <% end %>

        <%= if @directory.has_active_job do %>
          <div class="flex items-center justify-between gap-2">
            <div class="flex items-center gap-2">
              <.icon
                name="hero-arrow-path"
                class="w-5 h-5 flex-shrink-0 text-accent-600 animate-spin"
                title="Sync in Progress"
              />
              <span class="font-medium text-accent-600">
                Sync in progress...
              </span>
            </div>
            <%!-- Invisible spacer to match button height and prevent vertical jump --%>
            <div class="h-6"></div>
          </div>
        <% else %>
          <%= if @directory.synced_at do %>
            <div class="flex items-center justify-between gap-2">
              <div class="flex items-center gap-2">
                <.icon name="hero-arrow-path" class="w-5 h-5 flex-shrink-0" title="Last Synced" />
                <span class="font-medium">
                  synced <.relative_datetime datetime={@directory.synced_at} />
                </span>
              </div>
              <.button
                size="xs"
                style="primary"
                phx-click="sync_directory"
                phx-value-id={@directory.id}
                phx-value-type={@type}
                disabled={@directory.is_disabled}
              >
                Sync Now
              </.button>
            </div>
          <% else %>
            <div class="flex items-center justify-between gap-2">
              <div class="flex items-center gap-2">
                <.icon
                  name="hero-arrow-path"
                  class="w-5 h-5 flex-shrink-0 text-neutral-400"
                  title="Never Synced"
                />
                <span class="font-medium text-neutral-400">
                  Never synced
                </span>
              </div>
              <.button
                size="xs"
                style="primary"
                phx-click="sync_directory"
                phx-value-id={@directory.id}
                phx-value-type={@type}
                disabled={@directory.is_disabled}
              >
                Sync Now
              </.button>
            </div>
          <% end %>
        <% end %>

        <div class="flex items-center gap-2">
          <.icon name="hero-clock" class="w-5 h-5 flex-shrink-0" title="Updated" />
          <span class="font-medium">
            updated <.relative_datetime datetime={@directory.updated_at} />
          </span>
        </div>
      </div>
    </div>
    """
  end

  attr :directory, :any, required: true
  attr :subject, :any, required: true

  defp deletion_stats(assigns) do
    stats = DB.count_deletion_stats(assigns.directory, assigns.subject)
    total = stats.actors + stats.identities + stats.groups + stats.policies
    assigns = assign(assigns, stats: stats, total: total)

    ~H"""
    <div>
      <p class="text-neutral-700">
        Are you sure you want to delete <strong>{@directory.name}</strong>?
      </p>
      <%= if @total > 0 do %>
        <p class="mt-3 text-neutral-700">
          This will permanently delete:
        </p>
        <ul class="list-disc list-inside mt-2 text-neutral-700 space-y-1">
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
        <p class="mt-2 text-neutral-600">This action cannot be undone.</p>
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

        <div :if={@type == "entra"}>
          <label class="block text-sm font-medium text-neutral-700 mb-3">
            Group sync mode
          </label>
          <div class="grid gap-4 md:grid-cols-2">
            <label class={[
              "flex flex-col p-4 border-2 rounded-lg cursor-pointer transition-all",
              if(@form[:sync_all_groups].value == false,
                do: "border-accent-500 bg-accent-50",
                else: "border-neutral-200 hover:border-neutral-300"
              )
            ]}>
              <input
                type="radio"
                name={@form[:sync_all_groups].name}
                value="false"
                checked={@form[:sync_all_groups].value == false}
                class="sr-only"
              />
              <div class="mb-2">
                <span class="text-base font-semibold text-neutral-900">
                  Assigned groups only
                </span>
              </div>
              <span class="text-sm text-neutral-600">
                Only groups assigned to the
                <code class="text-xs"><strong>Firezone Authentication</strong></code>
                managed application will be synced. Requires Entra ID P1/P2 or higher.
                <strong class="block mt-1">Recommended for most users.</strong>
              </span>
            </label>

            <label class={[
              "flex flex-col p-4 border-2 rounded-lg cursor-pointer transition-all",
              if(@form[:sync_all_groups].value == true,
                do: "border-accent-500 bg-accent-50",
                else: "border-neutral-200 hover:border-neutral-300"
              )
            ]}>
              <input
                type="radio"
                name={@form[:sync_all_groups].name}
                value="true"
                checked={@form[:sync_all_groups].value == true}
                class="sr-only"
              />
              <div class="mb-2">
                <span class="text-base font-semibold text-neutral-900">
                  All groups
                </span>
              </div>
              <span class="text-sm text-neutral-600">
                All groups from your directory will be synced. Use this for Entra ID Free or to sync all groups without managing assignments.
              </span>
            </label>
          </div>
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

        <div :if={@type == "okta"} class="p-4 border-2 border-neutral-200 bg-neutral-50 rounded-lg">
          <div class="flex items-center justify-between mb-4">
            <div class="flex-1">
              <h3 class="text-base font-semibold text-neutral-900">Public Key (JWK)</h3>
              <p class="mt-1 text-sm text-neutral-600">
                Generate a keypair and copy the public key to your Okta application settings.
              </p>
            </div>
            <div class="ml-4">
              <.button
                type="button"
                phx-click="generate_keypair"
                icon="hero-key"
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
                  class="text-xs rounded-lg [&_code]:h-72 [&_code]:overflow-y-auto [&_code]:whitespace-pre-wrap [&_code]:break-all [&_code]:p-2"
                >
                  {JSON.encode!(@public_jwk)}
                </.code_block>
              </div>
              <p class="mt-2 text-xs text-neutral-600">
                Copy this public key and add it to your Okta application's JWKS configuration.
              </p>
            </div>
          <% else %>
            <p class="text-sm text-neutral-500 italic">
              No keypair generated yet. Click "Generate Keypair" to create one.
            </p>
          <% end %>
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
    field =
      case assigns.type do
        "google" -> :domain
        "entra" -> :tenant_id
        "okta" -> :okta_domain
      end

    assigns = assign(assigns, :field, field)

    ~H"""
    <div class="flex justify-between items-center">
      <label class="text-sm font-medium text-neutral-700">{Phoenix.Naming.humanize(@field)}</label>
      <div class="text-right">
        <p class="text-sm font-semibold text-neutral-900">
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
      {excluded, _errors}
      when excluded in [:is_verified, :domain, :tenant_id, :okta_domain] ->
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
      %Domain.Directory{}
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
    |> DB.insert_directory(socket.assigns.subject)
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
    |> DB.update_directory(socket.assigns.subject)
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
    config = Domain.Config.fetch_env!(:domain, Google.APIClient)
    key = config[:service_account_key] |> JSON.decode!()

    with {:ok, %Req.Response{status: 200, body: %{"access_token" => access_token}}} <-
           Google.APIClient.get_access_token(impersonation_email, key),
         {:ok, %Req.Response{status: 200, body: body}} <-
           Google.APIClient.get_customer(access_token),
         :ok <- Google.APIClient.test_connection(access_token, body["customerDomain"]) do
      changeset =
        changeset
        |> apply_changes()
        |> changeset(%{
          "domain" => body["customerDomain"],
          "is_verified" => true
        })

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
    #
    # IMPORTANT: Use the .default scope to request all application permissions
    # configured in the app registration. This is the correct way to request
    # application permissions (not delegated) via the admin consent endpoint.

    token = Domain.Crypto.random_token(32)
    state = "entra-admin-consent:#{token}"

    config = Domain.Config.fetch_env!(:domain, Entra.APIClient)
    client_id = config[:client_id]

    # Build admin consent URL - route through /auth/oidc/callback so admins only need one redirect URI
    redirect_uri = url(~p"/auth/oidc/callback")

    # Use .default scope to request all configured application permissions
    params = %{
      client_id: client_id,
      state: state,
      redirect_uri: redirect_uri,
      scope: "https://graph.microsoft.com/.default"
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
    changeset = socket.assigns.form.source
    okta_domain = get_field(changeset, :okta_domain)
    client_id = get_field(changeset, :client_id)
    private_key_jwk = get_field(changeset, :private_key_jwk)
    kid = get_field(changeset, :kid)

    client = Okta.APIClient.new(okta_domain, client_id, private_key_jwk, kid)

    with {:ok, access_token} <- Okta.APIClient.fetch_access_token(client),
         :ok <- Okta.APIClient.test_connection(client, access_token) do
      changeset =
        changeset
        |> apply_changes()
        |> changeset(%{"is_verified" => true})

      {:noreply,
       assign(socket, form: to_form(changeset), verification_error: nil, verifying: false)}
    else
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

  defp parse_google_verification_error({:error, reason}) do
    "Failed to verify directory access: #{inspect(reason)}"
  end

  defp parse_google_verification_error(error) do
    Logger.error("Unknown Google verification error", error: inspect(error))

    "Unknown error during verification. Please try again. If the problem persists, contact support."
  end

  defp parse_okta_verification_error({:error, %Req.Response{status: 400, body: body}}) do
    error_code = body["errorCode"]
    error_summary = body["errorSummary"]

    cond do
      error_code == "E0000021" ->
        "Bad request to Okta API. Please verify your Okta domain and API configuration."

      error_code == "E0000001" ->
        "API validation failed: #{error_summary || "Invalid request parameters"}"

      error_code == "E0000003" ->
        "The request body was invalid. Please check your configuration."

      error_code == "invalid_client" ->
        "Invalid client application. Please verify your Client ID is correct."

      error_summary ->
        "Configuration error: #{error_summary}"

      true ->
        "HTTP 400 Bad Request. Please verify your Okta domain and Client ID."
    end
  end

  defp parse_okta_verification_error({:error, %Req.Response{status: 401, body: body}}) do
    error_code = body["errorCode"]
    error_summary = body["errorSummary"]

    cond do
      error_code == "E0000011" ->
        "Invalid token. Please ensure your Client ID and private key are correct and the JWT is properly signed."

      error_code == "E0000061" ->
        "Access denied. The client application is not authorized to use this API."

      error_code == "invalid_client" ->
        "Client authentication failed. Please verify your Client ID and ensure the public key is registered in Okta."

      error_summary ->
        "Authentication failed: #{error_summary}"

      true ->
        "HTTP 401 Unauthorized. Please check your Client ID and ensure the public key matches your private key."
    end
  end

  defp parse_okta_verification_error(
         {:error, %Req.Response{status: 403, body: "", headers: headers}}
       ) do
    headers
    |> extract_www_authenticate_header()
    |> parse_www_authenticate_error()
  end

  defp parse_okta_verification_error({:error, %Req.Response{status: 403, body: body}}) do
    error_code = body["errorCode"]
    error_summary = body["errorSummary"]

    cond do
      error_code == "E0000006" ->
        "Access denied. You do not have permission to perform this action. Ensure the API service app has the required scopes."

      error_code == "E0000022" ->
        "API access denied. The feature may not be available for your Okta organization."

      error_summary ->
        "Permission denied: #{error_summary}"

      true ->
        "HTTP 403 Forbidden. Ensure the application has okta.users.read and okta.groups.read scopes granted."
    end
  end

  defp parse_okta_verification_error({:error, %Req.Response{status: 404, body: body}}) do
    error_code = body["errorCode"]
    error_summary = body["errorSummary"]

    cond do
      error_code == "E0000007" ->
        "Resource not found. The API endpoint or resource doesn't exist. Please verify your Okta domain."

      error_summary ->
        "Not found: #{error_summary}"

      true ->
        "HTTP 404 Not Found. Please verify your Okta domain (e.g., your-domain.okta.com) is correct."
    end
  end

  defp parse_okta_verification_error({:error, %Req.Response{status: status}})
       when status >= 500 do
    "Okta service is currently unavailable (HTTP #{status}). Please try again later."
  end

  defp parse_okta_verification_error(error) do
    Logger.error("Unknown Okta verification error", error: inspect(error))

    "Unknown error during verification. Please try again. If the problem persists, contact support."
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
    "The access token provided does not contain the required scopes."
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

  defmodule DB do
    alias Domain.{Entra, Google, Okta, Safe}
    import Ecto.Query

    def list_all_directories(subject) do
      [
        Entra.Directory |> Safe.scoped(subject) |> Safe.all(),
        Google.Directory |> Safe.scoped(subject) |> Safe.all(),
        Okta.Directory |> Safe.scoped(subject) |> Safe.all()
      ]
      |> List.flatten()
      |> enrich_with_job_status()
    end

    def get_directory!(schema, id, subject) do
      from(d in schema, where: d.id == ^id)
      |> Safe.scoped(subject)
      |> Safe.one!()
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
      # Delete the parent Domain.Directory, which will CASCADE delete the child
      parent =
        from(d in Domain.Directory, where: d.id == ^directory.id)
        |> Safe.scoped(subject)
        |> Safe.one!()

      parent |> Safe.scoped(subject) |> Safe.delete()
    end

    def count_deletion_stats(directory, subject) do
      directory_id = directory.id

      actors_count =
        from(a in Domain.Actor,
          where: a.created_by_directory_id == ^directory_id
        )
        |> Safe.scoped(subject)
        |> Safe.aggregate(:count)

      identities_count =
        from(ei in Domain.ExternalIdentity,
          where: ei.directory_id == ^directory_id
        )
        |> Safe.scoped(subject)
        |> Safe.aggregate(:count)

      groups_count =
        from(g in Domain.Group,
          where: g.directory_id == ^directory_id
        )
        |> Safe.scoped(subject)
        |> Safe.aggregate(:count)

      policies_count =
        from(p in Domain.Policy,
          join: g in Domain.Group,
          on: p.group_id == g.id,
          where: g.directory_id == ^directory_id
        )
        |> Safe.scoped(subject)
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
      |> Safe.scoped(subject)
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
          where: j.worker in ["Domain.Entra.Sync", "Domain.Google.Sync", "Domain.Okta.Sync"],
          where: j.state in ["available", "executing", "scheduled"],
          where: fragment("?->>'directory_id'", j.args) in ^directory_ids
        )
        |> Safe.unscoped()
        |> Safe.all()
        |> Enum.map(fn job ->
          directory_id = job.args["directory_id"]
          {directory_id, job.id}
        end)
        |> Map.new()

      # Add has_active_job and is_legacy fields to each directory
      Enum.map(directories, fn dir ->
        dir
        |> Map.put(:has_active_job, Map.has_key?(active_jobs, dir.id))
        |> Map.put(:is_legacy, Map.get(dir, :legacy_service_account_key) != nil)
      end)
    end
  end
end

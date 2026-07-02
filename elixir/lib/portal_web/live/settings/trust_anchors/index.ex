defmodule PortalWeb.Settings.TrustAnchors.Index do
  use PortalWeb, :live_view

  import Ecto.Changeset, only: [cast: 3, put_change: 3, add_error: 3]

  alias Portal.{Safe, TrustAnchor}

  @max_upload_size 1_000_000
  @max_upload_entries 10

  defmodule Database do
    import Ecto.Query
    alias Portal.{Safe, TrustAnchor}

    def list_trust_anchors(subject) do
      from(t in TrustAnchor, order_by: [asc: t.inserted_at, asc: t.id])
      |> Safe.scoped(subject, :replica)
      |> Safe.all()
      |> Safe.preload(:certificates, :replica)
    end

    def get_trust_anchor!(id, subject) do
      # A point lookup for the edit panel, not a hot path: `one!/2` already
      # falls back to primary on replica lag, so preload certificates from
      # primary too rather than risk a mismatched primary parent / stale
      # replica children read.
      from(t in TrustAnchor, where: t.id == ^id)
      |> Safe.scoped(subject, :replica)
      |> Safe.one!(fallback_to_primary: true)
      |> Safe.preload(:certificates, :primary)
    end
  end

  def mount(_params, _session, socket) do
    trust_anchors_enabled? = PortalWeb.NavigationComponents.trust_anchors_enabled?()

    if trust_anchors_enabled? do
      trust_anchors = Database.list_trust_anchors(socket.assigns.subject)

      socket =
        socket
        |> assign(page_title: "Trust Anchors")
        |> assign(trust_anchors: trust_anchors)
        |> assign(selected_trust_anchor: nil)
        |> assign(form: nil, input_mode: :paste)
        |> assign(pending_delete_id: nil, open_trust_anchor_actions_id: nil)
        |> assign(trust_anchors_enabled?: trust_anchors_enabled?)
        |> allow_upload(:cert_file,
          accept: ~w(.pem .crt .cer .der .txt),
          max_entries: @max_upload_entries,
          max_file_size: @max_upload_size,
          auto_upload: true
        )

      {:ok, socket}
    else
      {:ok, push_navigate(socket, to: ~p"/#{socket.assigns.account}/settings/account")}
    end
  end

  def handle_params(_params, _uri, %{assigns: %{live_action: :new}} = socket) do
    changeset = build_creation_changeset(%{})

    socket =
      socket
      |> assign(selected_trust_anchor: nil, input_mode: :paste, open_trust_anchor_actions_id: nil)
      |> assign(form: to_form(changeset, as: "trust_anchor"))

    {:noreply, socket}
  end

  def handle_params(%{"id" => id}, _uri, %{assigns: %{live_action: :edit}} = socket) do
    trust_anchor = Database.get_trust_anchor!(id, socket.assigns.subject)
    changeset = build_edit_changeset(trust_anchor, %{})

    socket =
      socket
      |> assign(
        selected_trust_anchor: trust_anchor,
        input_mode: :paste,
        open_trust_anchor_actions_id: nil
      )
      |> assign(form: to_form(changeset, as: "trust_anchor"))

    {:noreply, socket}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply,
     assign(socket,
       selected_trust_anchor: nil,
       form: nil,
       input_mode: :paste,
       pending_delete_id: nil,
       open_trust_anchor_actions_id: nil
     )}
  end

  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-full" phx-window-keydown="handle_keydown" phx-key="Escape">
      <.settings_nav
        account={@account}
        current_path={@current_path}
        trust_anchors_enabled?={@trust_anchors_enabled?}
      />

      <div class="flex-1 flex flex-col overflow-hidden">
        <div class="flex items-center justify-between px-6 py-3 border-b border-border shrink-0">
          <div class="flex items-center gap-2">
            <h2 class="text-xs font-semibold text-heading">Trust Anchors</h2>
            <span class="text-xs text-subtle tabular-nums">
              {length(@trust_anchors)}
            </span>
          </div>
          <div class="flex items-center gap-2">
            <.link
              patch={~p"/#{@account}/settings/trust_anchors/new"}
              class="flex items-center gap-1 px-2.5 py-1 rounded text-xs border border-border-strong text-body hover:text-heading hover:border-border-emphasis bg-surface transition-colors"
            >
              <.icon name="ri-add-line" class="w-3 h-3" /> Add
            </.link>
          </div>
        </div>

        <div class="flex-1 overflow-auto">
          <%= if Enum.empty?(@trust_anchors) do %>
            <div class="flex items-center justify-center h-full">
              <div class="flex flex-col items-center gap-3 py-16">
                <div class="w-9 h-9 rounded-lg border border-border bg-raised flex items-center justify-center">
                  <.icon name="ri-shield-check-line" class="w-3 h-3" />
                </div>
                <div class="text-center">
                  <p class="text-sm font-medium text-heading">No trust anchors yet</p>
                  <p class="text-xs text-subtle mt-0.5">
                    Add a CA certificate chain to validate presented certificates against.
                  </p>
                </div>
                <.link
                  patch={~p"/#{@account}/settings/trust_anchors/new"}
                  class="flex items-center gap-1 px-2.5 py-1 rounded text-xs border border-border-strong text-body hover:text-heading hover:border-border-emphasis bg-surface transition-colors"
                >
                  <.icon name="ri-add-line" class="w-3 h-3" /> Add a trust anchor
                </.link>
              </div>
            </div>
          <% else %>
            <table class="w-full text-sm border-collapse">
              <thead class="sticky top-0 z-10 bg-raised">
                <tr class="border-b border-border-strong">
                  <th class="px-6 py-2.5 text-left text-[10px] font-semibold tracking-widest uppercase text-subtle">
                    Name
                  </th>
                  <th class="px-6 py-2.5 text-left text-[10px] font-semibold tracking-widest uppercase text-subtle w-36">
                    Certificates
                  </th>
                  <th class="px-6 py-2.5 text-left text-[10px] font-semibold tracking-widest uppercase text-subtle w-36">
                    Created
                  </th>
                  <th class="px-6 py-2.5 w-10"></th>
                </tr>
              </thead>
              <tbody>
                <.trust_anchor_row
                  :for={trust_anchor <- @trust_anchors}
                  account={@account}
                  trust_anchor={trust_anchor}
                  pending_delete_id={@pending_delete_id}
                  open_trust_anchor_actions_id={@open_trust_anchor_actions_id}
                />
              </tbody>
            </table>
          <% end %>
        </div>
      </div>

    <!-- Creation Panel (:new) -->
      <div
        id="trust-anchor-new-panel"
        class={[
          "fixed top-14 right-0 bottom-0 z-20 flex flex-col w-full lg:w-3/4 xl:w-1/2",
          "bg-elevated border-l border-border-strong",
          "shadow-[-4px_0px_20px_rgba(0,0,0,0.07)]",
          "transition-transform duration-200 ease-in-out",
          (@live_action == :new && "translate-x-0") || "translate-x-full"
        ]}
      >
        <div :if={@live_action == :new && @form} class="flex flex-col h-full overflow-hidden">
          <div class="shrink-0 px-5 pt-4 pb-3 border-b border-border bg-elevated">
            <div class="flex items-center justify-between gap-3">
              <h2 class="text-sm font-semibold text-heading">New Trust Anchor</h2>
              <.icon_button icon="ri-close-line" title="Close (Esc)" phx-click="close_panel" />
            </div>
          </div>

          <.form
            id="trust-anchor-new-form"
            for={@form}
            phx-change="validate_new"
            phx-submit="create_trust_anchor"
            class="flex flex-col flex-1 min-h-0 overflow-hidden"
          >
            <div class="flex-1 overflow-y-auto px-5 py-4 space-y-4">
              <.trust_anchor_form_fields form={@form} input_mode={@input_mode} uploads={@uploads} />
            </div>

            <div class="shrink-0 flex items-center justify-end gap-2 px-5 py-3 border-t border-border bg-elevated">
              <.button type="button" phx-click="close_panel" size="sm">
                Cancel
              </.button>
              <.button type="submit" style="primary" size="sm">
                Create
              </.button>
            </div>
          </.form>
        </div>
      </div>

    <!-- Edit Panel (:edit) -->
      <div
        id="trust-anchor-edit-panel"
        class={[
          "fixed top-14 right-0 bottom-0 z-20 flex flex-col w-full lg:w-3/4 xl:w-1/2",
          "bg-elevated border-l border-border-strong",
          "shadow-[-4px_0px_20px_rgba(0,0,0,0.07)]",
          "transition-transform duration-200 ease-in-out",
          (@live_action == :edit && "translate-x-0") || "translate-x-full"
        ]}
      >
        <div
          :if={@live_action == :edit && @selected_trust_anchor && @form}
          class="flex flex-col h-full overflow-hidden"
        >
          <div class="shrink-0 px-5 pt-4 pb-3 border-b border-border bg-elevated">
            <div class="flex items-center justify-between gap-3">
              <h2 class="text-sm font-semibold text-heading">Edit Trust Anchor</h2>
              <.icon_button icon="ri-close-line" title="Close (Esc)" phx-click="close_panel" />
            </div>
          </div>

          <.form
            id="trust-anchor-edit-form"
            for={@form}
            phx-change="validate_edit"
            phx-submit="update_trust_anchor"
            class="flex flex-col flex-1 min-h-0 overflow-hidden"
          >
            <div class="flex-1 overflow-y-auto px-5 py-4 space-y-4">
              <.trust_anchor_form_fields form={@form} input_mode={@input_mode} uploads={@uploads} />
            </div>

            <div class="shrink-0 flex items-center justify-end gap-2 px-5 py-3 border-t border-border bg-elevated">
              <.button type="button" phx-click="close_panel" size="sm">
                Cancel
              </.button>
              <.button type="submit" style="primary" size="sm">
                Save
              </.button>
            </div>
          </.form>
        </div>
      </div>
    </div>
    """
  end

  attr :account, :any, required: true
  attr :trust_anchor, :any, required: true
  attr :pending_delete_id, :any, required: true
  attr :open_trust_anchor_actions_id, :string, default: nil

  defp trust_anchor_row(assigns) do
    is_pending_delete = assigns.pending_delete_id == assigns.trust_anchor.id
    assigns = assign(assigns, is_pending_delete: is_pending_delete)

    ~H"""
    <tr class={[
      "border-b transition-colors",
      @is_pending_delete && "border-red-200 bg-red-50",
      !@is_pending_delete && "border-border hover:bg-raised"
    ]}>
      <%= if @is_pending_delete do %>
        <td class="px-6 py-3">
          <div class="text-sm font-medium text-danger truncate">{@trust_anchor.name}</div>
          <div class="font-mono text-[10px] text-danger/80 mt-0.5 truncate">{@trust_anchor.id}</div>
        </td>
        <td colspan="3" class="px-6 py-3">
          <div class="flex items-center gap-4">
            <span class="text-xs text-danger">
              Delete this trust anchor? Certificates issued by it will no longer be trusted, and this cannot be undone.
            </span>
            <div class="flex items-center gap-2 ml-auto shrink-0">
              <.button phx-click="cancel_delete" size="xs">
                Cancel
              </.button>
              <.button
                phx-click="delete"
                phx-value-id={@trust_anchor.id}
                size="xs"
                style="danger"
                class="font-medium"
              >
                Delete
              </.button>
            </div>
          </div>
        </td>
      <% else %>
        <td class="px-6 py-3">
          <div class="text-sm font-medium text-heading truncate">{@trust_anchor.name}</div>
          <div class="font-mono text-[10px] text-subtle mt-0.5 truncate">
            {@trust_anchor.id}
          </div>
        </td>
        <td class="px-6 py-3 w-36">
          <span class="text-sm text-body">{cert_count_label(@trust_anchor.certificates)}</span>
        </td>
        <td class="px-6 py-3 w-36">
          <span class="text-sm text-body">
            {PortalWeb.Format.short_date(@trust_anchor.inserted_at)}
          </span>
        </td>
        <td class="px-6 py-3 w-10">
          <div class="flex justify-end">
            <.actions_dropdown
              open={@open_trust_anchor_actions_id == @trust_anchor.id}
              close_event="close_trust_anchor_actions"
              phx-click="toggle_trust_anchor_actions"
              phx-value-id={@trust_anchor.id}
            >
              <.link
                patch={~p"/#{@account}/settings/trust_anchors/#{@trust_anchor.id}/edit"}
                class="flex items-center gap-2.5 w-full px-3 py-2 text-xs text-left hover:bg-raised transition-colors text-body"
              >
                <.icon name="ri-pencil-line" class="w-3.5 h-3.5 shrink-0" /> Edit
              </.link>
              <div class="my-1 border-t border-border"></div>
              <button
                phx-click="request_delete"
                phx-value-id={@trust_anchor.id}
                class="flex items-center gap-2.5 w-full px-3 py-2 text-xs text-left hover:bg-raised transition-colors text-error"
              >
                <.icon name="ri-delete-bin-line" class="w-3.5 h-3.5 shrink-0" /> Delete
              </button>
            </.actions_dropdown>
          </div>
        </td>
      <% end %>
    </tr>
    """
  end

  attr :form, :any, required: true
  attr :input_mode, :atom, required: true
  attr :uploads, :any, required: true

  defp trust_anchor_form_fields(assigns) do
    certs_field = assigns.form[:certs]

    certs_errors =
      if Phoenix.Component.used_input?(certs_field) do
        Enum.map(certs_field.errors, &translate_error/1)
      else
        []
      end

    assigns =
      assigns
      |> assign(:certs_errors, certs_errors)
      |> assign(:certs_display_value, certs_display_value(assigns.form))

    ~H"""
    <div>
      <.input
        field={@form[:name]}
        label="Name"
        placeholder="E.g. 'Corporate Issuing CA'"
        phx-debounce="300"
        required
      />
    </div>

    <div>
      <h3 class="text-[10px] font-semibold uppercase tracking-widest text-subtle mb-2">
        Certificate Chain
      </h3>

      <div class="grid gap-3 grid-cols-2 mb-4">
        <div>
          <.input
            id="trust-anchor-input-mode--paste"
            type="radio_button_group"
            name="trust_anchor[input_mode]"
            value="paste"
            checked={@input_mode == :paste}
            required
          />
          <label
            for="trust-anchor-input-mode--paste"
            class={[
              "flex flex-col h-full p-3 border rounded cursor-pointer transition-all",
              "peer-checked:border-brand peer-checked:bg-raised",
              "border-border hover:border-border-emphasis"
            ]}
          >
            <span class="text-sm font-semibold text-heading mb-1 flex items-center gap-1.5">
              <.icon name="ri-clipboard-line" class="w-4 h-4 shrink-0" /> Paste
            </span>
            <span class="text-xs text-body my-auto">Paste PEM or base64 DER text.</span>
          </label>
        </div>

        <div>
          <.input
            id="trust-anchor-input-mode--upload"
            type="radio_button_group"
            name="trust_anchor[input_mode]"
            value="upload"
            checked={@input_mode == :upload}
            required
          />
          <label
            for="trust-anchor-input-mode--upload"
            class={[
              "flex flex-col h-full p-3 border rounded cursor-pointer transition-all",
              "peer-checked:border-brand peer-checked:bg-raised",
              "border-border hover:border-border-emphasis"
            ]}
          >
            <span class="text-sm font-semibold text-heading mb-1 flex items-center gap-1.5">
              <.icon name="ri-upload-2-line" class="w-4 h-4 shrink-0" /> Upload File
            </span>
            <span class="text-xs text-body my-auto">Upload one or more chain files.</span>
          </label>
        </div>
      </div>

      <div :if={@input_mode == :paste}>
        <.input
          type="textarea"
          field={@form[:certs]}
          multiple={true}
          value={@certs_display_value}
          label="Certificate chain (PEM or base64 DER)"
          placeholder="-----BEGIN CERTIFICATE-----"
          rows="10"
          class="font-mono text-xs"
          phx-debounce="300"
        />
      </div>

      <div :if={@input_mode == :upload} class="space-y-2">
        <.label>Chain file(s)</.label>
        <.live_file_input
          upload={@uploads.cert_file}
          class="block w-full text-xs text-subtle file:mr-3 file:cursor-pointer file:rounded file:border file:border-border-strong file:bg-surface file:px-3 file:py-1.5 file:text-xs file:font-medium file:text-body file:transition-colors hover:file:bg-raised hover:file:text-heading"
        />
        <p class="text-xs text-subtle">
          Accepts .pem, .crt, .cer, .der, or .txt, up to 1&nbsp;MB each. Select multiple files to upload
          a root and intermediate CA separately; a DER file holds a single certificate.
        </p>
        <div
          :for={entry <- @uploads.cert_file.entries}
          class="flex flex-col gap-0.5"
        >
          <div class="flex items-center gap-2 text-xs text-body">
            <.icon name="ri-file-line" class="w-3.5 h-3.5 shrink-0" />
            <span class="truncate">{entry.client_name}</span>
            <progress value={entry.progress} max="100" class="w-16">{entry.progress}%</progress>
            <button
              type="button"
              phx-click="cancel_upload"
              phx-value-ref={entry.ref}
              class="text-error"
            >
              <.icon name="ri-close-line" class="w-3.5 h-3.5" />
            </button>
          </div>
          <.error :for={err <- upload_errors(@uploads.cert_file, entry)} inline>
            {upload_error_to_string(err)}
          </.error>
        </div>
        <.error :for={msg <- @certs_errors}>{msg}</.error>
        <.error :for={err <- upload_errors(@uploads.cert_file)}>
          {upload_error_to_string(err)}
        </.error>
      </div>
    </div>
    """
  end

  def handle_event("close_panel", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/settings/trust_anchors")}
  end

  def handle_event(
        "handle_keydown",
        %{"key" => "Escape"},
        %{assigns: %{live_action: action}} = socket
      )
      when action in [:new, :edit] do
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/settings/trust_anchors")}
  end

  def handle_event("handle_keydown", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :cert_file, ref)}
  end

  def handle_event("validate_new", %{"trust_anchor" => attrs}, socket) do
    changeset =
      attrs
      |> build_creation_changeset()
      |> Map.put(:action, :insert)

    socket =
      socket
      |> assign(input_mode: input_mode_from_attrs(attrs, socket.assigns.input_mode))
      |> assign(form: to_form(changeset, as: "trust_anchor"))

    {:noreply, socket}
  end

  def handle_event("create_trust_anchor", %{"trust_anchor" => attrs}, socket) do
    attrs = resolve_certs_attrs(socket, attrs)
    changeset = build_creation_changeset(attrs)

    case Safe.scoped(changeset, socket.assigns.subject) |> Safe.insert() do
      {:ok, _trust_anchor} ->
        socket =
          socket
          |> assign(trust_anchors: Database.list_trust_anchors(socket.assigns.subject))
          |> put_flash(:success, "Trust anchor created successfully")
          |> push_patch(to: ~p"/#{socket.assigns.account}/settings/trust_anchors")

        {:noreply, socket}

      {:error, changeset} ->
        changeset = surface_certificate_errors(changeset)
        {:noreply, assign(socket, form: to_form(changeset, as: "trust_anchor"))}
    end
  end

  def handle_event("validate_edit", %{"trust_anchor" => attrs}, socket) do
    changeset =
      socket.assigns.selected_trust_anchor
      |> build_edit_changeset(attrs)
      |> Map.put(:action, :update)

    socket =
      socket
      |> assign(input_mode: input_mode_from_attrs(attrs, socket.assigns.input_mode))
      |> assign(form: to_form(changeset, as: "trust_anchor"))

    {:noreply, socket}
  end

  def handle_event("update_trust_anchor", %{"trust_anchor" => attrs}, socket) do
    attrs = resolve_certs_attrs(socket, attrs)
    changeset = build_edit_changeset(socket.assigns.selected_trust_anchor, attrs)

    case Safe.scoped(changeset, socket.assigns.subject) |> Safe.update() do
      {:ok, _trust_anchor} ->
        socket =
          socket
          |> assign(trust_anchors: Database.list_trust_anchors(socket.assigns.subject))
          |> put_flash(:success, "Trust anchor updated successfully")
          |> push_patch(to: ~p"/#{socket.assigns.account}/settings/trust_anchors")

        {:noreply, socket}

      {:error, changeset} ->
        changeset = surface_certificate_errors(changeset)
        {:noreply, assign(socket, form: to_form(changeset, as: "trust_anchor"))}
    end
  end

  def handle_event("request_delete", %{"id" => id}, socket) do
    {:noreply, assign(socket, pending_delete_id: id, open_trust_anchor_actions_id: nil)}
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, pending_delete_id: nil)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.trust_anchors, &(&1.id == id)) do
      nil ->
        {:noreply, assign(socket, pending_delete_id: nil, open_trust_anchor_actions_id: nil)}

      trust_anchor ->
        case Safe.scoped(trust_anchor, socket.assigns.subject) |> Safe.delete() do
          {:ok, _trust_anchor} ->
            socket =
              socket
              |> assign(
                trust_anchors: Database.list_trust_anchors(socket.assigns.subject),
                pending_delete_id: nil,
                open_trust_anchor_actions_id: nil
              )
              |> push_patch(to: ~p"/#{socket.assigns.account}/settings/trust_anchors")

            {:noreply, socket}

          {:error, _reason} ->
            socket =
              socket
              |> put_flash(:error, "Could not delete trust anchor. Please try again.")
              |> assign(
                trust_anchors: Database.list_trust_anchors(socket.assigns.subject),
                pending_delete_id: nil,
                open_trust_anchor_actions_id: nil
              )

            {:noreply, socket}
        end
    end
  rescue
    # Another session deleted this trust anchor after it was loaded into
    # `socket.assigns.trust_anchors`, so `Repo.delete` affected zero rows.
    # The end state already matches the user's intent, so just refresh.
    Ecto.StaleEntryError ->
      socket =
        assign(socket,
          trust_anchors: Database.list_trust_anchors(socket.assigns.subject),
          pending_delete_id: nil,
          open_trust_anchor_actions_id: nil
        )

      {:noreply, socket}
  end

  def handle_event("toggle_trust_anchor_actions", %{"id" => id}, socket) do
    current = socket.assigns.open_trust_anchor_actions_id
    next = if current == id, do: nil, else: id

    {:noreply, assign(socket, open_trust_anchor_actions_id: next)}
  end

  def handle_event("close_trust_anchor_actions", _params, socket) do
    {:noreply, assign(socket, open_trust_anchor_actions_id: nil)}
  end

  defp build_creation_changeset(attrs) do
    %TrustAnchor{}
    |> cast(attrs, [:name, :certs])
    |> TrustAnchor.changeset()
  end

  defp build_edit_changeset(trust_anchor, attrs) do
    trust_anchor
    |> cast(attrs, [:name, :certs])
    |> seed_certs_pem_if_untouched(attrs, trust_anchor)
    |> TrustAnchor.changeset()
  end

  defp seed_certs_pem_if_untouched(changeset, attrs, trust_anchor) do
    if Map.has_key?(attrs, "certs") or Map.has_key?(attrs, :certs) do
      changeset
    else
      put_change(changeset, :certs, [armor_certs_as_pem(trust_anchor.certificates)])
    end
  end

  defp armor_certs_as_pem(certificates) do
    certificates
    |> Enum.map(& &1.der)
    |> armor_der_as_pem()
  end

  defp armor_der_as_pem(ders) do
    ders
    |> Enum.map(&{:Certificate, &1, :not_encrypted})
    |> :public_key.pem_encode()
  end

  # `TrustAnchor.changeset/1` normalizes `:certs` in place, replacing whatever
  # PEM/base64/DER text the admin typed with the normalized raw DER bytes
  # (see `normalize_certs/2` and the schema test asserting on that). Showing
  # those bytes back in the textarea would corrupt the field, so once
  # normalization has produced `:certificates` changesets, re-armor their DER
  # as PEM for display instead of reading `@form[:certs].value` directly.
  defp certs_display_value(form) do
    case Ecto.Changeset.get_change(form.source, :certificates) do
      [_ | _] = certificate_changesets ->
        certificate_changesets
        # `put_assoc/3` can't match freshly-built cert changesets against the
        # existing (unsaved-input) `:id`-less ones they replace, so editing
        # always emits a `:replace` entry for the old row alongside the
        # `:insert` for the new one. Only the surviving side belongs on screen.
        |> Enum.reject(&(&1.action == :replace))
        |> Enum.map(&Ecto.Changeset.get_field(&1, :der))
        |> armor_der_as_pem()

      _ ->
        List.first(form[:certs].value || [], "")
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp resolve_certs_attrs(%{assigns: %{input_mode: :upload}} = socket, attrs) do
    # `path` is LiveView's own temp upload path, not user-controlled.
    certs =
      consume_uploaded_entries(socket, :cert_file, fn %{path: path}, _entry ->
        {:ok, File.read!(path)}
      end)

    Map.put(attrs, "certs", certs)
  end

  defp resolve_certs_attrs(_socket, attrs), do: attrs

  defp input_mode_from_attrs(%{"input_mode" => "upload"}, _current), do: :upload
  defp input_mode_from_attrs(%{"input_mode" => "paste"}, _current), do: :paste
  defp input_mode_from_attrs(_attrs, current), do: current

  defp cert_count_label(certs) do
    count = length(certs)
    "#{count} certificate#{if count == 1, do: "", else: "s"}"
  end

  defp surface_certificate_errors(changeset) do
    cert_changesets = Map.get(changeset.changes, :certificates, [])

    if Enum.any?(cert_changesets, &(not &1.valid?)) do
      add_error(
        changeset,
        :certs,
        "one of these certificates is already used by another trust anchor in this account"
      )
    else
      changeset
    end
  end

  defp upload_error_to_string(:too_large),
    do: "File is too large (max #{div(@max_upload_size, 1_000_000)} MB)."

  defp upload_error_to_string(:not_accepted),
    do: "Unsupported file type. Use .pem, .crt, .cer, .der, or .txt."

  defp upload_error_to_string(:too_many_files),
    do: "Too many files selected (max #{@max_upload_entries})."

  defp upload_error_to_string(_reason), do: "Could not upload file."
end

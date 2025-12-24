defmodule PortalWeb.Clients.Show do
  use PortalWeb, :live_view
  import PortalWeb.Policies.Components
  import PortalWeb.Clients.Components
  alias Portal.{Presence.Clients, ComponentVersions}
  alias __MODULE__.DB
  import Ecto.Changeset
  import Portal.Changeset

  def mount(%{"id" => id}, _session, socket) do
    client = DB.get_client!(id, socket.assigns.subject)
    client = Clients.preload_clients_presence([client]) |> List.first()

    if connected?(socket) do
      :ok = Clients.Actor.subscribe(client.actor_id)
    end

    socket =
      assign(
        socket,
        client: client,
        page_title: "Client #{client.name}"
      )
      |> assign_live_table("policy_authorizations",
        query_module: DB.PolicyAuthorizationQuery,
        sortable_fields: [],
        hide_filters: [:expiration],
        callback: &handle_policy_authorizations_update!/2
      )

    {:ok, socket}
  end

  def handle_params(params, uri, socket) do
    socket = handle_live_tables_params(socket, params, uri)
    {:noreply, socket}
  end

  def handle_policy_authorizations_update!(socket, list_opts) do
    list_opts =
      Keyword.put(list_opts, :preload,
        client: [:actor],
        gateway: [:site],
        policy: [:group, :resource]
      )

    with {:ok, policy_authorizations, metadata} <-
           DB.list_policy_authorizations_for(
             socket.assigns.client,
             socket.assigns.subject,
             list_opts
           ) do
      {:ok,
       assign(socket,
         policy_authorizations: policy_authorizations,
         policy_authorizations_metadata: metadata
       )}
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/clients"}>Clients</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/clients/#{@client.id}"}>
        {@client.name}
      </.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title>
        Client Details
      </:title>

      <:action>
        <.edit_button navigate={~p"/#{@account}/clients/#{@client}/edit"}>
          Edit Client
        </.edit_button>
      </:action>

      <:content>
        <.vertical_table id="client">
          <.vertical_table_row>
            <:label>
              <.popover>
                <:target>
                  ID <.icon name="hero-question-mark-circle" class="w-3 h-3 mb-1 text-neutral-400" />
                </:target>
                <:content>
                  Database ID assigned to this Client that can be used to manage this Client via the REST PortalAPI.
                </:content>
              </.popover>
            </:label>
            <:value>{@client.id}</:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>Name</:label>
            <:value>{@client.name}</:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>Status</:label>
            <:value><.connection_status class="ml-1/2" schema={@client} /></:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>Owner</:label>
            <:value>
              <.link
                navigate={~p"/#{@account}/actors/#{@client.actor.id}?#{[return_to: @return_to]}"}
                class={[link_style()]}
              >
                {@client.actor.name}
              </.link>
            </:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>Version</:label>
            <:value>
              <.version
                current={@client.last_seen_version}
                latest={ComponentVersions.client_version(@client)}
              />
            </:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>User agent</:label>
            <:value>
              {@client.last_seen_user_agent}
            </:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>Tunnel Interface IPv4 Address</:label>
            <:value>{@client.ipv4_address.address}</:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>Tunnel Interface IPv6 Address</:label>
            <:value>{@client.ipv6_address.address}</:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>Created</:label>
            <:value>
              <.relative_datetime datetime={@client.inserted_at} />
            </:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>Last started</:label>
            <:value>
              <.relative_datetime datetime={@client.last_seen_at} />
            </:value>
          </.vertical_table_row>
        </.vertical_table>
      </:content>
    </.section>

    <.section>
      <:title>
        Device Attributes
      </:title>

      <:help>
        Information about the device that the Client is running on.
      </:help>

      <:action :if={not is_nil(@client.verified_at)}>
        <.button_with_confirmation
          id="remove_client_verification"
          style="danger"
          icon="hero-shield-exclamation"
          on_confirm="remove_client_verification"
        >
          <:dialog_title>Confirm removal of Client verification</:dialog_title>
          <:dialog_content>
            Are you sure you want to remove verification of this Client?
            It will no longer be able to access Resources using Policies that require verification.
          </:dialog_content>
          <:dialog_confirm_button>
            Remove
          </:dialog_confirm_button>
          <:dialog_cancel_button>
            Cancel
          </:dialog_cancel_button>
          Remove verification
        </.button_with_confirmation>
      </:action>
      <:action :if={is_nil(@client.verified_at)}>
        <.button_with_confirmation
          id="verify_client"
          style="warning"
          confirm_style="primary"
          icon="hero-shield-check"
          on_confirm="verify_client"
        >
          <:dialog_title>Confirm verification of Client</:dialog_title>
          <:dialog_content>
            Are you sure you want to verify this Client?
          </:dialog_content>
          <:dialog_confirm_button>
            Verify
          </:dialog_confirm_button>
          <:dialog_cancel_button>
            Cancel
          </:dialog_cancel_button>
          Verify
        </.button_with_confirmation>
      </:action>

      <:content>
        <.vertical_table id="posture">
          <.vertical_table_row>
            <:label>
              <.popover>
                <:target>
                  File ID
                  <.icon name="hero-question-mark-circle" class="w-3 h-3 mb-1 text-neutral-400" />
                </:target>
                <:content>
                  Firezone-specific UUID generated and persisted to the device upon app installation.
                </:content>
              </.popover>
            </:label>
            <:value>{@client.external_id}</:value>
          </.vertical_table_row>
          <.vertical_table_row :for={{{title, helptext}, value} <- hardware_ids(@client)}>
            <:label>
              <.popover :if={not is_nil(helptext)}>
                <:target>
                  {title}
                  <.icon name="hero-question-mark-circle" class="w-3 h-3 mb-1 text-neutral-400" />
                </:target>
                <:content>
                  {helptext}
                </:content>
              </.popover>
              <span :if={is_nil(helptext)}>{title}</span>
            </:label>
            <:value>{value}</:value>
          </.vertical_table_row>

          <.vertical_table_row>
            <:label>Last seen remote IP</:label>
            <:value>
              <.last_seen schema={@client} />
            </:value>
          </.vertical_table_row>

          <.vertical_table_row>
            <:label>
              <.popover>
                <:target>
                  Verification
                  <.icon name="hero-question-mark-circle" class="w-3 h-3 mb-1 text-neutral-400" />
                </:target>
                <:content>
                  Policies can be configured to require verification in order to access a Resource.
                </:content>
              </.popover>
            </:label>
            <:value>
              <.verified schema={@client} />
            </:value>
          </.vertical_table_row>

          <.vertical_table_row>
            <:label>Operating System</:label>
            <:value>
              <.client_os client={@client} />
            </:value>
          </.vertical_table_row>
        </.vertical_table>
      </:content>
    </.section>

    <.section>
      <:title>Recent Connections</:title>
      <:help>
        Recent connections opened by this Client to access a Resource.
      </:help>
      <:content>
        <.live_table
          id="policy_authorizations"
          rows={@policy_authorizations}
          row_id={&"policy_authorizations-#{&1.id}"}
          filters={@filters_by_table_id["policy_authorizations"]}
          filter={@filter_form_by_table_id["policy_authorizations"]}
          ordered_by={@order_by_table_id["policy_authorizations"]}
          metadata={@policy_authorizations_metadata}
        >
          <:col :let={policy_authorization} label="authorized">
            <.relative_datetime datetime={policy_authorization.inserted_at} />
          </:col>
          <:col :let={policy_authorization} label="remote ip" class="w-3/12">
            {policy_authorization.client_remote_ip}
          </:col>
          <:col :let={policy_authorization} label="policy">
            <.link
              navigate={~p"/#{@account}/policies/#{policy_authorization.policy_id}"}
              class={[link_style()]}
            >
              <.policy_name policy={policy_authorization.policy} />
            </.link>
          </:col>
          <:col :let={policy_authorization} label="gateway" class="w-3/12">
            <.link
              navigate={~p"/#{@account}/gateways/#{policy_authorization.gateway_id}"}
              class={[link_style()]}
            >
              {policy_authorization.gateway.site.name}-{policy_authorization.gateway.name}
            </.link>
            <br />
            <code class="text-xs">{policy_authorization.gateway_remote_ip}</code>
          </:col>
          <:empty>
            <div class="text-center text-neutral-500 p-4">No activity to display.</div>
          </:empty>
        </.live_table>
      </:content>
    </.section>

    <.danger_zone>
      <:action>
        <.button_with_confirmation
          id="delete_client"
          style="danger"
          icon="hero-trash-solid"
          on_confirm="delete"
        >
          <:dialog_title>Confirm deletion of client</:dialog_title>
          <:dialog_content>
            <p>
              Deleting the client doesn't remove it from the device; it will be re-created with the same
              hardware attributes upon the next sign-in, but the verification status won't carry over.
            </p>

            <p class="mt-2">
              To prevent the client owner from logging in again,
              <.link
                navigate={~p"/#{@account}/actors/#{@client.actor_id}?#{[return_to: @return_to]}"}
                class={link_style()}
              >
                disable the owning actor
              </.link>
              instead.
            </p>
          </:dialog_content>
          <:dialog_confirm_button>
            Delete Client
          </:dialog_confirm_button>
          <:dialog_cancel_button>
            Cancel
          </:dialog_cancel_button>
          Delete Client
        </.button_with_confirmation>
      </:action>
    </.danger_zone>
    """
  end

  defp hardware_ids(client) do
    [
      {:device_serial, client.device_serial},
      {:device_uuid, client.device_uuid},
      {:identifier_for_vendor, client.identifier_for_vendor},
      {:firebase_installation_id, client.firebase_installation_id}
    ]
    |> Enum.flat_map(fn {key, value} ->
      if is_nil(value) do
        []
      else
        [{hardware_id_title(client, key), value}]
      end
    end)
  end

  defp hardware_id_title(%{last_seen_user_agent: "Mac OS/" <> _}, :device_serial),
    do: {"Device Serial", nil}

  defp hardware_id_title(%{last_seen_user_agent: "Mac OS/" <> _}, :device_uuid),
    do: {"Device UUID", nil}

  defp hardware_id_title(%{last_seen_user_agent: "iOS/" <> _}, :identifier_for_vendor),
    do: {"App installation ID", "This value is reset if the Firezone application is reinstalled."}

  defp hardware_id_title(%{last_seen_user_agent: "Android/" <> _}, :firebase_installation_id),
    do: {"App installation ID", "This value is reset if the Firezone application is reinstalled."}

  defp hardware_id_title(_client, :device_serial),
    do: {"Device Serial", nil}

  defp hardware_id_title(_client, :device_uuid),
    do: {"Device UUID", nil}

  defp hardware_id_title(_client, :identifier_for_vendor),
    do: {"App installation ID", nil}

  defp hardware_id_title(_client, :firebase_installation_id),
    do: {"App installation ID", nil}

  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "presences:actor_clients:" <> _actor_id,
          payload: payload
        },
        socket
      ) do
    client = socket.assigns.client

    socket =
      cond do
        Map.has_key?(payload.joins, client.id) ->
          client = DB.get_client!(client.id, socket.assigns.subject)
          assign(socket, client: %{client | online?: true})

        Map.has_key?(payload.leaves, client.id) ->
          assign(socket, client: %{client | online?: false})

        true ->
          socket
      end

    {:noreply, socket}
  end

  def handle_event(event, params, socket) when event in ["paginate", "order_by", "filter"],
    do: handle_live_table_event(event, params, socket)

  def handle_event("verify_client", _params, socket) do
    changeset =
      socket.assigns.client
      |> change()
      |> put_default_value(:verified_at, DateTime.utc_now())

    {:ok, client} = DB.verify_client(changeset, socket.assigns.subject)

    client = %{
      client
      | online?: socket.assigns.client.online?,
        actor: socket.assigns.client.actor
    }

    {:noreply, assign(socket, :client, client)}
  end

  def handle_event("remove_client_verification", _params, socket) do
    import Ecto.Changeset

    changeset =
      socket.assigns.client
      |> change()
      |> put_change(:verified_at, nil)

    {:ok, client} = DB.remove_client_verification(changeset, socket.assigns.subject)

    client = %{
      client
      | online?: socket.assigns.client.online?,
        actor: socket.assigns.client.actor
    }

    {:noreply, assign(socket, :client, client)}
  end

  def handle_event("delete", _params, socket) do
    {:ok, _deleted_client} = DB.delete_client(socket.assigns.client, socket.assigns.subject)

    socket =
      socket
      |> put_flash(:success, "Client was deleted.")
      |> push_navigate(to: ~p"/#{socket.assigns.account}/clients")

    {:noreply, socket}
  end

  defmodule DB do
    import Ecto.Query
    alias Portal.{Presence.Clients, Safe}
    alias Portal.Client

    def get_client!(id, subject) do
      from(c in Client, as: :clients)
      |> where([clients: c], c.id == ^id)
      |> preload([:actor, :ipv4_address, :ipv6_address])
      |> Safe.scoped(subject)
      |> Safe.one!()
    end

    def verify_client(changeset, subject) do
      # Only account_admin_user can verify clients
      if subject.actor.type == :account_admin_user do
        case Safe.scoped(changeset, subject) |> Safe.update() do
          {:ok, updated_client} ->
            {:ok, Clients.preload_clients_presence([updated_client]) |> List.first()}

          {:error, reason} ->
            {:error, reason}
        end
      else
        {:error, :unauthorized}
      end
    end

    def remove_client_verification(changeset, subject) do
      # Only account_admin_user can remove client verification
      if subject.actor.type == :account_admin_user do
        case Safe.scoped(changeset, subject) |> Safe.update() do
          {:ok, updated_client} ->
            {:ok, Clients.preload_clients_presence([updated_client]) |> List.first()}

          {:error, reason} ->
            {:error, reason}
        end
      else
        {:error, :unauthorized}
      end
    end

    def delete_client(client, subject) do
      case Safe.scoped(client, subject) |> Safe.delete() do
        {:ok, deleted_client} ->
          {:ok, Clients.preload_clients_presence([deleted_client]) |> List.first()}

        {:error, reason} ->
          {:error, reason}
      end
    end

    # Inline functions from Portal.PolicyAuthorizations
    def list_policy_authorizations_for(assoc, subject, opts \\ [])

    def list_policy_authorizations_for(
          %Portal.Policy{} = policy,
          %Portal.Auth.Subject{} = subject,
          opts
        ) do
      DB.PolicyAuthorizationQuery.all()
      |> DB.PolicyAuthorizationQuery.by_policy_id(policy.id)
      |> list_policy_authorizations(subject, opts)
    end

    def list_policy_authorizations_for(
          %Portal.Resource{} = resource,
          %Portal.Auth.Subject{} = subject,
          opts
        ) do
      DB.PolicyAuthorizationQuery.all()
      |> DB.PolicyAuthorizationQuery.by_resource_id(resource.id)
      |> list_policy_authorizations(subject, opts)
    end

    def list_policy_authorizations_for(
          %Portal.Client{} = client,
          %Portal.Auth.Subject{} = subject,
          opts
        ) do
      DB.PolicyAuthorizationQuery.all()
      |> DB.PolicyAuthorizationQuery.by_client_id(client.id)
      |> list_policy_authorizations(subject, opts)
    end

    def list_policy_authorizations_for(
          %Portal.Actor{} = actor,
          %Portal.Auth.Subject{} = subject,
          opts
        ) do
      DB.PolicyAuthorizationQuery.all()
      |> DB.PolicyAuthorizationQuery.by_actor_id(actor.id)
      |> list_policy_authorizations(subject, opts)
    end

    def list_policy_authorizations_for(
          %Portal.Gateway{} = gateway,
          %Portal.Auth.Subject{} = subject,
          opts
        ) do
      DB.PolicyAuthorizationQuery.all()
      |> DB.PolicyAuthorizationQuery.by_gateway_id(gateway.id)
      |> list_policy_authorizations(subject, opts)
    end

    defp list_policy_authorizations(queryable, subject, opts) do
      queryable
      |> Portal.Safe.scoped(subject)
      |> Portal.Safe.list(DB.PolicyAuthorizationQuery, opts)
    end
  end

  defmodule DB.PolicyAuthorizationQuery do
    import Ecto.Query

    def all do
      from(policy_authorizations in Portal.PolicyAuthorization, as: :policy_authorizations)
    end

    def expired(queryable) do
      now = DateTime.utc_now()

      where(
        queryable,
        [policy_authorizations: policy_authorizations],
        policy_authorizations.expires_at <= ^now
      )
    end

    def not_expired(queryable) do
      now = DateTime.utc_now()

      where(
        queryable,
        [policy_authorizations: policy_authorizations],
        policy_authorizations.expires_at > ^now
      )
    end

    def by_id(queryable, id) do
      where(
        queryable,
        [policy_authorizations: policy_authorizations],
        policy_authorizations.id == ^id
      )
    end

    def by_account_id(queryable, account_id) do
      where(
        queryable,
        [policy_authorizations: policy_authorizations],
        policy_authorizations.account_id == ^account_id
      )
    end

    def by_token_id(queryable, token_id) do
      where(
        queryable,
        [policy_authorizations: policy_authorizations],
        policy_authorizations.token_id == ^token_id
      )
    end

    def by_policy_id(queryable, policy_id) do
      where(
        queryable,
        [policy_authorizations: policy_authorizations],
        policy_authorizations.policy_id == ^policy_id
      )
    end

    def for_cache(queryable) do
      queryable
      |> select(
        [policy_authorizations: policy_authorizations],
        {{policy_authorizations.client_id, policy_authorizations.resource_id},
         {policy_authorizations.id, policy_authorizations.expires_at}}
      )
    end

    def by_policy_group_id(queryable, group_id) do
      queryable
      |> with_joined_policy()
      |> where([policy: policy], policy.group_id == ^group_id)
    end

    def by_membership_id(queryable, membership_id) do
      where(
        queryable,
        [policy_authorizations: policy_authorizations],
        policy_authorizations.membership_id == ^membership_id
      )
    end

    def by_site_id(queryable, site_id) do
      queryable
      |> with_joined_site()
      |> where([site: site], site.id == ^site_id)
    end

    def by_resource_id(queryable, resource_id) do
      where(
        queryable,
        [policy_authorizations: policy_authorizations],
        policy_authorizations.resource_id == ^resource_id
      )
    end

    def by_not_in_resource_ids(queryable, resource_ids) do
      where(
        queryable,
        [policy_authorizations: policy_authorizations],
        policy_authorizations.resource_id not in ^resource_ids
      )
    end

    def by_client_id(queryable, client_id) do
      where(
        queryable,
        [policy_authorizations: policy_authorizations],
        policy_authorizations.client_id == ^client_id
      )
    end

    def by_actor_id(queryable, actor_id) do
      queryable
      |> with_joined_client()
      |> where([client: client], client.actor_id == ^actor_id)
    end

    def by_gateway_id(queryable, gateway_id) do
      where(
        queryable,
        [policy_authorizations: policy_authorizations],
        policy_authorizations.gateway_id == ^gateway_id
      )
    end

    def with_joined_policy(queryable) do
      with_policy_authorization_named_binding(queryable, :policy, fn queryable, binding ->
        join(
          queryable,
          :inner,
          [policy_authorizations: policy_authorizations],
          policy in assoc(policy_authorizations, ^binding),
          as: ^binding
        )
      end)
    end

    def with_joined_client(queryable) do
      with_policy_authorization_named_binding(queryable, :client, fn queryable, binding ->
        join(
          queryable,
          :inner,
          [policy_authorizations: policy_authorizations],
          client in assoc(policy_authorizations, ^binding),
          as: ^binding
        )
      end)
    end

    def with_joined_site(queryable) do
      queryable
      |> with_joined_gateway()
      |> with_policy_authorization_named_binding(:site, fn queryable, binding ->
        join(queryable, :inner, [gateway: gateway], site in assoc(gateway, :site), as: ^binding)
      end)
    end

    def with_joined_gateway(queryable) do
      with_policy_authorization_named_binding(queryable, :gateway, fn queryable, binding ->
        join(
          queryable,
          :inner,
          [policy_authorizations: policy_authorizations],
          gateway in assoc(policy_authorizations, ^binding),
          as: ^binding
        )
      end)
    end

    def with_policy_authorization_named_binding(queryable, binding, fun) do
      if has_named_binding?(queryable, binding) do
        queryable
      else
        fun.(queryable, binding)
      end
    end

    # Pagination
    def cursor_fields,
      do: [
        {:policy_authorizations, :desc, :inserted_at},
        {:policy_authorizations, :asc, :id}
      ]
  end
end

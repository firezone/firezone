defmodule PortalWeb.Policies.Show do
  use Web, :live_view
  import PortalWeb.Policies.Components
  alias Portal.{Policy, Auth}
  alias __MODULE__.DB
  import Ecto.Changeset
  import Portal.Changeset

  def mount(%{"id" => id}, _session, socket) do
    policy = get_policy!(id, socket.assigns.subject)

    providers =
      DB.all_active_providers_for_account(socket.assigns.account, socket.assigns.subject)

    socket =
      assign(socket,
        page_title: "Policy #{policy.id}",
        policy: policy,
        providers: providers
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
        gateway: [:site]
      )

    with {:ok, policy_authorizations, metadata} <-
           DB.list_policy_authorizations_for(
             socket.assigns.policy,
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
      <.breadcrumb path={~p"/#{@account}/policies"}>Policies</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/policies/#{@policy}"}>
        <.policy_name policy={@policy} />
      </.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title>
        <.policy_name policy={@policy} />
        <span :if={not is_nil(@policy.disabled_at)} class="text-primary-600">(disabled)</span>
      </:title>
      <:action>
        <.edit_button navigate={~p"/#{@account}/policies/#{@policy}/edit"}>
          Edit Policy
        </.edit_button>
      </:action>
      <:action>
        <.button_with_confirmation
          :if={is_nil(@policy.disabled_at)}
          id="disable"
          style="warning"
          icon="hero-lock-closed"
          on_confirm="disable"
        >
          <:dialog_title>Confirm disabling the Policy</:dialog_title>
          <:dialog_content>
            Are you sure you want to disable this policy?
            This will <strong>immediately</strong>
            revoke all access granted by it. Keep in mind, other policies may still grant access to the same resource.
          </:dialog_content>
          <:dialog_confirm_button>
            Disable
          </:dialog_confirm_button>
          <:dialog_cancel_button>
            Cancel
          </:dialog_cancel_button>
          Disable
        </.button_with_confirmation>
        <.button_with_confirmation
          :if={not is_nil(@policy.disabled_at)}
          id="enable"
          style="warning"
          confirm_style="primary"
          icon="hero-lock-open"
          on_confirm="enable"
        >
          <:dialog_title>Confirm enabling the Policy</:dialog_title>
          <:dialog_content>
            Are you sure you want to enable this policy?
            This will <strong>immediately</strong>
            grant access to the specified resource to all members of the given group.
          </:dialog_content>
          <:dialog_confirm_button>
            Enable
          </:dialog_confirm_button>
          <:dialog_cancel_button>
            Cancel
          </:dialog_cancel_button>
          Enable
        </.button_with_confirmation>
      </:action>
      <:content>
        <.vertical_table id="policy">
          <.vertical_table_row>
            <:label>
              ID
            </:label>
            <:value>
              {@policy.id}
            </:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>
              Group
            </:label>
            <:value>
              <.group_badge account={@account} group={@policy.group} return_to={@return_to} />
            </:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>
              Resource
            </:label>
            <:value>
              <.link navigate={~p"/#{@account}/resources/#{@policy.resource_id}"} class={link_style()}>
                {@policy.resource.name}
              </.link>
            </:value>
          </.vertical_table_row>
          <.vertical_table_row :if={@policy.conditions != []}>
            <:label>
              Conditions
            </:label>
            <:value>
              <.conditions account={@account} providers={@providers} conditions={@policy.conditions} />
            </:value>
          </.vertical_table_row>
          <.vertical_table_row :if={@policy.description}>
            <:label>
              Description
            </:label>
            <:value>
              <span class="whitespace-pre" phx-no-format><%= @policy.description %></span>
            </:value>
          </.vertical_table_row>
        </.vertical_table>
      </:content>
    </.section>

    <.section>
      <:title>Recent Connections</:title>
      <:help>
        Recent connections opened by Actors to access the Resources governed by this Policy.
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
          <:col :let={policy_authorization} label="client, actor" class="w-3/12">
            <.link
              navigate={~p"/#{@account}/clients/#{policy_authorization.client_id}"}
              class={link_style()}
            >
              {policy_authorization.client.name}
            </.link>
            owned by
            <.link
              navigate={
                ~p"/#{@account}/actors/#{policy_authorization.client.actor_id}?#{[return_to: @return_to]}"
              }
              class={link_style()}
            >
              {policy_authorization.client.actor.name}
            </.link>
            {policy_authorization.client_remote_ip}
          </:col>
          <:col :let={policy_authorization} label="gateway" class="w-3/12">
            <.link
              navigate={~p"/#{@account}/gateways/#{policy_authorization.gateway_id}"}
              class={link_style()}
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
          id="delete_policy"
          style="danger"
          icon="hero-trash-solid"
          on_confirm="delete"
          on_confirm_id={@policy.id}
        >
          <:dialog_title>Confirm deletion of Policy</:dialog_title>
          <:dialog_content>
            Are you sure you want to delete this Policy? All sessions authorized by it will be expired.
          </:dialog_content>
          <:dialog_confirm_button>
            Delete Policy
          </:dialog_confirm_button>
          <:dialog_cancel_button>
            Cancel
          </:dialog_cancel_button>
          Delete Policy
        </.button_with_confirmation>
      </:action>
    </.danger_zone>
    """
  end

  def handle_info(_, socket) do
    {:noreply, socket}
  end

  def handle_event(event, params, socket) when event in ["paginate", "order_by", "filter"],
    do: handle_live_table_event(event, params, socket)

  def handle_event("disable", _params, socket) do
    {:ok, policy} = disable_policy(socket.assigns.policy, socket.assigns.subject)

    policy = %{
      policy
      | group: socket.assigns.policy.group,
        resource: socket.assigns.policy.resource
    }

    {:noreply,
     socket
     |> put_flash(:success, "Policy disabled successfully.")
     |> assign(policy: policy)}
  end

  def handle_event("enable", _params, socket) do
    {:ok, policy} = enable_policy(socket.assigns.policy, socket.assigns.subject)

    policy = %{
      policy
      | group: socket.assigns.policy.group,
        resource: socket.assigns.policy.resource
    }

    {:noreply,
     socket
     |> put_flash(:success, "Policy enabled successfully.")
     |> assign(policy: policy)}
  end

  def handle_event("delete", _params, socket) do
    {:ok, _deleted_policy} = delete_policy(socket.assigns.policy, socket.assigns.subject)

    {:noreply,
     socket
     |> put_flash(:success, "Policy deleted successfully.")
     |> push_navigate(to: ~p"/#{socket.assigns.account}/policies")}
  end

  # Inline functions from Portal.Policies

  defp get_policy!(id, %Auth.Subject{} = subject) do
    DB.get_policy!(id, subject)
  end

  defp disable_policy(%Policy{} = policy, %Auth.Subject{} = subject) do
    changeset =
      policy
      |> change()
      |> put_default_value(:disabled_at, DateTime.utc_now())

    DB.update_policy(changeset, subject)
  end

  defp enable_policy(%Policy{} = policy, %Auth.Subject{} = subject) do
    changeset =
      policy
      |> change()
      |> put_change(:disabled_at, nil)

    DB.update_policy(changeset, subject)
  end

  defp delete_policy(%Policy{} = policy, %Auth.Subject{} = subject) do
    DB.delete_policy(policy, subject)
  end

  defmodule DB do
    import Ecto.Query
    alias Portal.{Policy, Safe, Userpass, EmailOTP, OIDC, Google, Entra, Okta}
    alias Portal.Auth

    def get_policy!(id, %Auth.Subject{} = subject) do
      from(p in Policy, as: :policies)
      |> where([policies: p], p.id == ^id)
      |> preload(group: [], resource: [])
      |> Safe.scoped(subject)
      |> Safe.one!()
    end

    def update_policy(changeset, %Auth.Subject{} = subject) do
      Safe.scoped(changeset, subject)
      |> Safe.update()
    end

    def delete_policy(%Policy{} = policy, %Auth.Subject{} = subject) do
      Safe.scoped(policy, subject)
      |> Safe.delete()
    end

    def all_active_providers_for_account(_account, subject) do
      [
        Userpass.AuthProvider,
        EmailOTP.AuthProvider,
        OIDC.AuthProvider,
        Google.AuthProvider,
        Entra.AuthProvider,
        Okta.AuthProvider
      ]
      |> Enum.flat_map(fn schema ->
        from(p in schema, where: not p.is_disabled)
        |> Safe.scoped(subject)
        |> Safe.all()
      end)
    end

    def list_policy_authorizations_for(
          %Portal.Policy{} = policy,
          %Portal.Auth.Subject{} = subject,
          opts
        ) do
      DB.PolicyAuthorizationQuery.all()
      |> DB.PolicyAuthorizationQuery.by_policy_id(policy.id)
      |> Safe.scoped(subject)
      |> Safe.list(DB.PolicyAuthorizationQuery, opts)
    end
  end

  defmodule DB.PolicyAuthorizationQuery do
    import Ecto.Query

    def all do
      from(policy_authorizations in Portal.PolicyAuthorization, as: :policy_authorizations)
    end

    def by_policy_id(queryable, policy_id) do
      where(
        queryable,
        [policy_authorizations: policy_authorizations],
        policy_authorizations.policy_id == ^policy_id
      )
    end

    def cursor_fields,
      do: [
        {:policy_authorizations, :desc, :inserted_at},
        {:policy_authorizations, :asc, :id}
      ]
  end
end

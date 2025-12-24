defmodule PortalWeb.Policies.New do
  use Web, :live_view
  import PortalWeb.Policies.Components
  alias Portal.{Policy, Auth}
  alias __MODULE__.DB

  def mount(params, _session, socket) do
    providers =
      DB.all_active_providers_for_account(
        socket.assigns.account,
        socket.assigns.subject
      )

    form =
      new_policy(%{}, socket.assigns.subject)
      |> to_form()

    socket =
      assign(socket,
        page_title: "New Policy",
        timezone: Map.get(socket.private.connect_params, "timezone", "UTC"),
        providers: providers,
        params: Map.take(params, ["site_id"]),
        selected_resource: nil,
        enforced_resource_id: params["resource_id"],
        enforced_group_id: params["group_id"],
        form: form
      )

    {:ok, socket}
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/policies"}>Policies</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/policies/new"}>Add Policy</.breadcrumb>
    </.breadcrumbs>
    <.section>
      <:title>{@page_title}</:title>
      <:content>
        <div class="max-w-2xl px-4 py-8 mx-auto lg:py-16">
          <legend class="mb-4 text-xl text-neutral-900">Details</legend>

          <.form for={@form} phx-submit="submit" phx-change="validate">
            <.base_error form={@form} field={:base} />

            <div class="grid gap-4 mb-4 sm:grid-cols-1 sm:gap-6 sm:mb-6">
              <fieldset class="flex flex-col gap-2">
                <.live_component
                  module={PortalWeb.Components.FormComponents.SelectWithGroups}
                  id="policy_group_id"
                  label="Group"
                  placeholder="Select Group"
                  field={@form[:group_id]}
                  fetch_option_callback={&DB.fetch_group_option(&1, @subject)}
                  list_options_callback={&DB.list_group_options(&1, @subject)}
                  value={@enforced_group_id || @form[:group_id].value}
                  disabled={not is_nil(@enforced_group_id)}
                  required
                >
                  <:options_group :let={options_group}>
                    {options_group}
                  </:options_group>

                  <:option :let={group}>
                    <div class="flex items-center gap-3">
                      <.provider_icon
                        type={provider_type_from_group(group)}
                        class="w-5 h-5 flex-shrink-0"
                      />
                      <span>{group.name}</span>
                    </div>
                  </:option>

                  <:no_options :let={name}>
                    <.error data-validation-error-for={name}>
                      <span>
                        You have no groups to create policies for. You can create a group <.link
                          navigate={~p"/#{@account}/groups/new"}
                          class={[link_style()]}
                        >here</.link>.
                      </span>
                    </.error>
                  </:no_options>

                  <:no_search_results>
                    No groups found. Try a different search query or create a new one <.link
                      navigate={~p"/#{@account}/groups/new"}
                      class={link_style()}
                    >here</.link>.
                  </:no_search_results>
                </.live_component>

                <.live_component
                  module={PortalWeb.Components.FormComponents.SelectWithGroups}
                  id="policy_resource_id"
                  label="Resource"
                  placeholder="Select Resource"
                  field={@form[:resource_id]}
                  fetch_option_callback={
                    &PortalWeb.Resources.Components.fetch_resource_option(&1, @subject)
                  }
                  list_options_callback={
                    &PortalWeb.Resources.Components.list_resource_options(&1, @subject)
                  }
                  on_change={&on_resource_change/1}
                  value={@enforced_resource_id || @form[:resource_id].value}
                  disabled={not is_nil(@enforced_resource_id)}
                  required
                >
                  <:options_group :let={group}>
                    {group}
                  </:options_group>

                  <:option :let={resource}>
                    <%= if resource.type == :internet do %>
                      Internet
                      <span :if={not Portal.Account.internet_resource_enabled?(@account)}>
                        - <span class="text-red-800">upgrade to unlock</span>
                      </span>
                    <% else %>
                      {resource.name}

                      <span
                        :if={resource.site_id}
                        class="text-neutral-500 inline-flex"
                      >
                        ({resource.site.name})
                      </span>
                    <% end %>

                    <span :if={is_nil(resource.site_id)} class="text-red-800">
                      (not connected to a Site)
                    </span>
                  </:option>

                  <:no_options :let={name}>
                    <.error data-validation-error-for={name}>
                      <span>
                        You have no resources to create policies for. You can create a resource <.link
                          navigate={~p"/#{@account}/resources/new"}
                          class={[link_style()]}
                        >here</.link>.
                      </span>
                    </.error>
                  </:no_options>

                  <:no_search_results>
                    No Resources found. Try a different search query or create a new one <.link
                      navigate={~p"/#{@account}/resources/new"}
                      class={link_style()}
                    >here</.link>.
                  </:no_search_results>
                </.live_component>

                <.input
                  field={@form[:description]}
                  label="Description"
                  type="textarea"
                  placeholder="Enter an optional reason for creating this policy here."
                  phx-debounce="300"
                />
              </fieldset>

              <.conditions_form
                :if={not is_nil(@selected_resource)}
                form={@form}
                account={@account}
                timezone={@timezone}
                providers={@providers}
                selected_resource={@selected_resource}
              />

              <.options_form
                :if={not is_nil(@selected_resource)}
                form={@form}
                account={@account}
                selected_resource={@selected_resource}
              />
            </div>

            <div class="flex justify-end">
              <.submit_button phx-disable-with="Creating Policy..." class="w-full">
                Create Policy
              </.submit_button>
            </div>
          </.form>
        </div>
      </:content>
    </.section>
    """
  end

  def on_resource_change({_id, _name, resource}) do
    send(self(), {:change_resource, resource})
  end

  def handle_info({:change_resource, resource}, socket) do
    {:noreply, assign(socket, selected_resource: resource)}
  end

  def handle_event("validate", %{"policy" => params}, socket) do
    form =
      params
      |> maybe_enforce_resource_id(socket)
      |> maybe_enforce_group_id(socket)
      |> map_condition_params(empty_values: :keep)
      |> maybe_drop_unsupported_conditions(socket)
      |> new_policy(socket.assigns.subject)
      |> to_form(action: :validate)

    {:noreply, assign(socket, form: form)}
  end

  def handle_event("submit", %{"policy" => params}, socket) do
    params =
      params
      |> maybe_enforce_resource_id(socket)
      |> maybe_enforce_group_id(socket)
      |> map_condition_params(empty_values: :drop)
      |> maybe_drop_unsupported_conditions(socket)

    with {:ok, _policy} <- create_policy(params, socket.assigns.subject) do
      socket = put_flash(socket, :success, "Policy created successfully")

      cond do
        site_id = socket.assigns.params["site_id"] ->
          # Created from Add Resource from Site
          {:noreply,
           push_navigate(socket, to: ~p"/#{socket.assigns.account}/sites/#{site_id}?#resources")}

        resource_id = socket.assigns.enforced_resource_id ->
          # Created from Add Resource from Resources
          {:noreply,
           push_navigate(socket, to: ~p"/#{socket.assigns.account}/resources/#{resource_id}")}

        group_id = socket.assigns.enforced_group_id ->
          # Created from Add Policy from Group
          {:noreply, push_navigate(socket, to: ~p"/#{socket.assigns.account}/groups/#{group_id}")}

        true ->
          # Created from Add Policy from Policies
          {:noreply, push_navigate(socket, to: ~p"/#{socket.assigns.account}/policies")}
      end
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, action: :insert))}
    end
  end

  defp maybe_enforce_resource_id(attrs, socket) do
    if resource_id = socket.assigns.enforced_resource_id do
      Map.put(attrs, "resource_id", resource_id)
    else
      attrs
    end
  end

  defp maybe_enforce_group_id(attrs, socket) do
    if group_id = socket.assigns.enforced_group_id do
      Map.put(attrs, "group_id", group_id)
    else
      attrs
    end
  end

  # Inline functions from Portal.Policies

  defp new_policy(attrs, %Auth.Subject{} = subject) do
    import Ecto.Changeset

    %Policy{}
    |> cast(attrs, ~w[description group_id resource_id]a)
    |> validate_required(~w[group_id resource_id]a)
    |> cast_embed(:conditions, with: &Portal.Policies.Condition.changeset/3)
    |> Policy.changeset()
    |> put_change(:account_id, subject.account.id)
  end

  defp create_policy(attrs, %Auth.Subject{} = subject) do
    changeset = new_policy(attrs, subject)
    DB.insert_policy(changeset, subject)
  end

  defmodule DB do
    import Ecto.Query
    import Portal.Repo.Query
    alias Portal.{Safe, Userpass, EmailOTP, OIDC, Google, Entra, Okta, Group}
    alias Portal.Auth

    def insert_policy(changeset, %Auth.Subject{} = subject) do
      Safe.scoped(changeset, subject)
      |> Safe.insert()
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

    def fetch_group_option(id, subject) do
      group =
        from(g in Group, as: :groups)
        |> where([groups: g], g.id == ^id)
        |> join(:left, [groups: g], d in assoc(g, :directory), as: :directory)
        |> join(:left, [directory: d], gd in Portal.Google.Directory,
          on: gd.id == d.id and d.type == :google,
          as: :google_directory
        )
        |> join(:left, [directory: d], ed in Portal.Entra.Directory,
          on: ed.id == d.id and d.type == :entra,
          as: :entra_directory
        )
        |> join(:left, [directory: d], od in Portal.Okta.Directory,
          on: od.id == d.id and d.type == :okta,
          as: :okta_directory
        )
        |> select_merge(
          [directory: d, google_directory: gd, entra_directory: ed, okta_directory: od],
          %{
            directory_name:
              fragment(
                "COALESCE(?, ?, ?)",
                gd.name,
                ed.name,
                od.name
              ),
            directory_type: d.type
          }
        )
        |> Safe.scoped(subject)
        |> Safe.one!()

      {:ok, group_option(group)}
    end

    def list_group_options(search_query_or_nil, subject) do
      query =
        from(g in Group, as: :groups)
        |> join(:left, [groups: g], d in assoc(g, :directory), as: :directory)
        |> join(:left, [directory: d], gd in Portal.Google.Directory,
          on: gd.id == d.id and d.type == :google,
          as: :google_directory
        )
        |> join(:left, [directory: d], ed in Portal.Entra.Directory,
          on: ed.id == d.id and d.type == :entra,
          as: :entra_directory
        )
        |> join(:left, [directory: d], od in Portal.Okta.Directory,
          on: od.id == d.id and d.type == :okta,
          as: :okta_directory
        )
        |> select_merge(
          [directory: d, google_directory: gd, entra_directory: ed, okta_directory: od],
          %{
            directory_name:
              fragment(
                "COALESCE(?, ?, ?)",
                gd.name,
                ed.name,
                od.name
              ),
            directory_type: d.type
          }
        )
        |> order_by([groups: g], asc: g.name)
        |> limit(25)

      query =
        if search_query_or_nil != "" and search_query_or_nil != nil do
          from(g in query, where: fulltext_search(g.name, ^search_query_or_nil))
        else
          query
        end

      groups = query |> Safe.scoped(subject) |> Safe.all()
      metadata = %{limit: 25, count: length(groups)}

      {:ok, grouped_select_options(groups), metadata}
    end

    defp grouped_select_options(groups) do
      groups
      |> Enum.group_by(&option_groups_index_and_label/1)
      |> Enum.sort_by(fn {{options_group_index, options_group_label}, _groups} ->
        {options_group_index, options_group_label}
      end)
      |> Enum.map(fn {{_options_group_index, options_group_label}, groups} ->
        {options_group_label, groups |> Enum.sort_by(& &1.name) |> Enum.map(&group_option/1)}
      end)
    end

    defp option_groups_index_and_label(group) do
      index =
        cond do
          group_synced?(group) -> 9
          group_managed?(group) -> 1
          true -> 2
        end

      label =
        cond do
          group_synced?(group) -> "Synced from #{directory_display_name(group)}"
          group_managed?(group) -> "Managed by Firezone"
          true -> "Manually managed"
        end

      {index, label}
    end

    defp group_option(group), do: {group.id, group.name, group}
    defp group_synced?(group), do: not is_nil(group.idp_id)
    defp group_managed?(group), do: group.type == :managed

    defp directory_display_name(%{directory_name: name}) when not is_nil(name), do: name
    defp directory_display_name(_), do: "Unknown"
  end
end

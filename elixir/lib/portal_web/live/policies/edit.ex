defmodule PortalWeb.Policies.Edit do
  use PortalWeb, :live_view
  import PortalWeb.Policies.Components
  alias Portal.{Policy, Auth}
  alias __MODULE__.Database

  def mount(%{"id" => id}, _session, socket) do
    policy = Database.get_policy!(id, socket.assigns.subject)

    providers =
      Database.all_active_providers_for_account(
        socket.assigns.account,
        socket.assigns.subject
      )

    form =
      policy
      |> change_policy(%{})
      |> to_form()

    socket =
      assign(socket,
        page_title: "Edit Policy #{policy.id}",
        timezone: Map.get(socket.private.connect_params, "timezone", "UTC"),
        providers: providers,
        policy: policy,
        selected_resource: policy.resource,
        form: form
      )

    {:ok, socket}
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/policies"}>Policies</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/policies/#{@policy}"}>
        <.policy_name policy={@policy} />
      </.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/policies/#{@policy}/edit"}>
        Edit
      </.breadcrumb>
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
                  fetch_option_callback={&Database.fetch_group_option(&1, @subject)}
                  list_options_callback={&Database.list_group_options(&1, @subject)}
                  value={@form[:group_id].value}
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
                  value={@form[:resource_id].value}
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
                    <% end %>

                    <span :if={is_nil(resource.site_id)} class="text-red-800">
                      (not connected to a Site)
                    </span>
                    <span
                      :if={resource.site_id}
                      class="text-neutral-500 inline-flex"
                    >
                      ({resource.site.name})
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
              <.submit_button phx-disable-with="Updating Policy...">
                Save
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
    params =
      params
      |> map_condition_params(empty_values: :drop)
      |> maybe_drop_unsupported_conditions(socket)

    changeset =
      change_policy(socket.assigns.policy, params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("submit", %{"policy" => params}, socket) do
    params =
      params
      |> map_condition_params(empty_values: :drop)
      |> maybe_drop_unsupported_conditions(socket)

    case update_policy(socket.assigns.policy, params, socket.assigns.subject) do
      {:ok, policy} ->
        socket =
          socket
          |> put_flash(:success, "Policy updated successfully")
          |> push_navigate(to: ~p"/#{socket.assigns.account}/policies/#{policy}")

        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  # Inline functions from Portal.Policies

  defp change_policy(%Policy{} = policy, attrs) do
    import Ecto.Changeset

    policy
    |> cast(attrs, ~w[description group_id resource_id]a)
    |> validate_required(~w[group_id resource_id]a)
    |> cast_embed(:conditions, with: &Portal.Policies.Condition.changeset/3)
    |> Policy.changeset()
  end

  defp update_policy(%Policy{} = policy, attrs, %Auth.Subject{} = subject) do
    changeset = change_policy(policy, attrs)
    Database.update_policy(changeset, subject)
  end

  defmodule Database do
    import Ecto.Query
    import Portal.Repo.Query
    alias Portal.{Policy, Safe, Userpass, EmailOTP, OIDC, Google, Entra, Okta, Group}
    alias Portal.Authentication

    def get_policy!(id, %Auth.Subject{} = subject) do
      from(p in Policy, as: :policies)
      |> where([policies: p], p.id == ^id)
      |> preload([:group, :resource])
      |> Safe.scoped(subject)
      |> Safe.one!()
    end

    def update_policy(changeset, %Auth.Subject{} = subject) do
      Safe.scoped(changeset, subject)
      |> Safe.update()
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

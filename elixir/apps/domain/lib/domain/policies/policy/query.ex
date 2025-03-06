defmodule Domain.Policies.Policy.Query do
  use Domain, :query

  def all do
    from(policies in Domain.Policies.Policy, as: :policies)
  end

  def not_deleted do
    all()
    |> where([policies: policies], is_nil(policies.deleted_at))
  end

  def not_disabled(queryable \\ not_deleted()) do
    where(queryable, [policies: policies], is_nil(policies.disabled_at))
  end

  def disabled(queryable \\ not_deleted()) do
    where(queryable, [policies: policies], not is_nil(policies.disabled_at))
  end

  def by_id(queryable, id) do
    where(queryable, [policies: policies], policies.id == ^id)
  end

  def by_id_or_persistent_id(queryable, id) do
    where(queryable, [policies: policies], policies.id == ^id)
    |> or_where(
      [policies: policies],
      policies.persistent_id == ^id and is_nil(policies.replaced_by_policy_id)
    )
  end

  def by_account_id(queryable, account_id) do
    where(queryable, [policies: policies], policies.account_id == ^account_id)
  end

  def by_resource_id(queryable, resource_id) do
    where(queryable, [policies: policies], policies.resource_id == ^resource_id)
  end

  def by_resource_ids(queryable, resource_ids) do
    where(queryable, [policies: policies], policies.resource_id in ^resource_ids)
  end

  def by_actor_group_id(queryable, actor_group_id) do
    queryable
    |> where([policies: policies], policies.actor_group_id == ^actor_group_id)
  end

  def by_actor_group_provider_id(queryable, provider_id) do
    queryable
    |> with_joined_actor_group()
    |> where([actor_group: actor_group], actor_group.provider_id == ^provider_id)
  end

  def by_actor_id(queryable, actor_id) do
    queryable
    |> with_joined_memberships()
    |> where([memberships: memberships], memberships.actor_id == ^actor_id)
  end

  def count_by_resource_id(queryable) do
    queryable
    |> group_by([policies: policies], policies.resource_id)
    |> select([policies: policies], %{
      resource_id: policies.resource_id,
      count: count(policies.id)
    })
  end

  def delete(queryable) do
    queryable
    |> Ecto.Query.select([policies: policies], policies)
    |> Ecto.Query.update([policies: policies],
      set: [
        deleted_at: fragment("COALESCE(?, timezone('UTC', NOW()))", policies.deleted_at)
      ]
    )
  end

  def with_joined_actor_group(queryable) do
    with_named_binding(queryable, :actor_group, fn queryable, binding ->
      join(queryable, :inner, [policies: policies], actor_group in assoc(policies, ^binding),
        as: ^binding
      )
    end)
  end

  def with_joined_resource(queryable) do
    with_named_binding(queryable, :resource, fn queryable, binding ->
      join(queryable, :inner, [policies: policies], resource in assoc(policies, ^binding),
        as: ^binding
      )
    end)
  end

  def with_joined_memberships(queryable) do
    queryable
    |> with_joined_actor_group()
    |> with_named_binding(:memberships, fn queryable, binding ->
      join(
        queryable,
        :inner,
        [actor_group: actor_group],
        memberships in assoc(actor_group, ^binding),
        as: ^binding
      )
    end)
  end

  # Pagination

  @impl Domain.Repo.Query
  def cursor_fields,
    do: [
      {:policies, :asc, :inserted_at},
      {:policies, :asc, :id}
    ]

  @impl Domain.Repo.Query
  def filters,
    do: [
      %Domain.Repo.Filter{
        name: :resource_id,
        title: "Resource",
        type: {:string, :uuid},
        values: &Domain.Resources.all_resources!/1,
        fun: &filter_by_resource_id/2
      },
      %Domain.Repo.Filter{
        name: :actor_group_id,
        title: "Actor Group",
        type: {:string, :uuid},
        fun: &filter_by_actor_group_id/2
      },
      %Domain.Repo.Filter{
        name: :actor_group_name,
        title: "Actor Group Name",
        type: {:string, :websearch},
        fun: &filter_by_actor_group_name/2
      },
      %Domain.Repo.Filter{
        name: :resource_name,
        title: "Resource Name",
        type: {:string, :websearch},
        fun: &filter_by_resource_name/2
      },
      %Domain.Repo.Filter{
        name: :group_or_resource_name,
        title: "Group Name or Resource Name",
        type: {:string, :websearch},
        fun: &filter_by_group_or_resource_name/2
      },
      %Domain.Repo.Filter{
        name: :status,
        title: "Status",
        type: :string,
        values: [
          {"Active", "active"},
          {"Disabled", "disabled"}
        ],
        fun: &filter_by_status/2
      },
      %Domain.Repo.Filter{
        name: :deleted?,
        type: :boolean,
        fun: &filter_deleted/1
      }
    ]

  def filter_by_resource_id(queryable, resource_id) do
    {queryable, dynamic([policies: policies], policies.resource_id == ^resource_id)}
  end

  def filter_by_actor_group_id(queryable, actor_group_id) do
    {queryable, dynamic([policies: policies], policies.actor_group_id == ^actor_group_id)}
  end

  def filter_by_actor_group_name(queryable, actor_group_name) do
    queryable =
      with_named_binding(queryable, :actor_group, fn queryable, binding ->
        join(queryable, :inner, [policies: policies], actor_group in assoc(policies, ^binding),
          as: ^binding
        )
      end)

    {queryable,
     dynamic(
       [actor_group: actor_group],
       ilike(actor_group.name, ^"%#{actor_group_name}%")
     )}
  end

  def filter_by_resource_name(queryable, resource_name) do
    queryable =
      with_named_binding(queryable, :resource, fn queryable, binding ->
        join(queryable, :inner, [policies: policies], resource in assoc(policies, ^binding),
          as: ^binding
        )
      end)

    {queryable,
     dynamic(
       [resource: resource],
       ilike(resource.name, ^"%#{resource_name}%")
     )}
  end

  def filter_by_group_or_resource_name(queryable, name) do
    {queryable, dynamic_group_filter} = filter_by_actor_group_name(queryable, name)
    {queryable, dynamic_resource_filter} = filter_by_resource_name(queryable, name)

    {queryable, dynamic(^dynamic_group_filter or ^dynamic_resource_filter)}
  end

  def filter_by_status(queryable, "active") do
    {queryable, dynamic([policies: policies], is_nil(policies.disabled_at))}
  end

  def filter_by_status(queryable, "disabled") do
    {queryable, dynamic([policies: policies], not is_nil(policies.disabled_at))}
  end

  def filter_deleted(queryable) do
    {queryable, dynamic([policies: policies], not is_nil(policies.deleted_at))}
  end
end

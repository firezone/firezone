defmodule Domain.Auth.Identity.Query do
  use Domain, :query

  def all do
    from(identities in Domain.Auth.Identity, as: :identities)
  end

  def not_deleted do
    all()
    |> where([identities: identities], is_nil(identities.deleted_at))
  end

  def deleted do
    all()
    |> where([identities: identities], not is_nil(identities.deleted_at))
  end

  def not_disabled(queryable \\ not_deleted()) do
    queryable
    |> with_assoc(:inner, :actor)
    |> where([actor: actor], is_nil(actor.deleted_at))
    |> where([actor: actor], is_nil(actor.disabled_at))
    |> with_assoc(:inner, :provider)
    |> where([provider: provider], is_nil(provider.deleted_at))
    |> where([provider: provider], is_nil(provider.disabled_at))
  end

  def by_id(queryable, id)

  def by_id(queryable, {:not, id}) do
    where(queryable, [identities: identities], identities.id != ^id)
  end

  def by_id(queryable, id) do
    where(queryable, [identities: identities], identities.id == ^id)
  end

  def by_account_id(queryable, account_id) do
    where(queryable, [identities: identities], identities.account_id == ^account_id)
  end

  def by_actor_id(queryable, {:in, actor_ids}) do
    where(queryable, [identities: identities], identities.actor_id in ^actor_ids)
  end

  def by_actor_id(queryable, actor_id) do
    where(queryable, [identities: identities], identities.actor_id == ^actor_id)
  end

  def by_provider_id(queryable, provider_id) do
    queryable
    |> where([identities: identities], identities.provider_id == ^provider_id)
  end

  def by_adapter(queryable, adapter) do
    where(queryable, [identities: identities], identities.adapter == ^adapter)
  end

  def by_provider_identifier(queryable, provider_identifier)

  def by_provider_identifier(queryable, {:in, provider_identifiers}) do
    where(
      queryable,
      [identities: identities],
      identities.provider_identifier in ^provider_identifiers
    )
  end

  def by_provider_identifier(queryable, provider_identifier) do
    where(
      queryable,
      [identities: identities],
      identities.provider_identifier == ^provider_identifier
    )
  end

  def by_provider_claims(queryable, provider_identifier, nil) do
    by_provider_identifier(queryable, provider_identifier)
  end

  def by_provider_claims(queryable, provider_identifier, "") do
    by_provider_identifier(queryable, provider_identifier)
  end

  def by_provider_claims(queryable, provider_identifier, email) do
    # For manually created IdP identities (where last_seen_at is nil)
    # we also try to fetch them by email, so that users can provision
    # them without knowing which ID will be assigned to the OIDC sub claim.
    where(
      queryable,
      [identities: identities],
      identities.provider_identifier == ^provider_identifier or
        (is_nil(identities.last_seen_at) and
           identities.provider_identifier == ^email)
    )
    |> order_by([identities: identities], desc_nulls_last: identities.last_seen_at)
    |> limit(1)
  end

  def by_id_or_provider_identifier(queryable, id_or_provider_identifier) do
    if Domain.Repo.valid_uuid?(id_or_provider_identifier) do
      where(
        queryable,
        [identities: identities],
        identities.provider_identifier == ^id_or_provider_identifier or
          identities.id == ^id_or_provider_identifier
      )
    else
      by_provider_identifier(queryable, id_or_provider_identifier)
    end
  end

  def by_membership_rules(queryable, rules) do
    dynamic =
      Enum.reduce(rules, false, fn
        rule, false ->
          membership_rule_dynamic(rule)

        rule, dynamic ->
          dynamic([identities: identities], ^dynamic or ^membership_rule_dynamic(rule))
      end)

    where(queryable, ^dynamic)
  end

  defp membership_rule_dynamic(%{path: path, operator: :is_in, values: values}) do
    dynamic(
      [identities: identities],
      fragment("? \\?| ?", json_extract_path(identities.provider_state, ^path), ^values)
    )
  end

  defp membership_rule_dynamic(%{path: path, operator: :is_not_in, values: values}) do
    dynamic(
      [identities: identities],
      fragment("NOT (? \\?| ?)", json_extract_path(identities.provider_state, ^path), ^values)
    )
  end

  defp membership_rule_dynamic(%{path: path, operator: :contains, values: [value]}) do
    dynamic(
      [identities: identities],
      fragment(
        "?->>0 LIKE '%' || ? || '%'",
        json_extract_path(identities.provider_state, ^path),
        ^value
      )
    )
  end

  defp membership_rule_dynamic(%{path: path, operator: :does_not_contain, values: [value]}) do
    dynamic(
      [identities: identities],
      fragment(
        "?->>0 NOT LIKE '%' || ? || '%'",
        json_extract_path(identities.provider_state, ^path),
        ^value
      )
    )
  end

  defp membership_rule_dynamic(%{operator: true}) do
    dynamic(
      [identities: identities],
      true
    )
  end

  def lock(queryable) do
    lock(queryable, "FOR UPDATE")
  end

  def returning_ids(queryable) do
    select(queryable, [identities: identities], identities.id)
  end

  def returning_distinct_actor_ids(queryable) do
    queryable
    |> select([identities: identities], identities.actor_id)
    |> distinct(true)
  end

  def group_by_provider_id(queryable) do
    queryable
    |> group_by([identities: identities], identities.provider_id)
    |> select([identities: identities], %{
      provider_id: identities.provider_id,
      count: count(identities.id)
    })
  end

  def max_last_seen_at_grouped_by_actor_id(queryable) do
    queryable
    |> group_by([identities: identities], identities.actor_id)
    |> select([identities: identities], %{
      actor_id: identities.actor_id,
      max: max(identities.last_seen_at)
    })
  end

  def delete(queryable) do
    queryable
    |> Ecto.Query.select([identities: identities], identities)
    |> Ecto.Query.update([identities: identities],
      set: [
        deleted_at: fragment("COALESCE(?, timezone('UTC', NOW()))", identities.deleted_at),
        provider_state: ^%{}
      ]
    )
  end

  def with_preloaded_assoc(queryable, type \\ :left, assoc) do
    queryable
    |> with_assoc(type, assoc)
    |> preload([{^assoc, assoc}], [{^assoc, assoc}])
  end

  def with_assoc(queryable, type \\ :left, assoc) do
    with_named_binding(queryable, assoc, fn query, binding ->
      join(query, type, [identities: identities], a in assoc(identities, ^binding), as: ^binding)
    end)
  end

  # Pagination

  @impl Domain.Repo.Query
  def cursor_fields,
    do: [
      {:identities, :asc, :inserted_at},
      {:identities, :asc, :id}
    ]
end

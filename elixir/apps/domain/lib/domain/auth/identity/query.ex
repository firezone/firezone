defmodule Domain.Auth.Identity.Query do
  use Domain, :query

  def all do
    from(identities in Domain.Auth.Identity, as: :identities)
  end

  def not_deleted do
    all()
    |> where([identities: identities], is_nil(identities.deleted_at))
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

  def by_id(queryable \\ not_deleted(), id)

  def by_id(queryable, {:not, id}) do
    where(queryable, [identities: identities], identities.id != ^id)
  end

  def by_id(queryable, id) do
    where(queryable, [identities: identities], identities.id == ^id)
  end

  def by_account_id(queryable \\ not_deleted(), account_id) do
    where(queryable, [identities: identities], identities.account_id == ^account_id)
  end

  def by_actor_id(queryable \\ not_deleted(), actor_id) do
    where(queryable, [identities: identities], identities.actor_id == ^actor_id)
  end

  def by_provider_id(queryable \\ not_deleted(), provider_id) do
    queryable
    |> where([identities: identities], identities.provider_id == ^provider_id)
  end

  def by_adapter(queryable \\ not_deleted(), adapter) do
    where(queryable, [identities: identities], identities.adapter == ^adapter)
  end

  def by_provider_identifier(queryable \\ not_deleted(), provider_identifier)

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
  end

  def by_id_or_provider_identifier(queryable \\ not_deleted(), id_or_provider_identifier) do
    if Domain.Validator.valid_uuid?(id_or_provider_identifier) do
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

  def by_membership_rules(queryable \\ not_deleted(), rules) do
    dynamic =
      Enum.reduce(rules, false, fn
        %{path: path, operator: :is_in, values: values}, dynamic ->
          dynamic(
            [identities: identities],
            ^dynamic or
              type(json_extract_path(identities.provider_state, ^path), :string) in ^values
          )

        %{path: path, operator: :is_not_in, values: values}, dynamic ->
          dynamic(
            [identities: identities],
            ^dynamic or
              type(json_extract_path(identities.provider_state, ^path), :string) not in ^values
          )

        %{path: path, operator: :contains, values: [value]}, dynamic ->
          dynamic(
            [identities: identities],
            ^dynamic or
              fragment(
                "? LIKE ?",
                type(json_extract_path(identities.provider_state, ^path), :string),
                ^value
              )
          )

        %{path: path, operator: :does_not_contain, values: [value]}, dynamic ->
          dynamic(
            [identities: identities],
            ^dynamic or
              fragment(
                "? NOT LIKE ?",
                type(json_extract_path(identities.provider_state, ^path), :string),
                ^value
              )
          )

        %{operator: true}, dynamic ->
          dynamic(
            [identities: identities],
            ^dynamic or
              true
          )
      end)

    where(queryable, ^dynamic)
  end

  def lock(queryable \\ not_deleted()) do
    lock(queryable, "FOR UPDATE")
  end

  def returning_ids(queryable \\ not_deleted()) do
    select(queryable, [identities: identities], identities.id)
  end

  def returning_distinct_actor_ids(queryable \\ not_deleted()) do
    queryable
    |> select([identities: identities], identities.actor_id)
    |> distinct(true)
  end

  def group_by_provider_id(queryable \\ not_deleted()) do
    queryable
    |> group_by([identities: identities], identities.provider_id)
    |> select([identities: identities], %{
      provider_id: identities.provider_id,
      count: count(identities.id)
    })
  end

  def delete(queryable \\ not_deleted()) do
    queryable
    |> Ecto.Query.select([identities: identities], identities)
    |> Ecto.Query.update([identities: identities],
      set: [
        deleted_at: fragment("COALESCE(?, NOW())", identities.deleted_at),
        provider_state: ^%{}
      ]
    )
  end

  def with_preloaded_assoc(queryable \\ not_deleted(), type \\ :left, assoc) do
    queryable
    |> with_assoc(type, assoc)
    |> preload([{^assoc, assoc}], [{^assoc, assoc}])
  end

  def with_assoc(queryable \\ not_deleted(), type \\ :left, assoc) do
    with_named_binding(queryable, assoc, fn query, binding ->
      join(query, type, [identities: identities], a in assoc(identities, ^binding), as: ^binding)
    end)
  end
end

defmodule FzHttp.Users.User.Query do
  use FzHttp, :query

  def all do
    from(users in FzHttp.Users.User, as: :users)
  end

  def by_id(queryable \\ all(), id) do
    where(queryable, [users: users], users.id == ^id)
  end

  def by_email(queryable \\ all(), email) do
    where(queryable, [users: users], users.email == ^email)
  end

  def by_role(queryable \\ all(), role) do
    where(queryable, [users: users], users.role == ^role)
  end

  def where_sign_in_token_is_not_expired(queryable \\ all()) do
    queryable
    |> where(
      [users: users],
      datetime_add(users.sign_in_token_created_at, 1, "hour") >= fragment("NOW()")
    )
  end

  def hydrate_device_count(queryable \\ all()) do
    queryable
    |> with_assoc(:devices)
    |> group_by([users: users], users.id)
    |> select_merge([users: users, devices: devices], %{device_count: count(devices.id)})
  end

  def with_assoc(queryable \\ all(), assoc) do
    with_named_binding(queryable, assoc, fn query, binding ->
      join(query, :left, [users: users], a in assoc(users, ^binding), as: ^binding)
    end)
  end
end

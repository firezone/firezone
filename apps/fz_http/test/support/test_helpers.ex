defmodule FzHttp.TestHelpers do
  @moduledoc """
  Test setup helpers
  """
  alias FzHttp.{Fixtures, Repo, Users, Users.User}

  def create_device(tags) do
    device =
      if tags[:unauthed] || is_nil(tags[:user_id]) do
        Fixtures.device()
      else
        Fixtures.device(%{user_id: tags[:user_id]})
      end

    {:ok, device: device}
  end

  def create_other_user_device(_) do
    user_id = Fixtures.user(%{email: "other_user@test"}).id

    device =
      Fixtures.device(%{
        user_id: user_id,
        name: "other device",
        public_key: "other-pubkey",
        private_key: "other-privkey"
      })

    {:ok, other_device: device}
  end

  def create_devices(tags) do
    user_id =
      if tags[:unathed] do
        Fixtures.user().id
      else
        tags[:user_id]
      end

    devices =
      Enum.map(1..5, fn num ->
        Fixtures.device(%{
          name: "device #{num}",
          public_key: "#{num}",
          private_key: "#{num}",
          user_id: user_id
        })
      end)

    {:ok, devices: devices}
  end

  def create_user(_) do
    user = Fixtures.user()
    {:ok, user: user}
  end

  def create_session(_) do
    session = Fixtures.session()
    {:ok, session: session}
  end

  def create_allow_rule(tags) do
    rule = Fixtures.rule(%{action: :allow})
    {:ok, rule: rule}
  end

  def create_deny_rule(tags) do
    rule = Fixtures.rule(%{action: :deny})
    {:ok, rule: rule}
  end

  def create_rule(tags) do
    rule = Fixtures.rule(%{})
    {:ok, rule: rule}
  end

  def create_rule6(tags) do
    rule = Fixtures.rule6(%{})
    {:ok, rule6: rule}
  end

  def create_rule4(tags) do
    rule = Fixtures.rule4(%{})
    {:ok, rule4: rule}
  end

  @doc """
  XXX: Mimic a more realistic setup.
  """
  def create_rules(tags) do
    rules =
      1..5
      |> Enum.map(fn num ->
        destination = "#{num}.#{num}.#{num}.0/24"
        Fixtures.rule(%{destination: destination})
      end)

    {:ok, rules: rules}
  end

  def create_user_with_valid_sign_in_token(_) do
    {:ok, user: %User{} = Fixtures.user(Users.sign_in_keys())}
  end

  def create_user_with_expired_sign_in_token(_) do
    expired = DateTime.add(DateTime.utc_now(), -1 * 86_401)
    params = %{Users.sign_in_keys() | sign_in_token_created_at: expired}
    {:ok, user: %User{} = Fixtures.user(params)}
  end

  def create_users(%{count: count}) do
    users =
      Enum.map(1..count, fn i ->
        Fixtures.user(%{email: "userlist#{i}@test"})
      end)

    {:ok, users: users}
  end

  def create_users(_), do: create_users(%{count: 5})

  def clear_users(_) do
    {count, _result} = Repo.delete_all(User)
    {:ok, count: count}
  end
end

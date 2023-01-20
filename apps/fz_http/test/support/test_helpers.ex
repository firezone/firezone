defmodule FzHttp.TestHelpers do
  @moduledoc """
  Test setup helpers
  """

  alias FzHttp.{
    ConnectivityChecksFixtures,
    DevicesFixtures,
    NotificationsFixtures,
    Repo,
    RulesFixtures,
    Users.User,
    UsersFixtures
  }

  def clear_users do
    Repo.delete_all(User)
  end

  def create_unprivileged_device(%{unprivileged_user: user}) do
    {:ok, device: DevicesFixtures.device(%{user_id: user.id})}
  end

  def create_device(tags) do
    device =
      if tags[:unauthed] || is_nil(tags[:user_id]) do
        DevicesFixtures.device()
      else
        DevicesFixtures.device(%{user_id: tags[:user_id]})
      end

    {:ok, device: device}
  end

  def create_other_user_device(_) do
    user_id = UsersFixtures.user(%{role: :unprivileged, email: "other_user@test"}).id

    device =
      DevicesFixtures.device(%{
        user_id: user_id,
        name: "other device"
      })

    {:ok, other_device: device}
  end

  def create_connectivity_checks(_tags) do
    connectivity_checks =
      Enum.map(1..5, fn _i ->
        ConnectivityChecksFixtures.connectivity_check_fixture()
      end)

    {:ok, connectivity_checks: connectivity_checks}
  end

  def create_devices(tags) do
    user_id =
      if tags[:unathed] || is_nil(tags[:user_id]) do
        UsersFixtures.user().id
      else
        tags[:user_id]
      end

    devices =
      Enum.map(1..5, fn num ->
        DevicesFixtures.device(%{
          name: "device #{num}",
          user_id: user_id
        })
      end)

    {:ok, devices: devices}
  end

  def create_user(tags) do
    role = tags[:role] || :admin
    user = UsersFixtures.user(%{role: role})

    {:ok, user: user}
  end

  def create_accept_rule(_) do
    rule = RulesFixtures.rule(%{action: :accept})
    {:ok, rule: rule}
  end

  def create_drop_rule(_) do
    rule = RulesFixtures.rule(%{action: :drop})
    {:ok, rule: rule}
  end

  def create_rule(_) do
    rule = RulesFixtures.rule(%{})
    {:ok, rule: rule}
  end

  def create_rule_accept(_) do
    rule = RulesFixtures.rule(%{action: :accept})
    {:ok, rule: rule}
  end

  @doc """
  XXX: Mimic a more realistic setup.
  """
  def create_rules(_) do
    rules =
      1..5
      |> Enum.map(fn num ->
        destination = "#{num}.#{num}.#{num}.0/24"
        RulesFixtures.rule(%{destination: destination})
      end)

    {rules_with_users, users_and_devices} =
      4..6
      |> Enum.map(fn num ->
        user = UsersFixtures.user()
        destination = "#{num}.#{num}.#{num}.0/24"

        device =
          DevicesFixtures.device(%{
            name: "device #{num}",
            user_id: user.id
          })

        rule = RulesFixtures.rule(%{destination: destination, user_id: user.id})
        {rule, {user, device}}
      end)
      |> Enum.unzip()

    {users, devices} = Enum.unzip(users_and_devices)

    destination = "7.7.7.0/24"
    user = UsersFixtures.user()
    rule_without_device = RulesFixtures.rule(%{destination: destination, user_id: user.id})

    rules = rules ++ [rule_without_device | rules_with_users]
    users = [user | users]

    {:ok, %{rules: rules, users: users, devices: devices}}
  end

  def create_rule_with_user_and_device(_) do
    user = UsersFixtures.user()
    rule = RulesFixtures.rule(%{user_id: user.id, destination: "10.20.30.0/24"})

    device =
      DevicesFixtures.device(%{
        name: "device",
        user_id: user.id
      })

    {:ok, rule: rule, user: user, device: device}
  end

  def create_rule_with_user(opts \\ %{}) do
    user = UsersFixtures.user()
    rule = RulesFixtures.rule(Map.merge(%{user_id: user.id}, opts))

    {:ok, rule: rule, user: user}
  end

  def create_rule_with_ports(opts \\ %{}) do
    rule = RulesFixtures.rule(Map.merge(%{port_range: "10 - 20", port_type: :udp}, opts))

    {:ok, rule: rule}
  end

  def create_user_with_valid_sign_in_token(_) do
    {:ok, user: %User{}} = UsersFixtures.user()
  end

  def create_user_with_expired_sign_in_token(_) do
    expired_at = DateTime.add(DateTime.utc_now(), -1 * 86_401)

    {:ok,
     user:
       UsersFixtures.user(%{
         sign_in_token: "EXPIRED_TOKEN",
         sign_in_token_created_at: expired_at
       })}
  end

  def create_users(tags) do
    count = tags[:count] || 5
    role = tags[:role] || :admin

    users =
      Enum.map(1..count, fn i ->
        UsersFixtures.user(%{role: role, email: "userlist#{i}@test"})
      end)

    {:ok, users: users}
  end

  def clear_users(_) do
    {count, _result} = Repo.delete_all(User)
    {:ok, count: count}
  end

  def create_notifications(opts \\ []) do
    count = opts[:count] || 5

    notifications =
      for i <- 1..count do
        NotificationsFixtures.notification_fixture(user: "test#{i}@localhost")
      end

    {:ok, notifications: notifications}
  end

  def create_notification(attrs \\ []) do
    {:ok, notification: NotificationsFixtures.notification_fixture(attrs)}
  end
end

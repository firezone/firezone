defmodule FgHttp.TestHelpers do
  @moduledoc """
  Test setup helpers
  """
  alias FgHttp.{Fixtures, Repo, Users.PasswordReset, Users.User}

  def create_device(_) do
    device = Fixtures.device()
    {:ok, device: device}
  end

  def create_user(_) do
    user = Fixtures.user()
    {:ok, user: user}
  end

  def create_session(_) do
    session = Fixtures.session()
    {:ok, session: session}
  end

  def create_allow_rule(_) do
    rule = Fixtures.rule(%{action: :allow})
    {:ok, rule: rule}
  end

  def create_deny_rule(_) do
    rule = Fixtures.rule(%{action: :deny})
    {:ok, rule: rule}
  end

  def create_rule(_) do
    rule = Fixtures.rule()
    {:ok, rule: rule}
  end

  def create_rule6(_) do
    rule = Fixtures.rule6()
    {:ok, rule6: rule}
  end

  def create_rule4(_) do
    rule = Fixtures.rule4()
    {:ok, rule4: rule}
  end

  @doc """
  XXX: Mimic a more realistic setup.
  """
  def create_rules(_) do
    device = Fixtures.device()

    rules =
      1..5
      |> Enum.map(fn num ->
        destination = "#{num}.#{num}.#{num}.0/24"
        Fixtures.rule(%{destination: destination, device_id: device.id})
      end)

    {:ok, rules: rules}
  end

  def create_password_reset(_) do
    password_reset = Fixtures.password_reset()
    {:ok, password_reset: password_reset}
  end

  def expired_reset_token(_) do
    # Expired by 1 second
    reset_sent_at =
      DateTime.utc_now()
      |> DateTime.add(-1 * PasswordReset.token_validity_secs() - 1)

    expired_reset_token =
      Fixtures.password_reset()
      |> PasswordReset.changeset(%{reset_sent_at: reset_sent_at})
      |> Repo.update()
      |> elem(1)
      |> Map.get(:reset_token)

    {:ok, expired_reset_token: expired_reset_token}
  end

  def clear_users(_) do
    {count, _result} = Repo.delete_all(User)
    {:ok, count: count}
  end
end

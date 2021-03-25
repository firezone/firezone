defmodule FgHttp.TestHelpers do
  @moduledoc """
  Test setup helpers
  """
  alias FgHttp.{Fixtures, Repo, Users, Users.User}

  def create_device(_) do
    device = Fixtures.device()
    {:ok, device: device}
  end

  def create_rule(_) do
    rule = Fixtures.rule()
    {:ok, rule: rule}
  end

  def create_user(_) do
    user = Fixtures.user()
    {:ok, user: user}
  end

  def clear_users(_) do
    {count, _result} = Repo.delete_all(User)
    {:ok, count: count}
  end
end

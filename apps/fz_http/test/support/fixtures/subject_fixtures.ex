defmodule FzHttp.SubjectFixtures do
  alias FzHttp.Auth
  alias FzHttp.UsersFixtures

  def create_subject(user \\ UsersFixtures.user()) do
    FzHttp.Auth.fetch_subject!(user, {127, 0, 0, 1}, "DummyAgent (1.0.0)")
  end

  def remove_permissions(%Auth.Subject{} = subject) do
    %{subject | permissions: MapSet.new()}
  end

  def add_permission(%Auth.Subject{} = subject, permission) do
    %{subject | permissions: MapSet.put(subject.permissions, permission)}
  end
end

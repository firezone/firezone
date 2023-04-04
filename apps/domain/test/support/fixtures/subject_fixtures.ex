defmodule Domain.SubjectFixtures do
  alias Domain.Auth
  alias Domain.UsersFixtures

  def new(user \\ nil) do
    %Auth.Subject{
      actor: {:user, user},
      permissions: MapSet.new()
    }
  end

  def create_subject(user \\ UsersFixtures.create_user_with_role(:admin)) do
    Domain.Auth.fetch_subject!(user, {127, 0, 0, 1}, "DummyAgent (1.0.0)")
  end

  def remove_permissions(%Auth.Subject{} = subject) do
    %{subject | permissions: MapSet.new()}
  end

  def set_permissions(%Auth.Subject{} = subject, permissions) do
    %{subject | permissions: MapSet.new(permissions)}
  end

  def add_permission(%Auth.Subject{} = subject, permission) do
    %{subject | permissions: MapSet.put(subject.permissions, permission)}
  end
end

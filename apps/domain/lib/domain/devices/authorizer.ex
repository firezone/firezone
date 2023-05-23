defmodule Domain.Devices.Authorizer do
  use Domain.Auth.Authorizer
  alias Domain.Devices.Device

  def manage_own_devices_permission, do: build(Device, :manage_own)
  def manage_devices_permission, do: build(Device, :manage)

  @impl Domain.Auth.Authorizer

  def list_permissions_for_role(:account_admin_user) do
    [
      manage_own_devices_permission(),
      manage_devices_permission()
    ]
  end

  def list_permissions_for_role(:end_user) do
    [
      manage_own_devices_permission()
    ]
  end

  def list_permissions_for_role(_) do
    []
  end

  @impl Domain.Auth.Authorizer
  def for_subject(queryable, %Subject{} = subject) do
    cond do
      has_permission?(subject, manage_devices_permission()) ->
        Device.Query.by_account_id(queryable, subject.account.id)

      has_permission?(subject, manage_own_devices_permission()) ->
        queryable
        |> Device.Query.by_account_id(subject.account.id)
        |> Device.Query.by_actor_id(subject.actor.id)
    end
  end
end

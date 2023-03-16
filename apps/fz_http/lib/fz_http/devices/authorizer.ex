defmodule FzHttp.Devices.Authorizer do
  use FzHttp.Auth.Authorizer
  alias FzHttp.Devices.Device

  def view_devices_permission, do: build(Device, :view)
  def create_own_devices_permission, do: build(Device, :create_owned)
  def create_devices_permission, do: build(Device, :create)
  def update_owned_devices_permission, do: build(Device, :update_owned)
  def update_devices_permission, do: build(Device, :update)
  def delete_owned_devices_permission, do: build(Device, :delete_owned)
  def delete_devices_permission, do: build(Device, :delete)
  def configure_devices_permission, do: build(Device, :configure)

  @impl FzHttp.Auth.Authorizer
  def list_permissions do
    [
      view_devices_permission(),
      create_own_devices_permission(),
      create_devices_permission(),
      update_owned_devices_permission(),
      update_devices_permission(),
      delete_owned_devices_permission(),
      delete_devices_permission(),
      configure_devices_permission()
    ]
  end

  @impl FzHttp.Auth.Authorizer
  def for_subject(queryable, %Subject{} = subject) when is_user(subject) do
    cond do
      has_permission?(subject, create_devices_permission()) ->
        queryable

      has_permission?(subject, view_devices_permission()) ->
        {:user, %{id: user_id}} = subject.actor
        Device.Query.by_user_id(queryable, user_id)
    end
  end

  def ensure_can_manage(%Subject{} = subject, %Device{} = device) do
    cond do
      has_permission?(subject, create_devices_permission()) ->
        :ok

      has_permission?(subject, create_own_devices_permission()) ->
        {:user, %{id: user_id}} = subject.actor

        if device.user_id == user_id do
          :ok
        else
          {:error, :unauthorized}
        end

      true ->
        {:error, :unauthorized}
    end
  end
end

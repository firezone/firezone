defmodule PortalAPI.DeviceTokenOwner do
  @moduledoc """
  Resolves the optional `actor_id` a provisioning request names as the owner
  of a device-bound token: a service account of the caller's account, or the
  Infrastructure service account when omitted. Anything else is a validation
  error on `actor_id`, never a 404, so an id from another account looks the
  same as a made-up one.
  """

  alias Portal.Actor
  alias Portal.Authentication.Subject

  @spec fetch(String.t() | nil, Subject.t()) ::
          {:ok, Actor.t() | nil} | {:error, :unprocessable_entity, keyword()}
  def fetch(nil, %Subject{}), do: {:ok, nil}

  def fetch(actor_id, %Subject{} = subject) when is_binary(actor_id) do
    with {:ok, id} <- Ecto.UUID.cast(actor_id),
         %Actor{} = actor <- Actor.fetch_service_account(id, subject) do
      {:ok, actor}
    else
      _ -> {:error, :unprocessable_entity, validation_errors: %{actor_id: [message()]}}
    end
  end

  def fetch(_actor_id, %Subject{}),
    do: {:error, :unprocessable_entity, validation_errors: %{actor_id: [message()]}}

  defp message, do: "must be a service account of this account"
end

defmodule Portal.UnsubscribeToken do
  @moduledoc """
  A signed token in a notification email that stops that notification being
  emailed to the actor it was sent to, without signing in. Using it again
  changes nothing, so it is not tracked.
  """

  alias Portal.Actor.Preferences

  @notifications Preferences.notifications()
  @salt "unsubscribe-token"
  @max_age_seconds 90 * 24 * 60 * 60

  @spec sign(Portal.Actor.t(), Preferences.notification(), Keyword.t()) :: String.t()
  def sign(%Portal.Actor{} = actor, notification, opts \\ [])
      when notification in @notifications do
    Phoenix.Token.sign(PortalWeb.Endpoint, @salt, {actor.account_id, actor.id, notification}, opts)
  end

  @spec verify(String.t()) ::
          {:ok, {Ecto.UUID.t(), Ecto.UUID.t(), Preferences.notification()}} | {:error, atom()}
  def verify(token) when is_binary(token) do
    case Phoenix.Token.verify(PortalWeb.Endpoint, @salt, token, max_age: @max_age_seconds) do
      {:ok, {account_id, actor_id, notification} = payload}
      when is_binary(account_id) and is_binary(actor_id) ->
        if notification in @notifications do
          {:ok, payload}
        else
          {:error, :invalid}
        end

      {:ok, _payload} ->
        {:error, :invalid}

      {:error, reason} ->
        {:error, reason}
    end
  end
end

defmodule Portal.Google.Webhooks do
  @moduledoc """
  Turns Google Directory API user push notifications into Oban jobs.

  Each notification carries the channel token the watch was created with in
  the `X-Goog-Channel-Token` header. Notifications whose token does not match
  the directory's `webhook_secret` are dropped.
  """

  alias Portal.Google
  alias __MODULE__.Database
  require Logger

  def handle_notification(directory_id, %{token: token, state: state}, body) do
    with {:ok, id} <- Ecto.UUID.cast(directory_id || ""),
         %Google.Directory{} = directory <- Database.get_directory(id),
         true <- authentic?(directory, token) do
      handle_state(directory, state, body)
    else
      false ->
        Logger.warning("Dropping Google notification with a missing or invalid channel token",
          google_directory_id: directory_id
        )

        :ok

      _ ->
        Logger.warning("Dropping Google notification for unknown directory",
          google_directory_id: directory_id
        )

        :ok
    end
  end

  defp authentic?(directory, token) when is_binary(token) do
    Plug.Crypto.secure_compare(token, directory.webhook_secret)
  end

  defp authentic?(_directory, _token), do: false

  defp handle_state(_directory, "sync", _body), do: :ok

  defp handle_state(directory, state, %{"id" => user_id}) when is_binary(user_id) do
    if in_scope?(directory, user_id) do
      {:ok, _job} =
        %{account_id: directory.account_id, directory_id: directory.id, user_id: user_id}
        |> Google.WebhookSync.new()
        |> Oban.insert()
    else
      Logger.debug("Ignoring Google notification for a user this directory does not track",
        google_directory_id: directory.id,
        state: state
      )
    end

    :ok
  end

  defp handle_state(directory, state, body) do
    Logger.info("Ignoring malformed Google notification",
      google_directory_id: directory.id,
      state: inspect(state),
      body: inspect(body)
    )

    :ok
  end

  # With org unit sync on, any user can gain an identity by sitting in a
  # tracked org unit, so every user event is worth a look. Otherwise only users
  # that already have an identity here matter.
  defp in_scope?(%{orgunit_sync_enabled: true}, _user_id), do: true

  defp in_scope?(directory, user_id) do
    Database.identity_exists?(directory, user_id)
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe

    def get_directory(id) do
      from(d in Portal.Google.Directory,
        join: a in Portal.Account,
        on: a.id == d.account_id,
        where: d.id == ^id,
        where: d.is_disabled == false,
        where: not is_nil(d.webhook_secret),
        where: a.is_disabled == false,
        where: fragment("(?)->>'idp_sync' = 'true'", a.features)
      )
      |> Safe.unscoped()
      |> Safe.one()
    end

    def identity_exists?(directory, idp_id) do
      issuer = Portal.Google.Sync.issuer()

      from(i in Portal.ExternalIdentity,
        where: i.account_id == ^directory.account_id,
        where: i.directory_id == ^directory.id,
        where: i.issuer == ^issuer,
        where: i.idp_id == ^idp_id
      )
      |> Safe.unscoped()
      |> Safe.exists?()
    end
  end
end

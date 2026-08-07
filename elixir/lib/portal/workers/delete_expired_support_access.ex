defmodule Portal.Workers.DeleteExpiredSupportAccess do
  @moduledoc """
  Deletes an account's expired Firezone Support auth provider and, once no
  active support provider remains, the account's support actors. Scheduled at
  the provider's expiry when support access is granted; the
  SweepExpiredSupportAccess cron worker enqueues it as a backstop.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete, keys: [:account_id, :auth_provider_id]]

  alias __MODULE__.Database

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"account_id" => account_id} = args}) do
    {:ok, result} = Database.delete_expired_support_access(account_id, args["auth_provider_id"])

    Logger.info("Deleted expired support access",
      account_id: account_id,
      providers: result.providers,
      actors: result.actors
    )

    :ok
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Actor
    alias Portal.AuthProvider
    alias Portal.FirezoneSupport
    alias Portal.Safe

    def delete_expired_support_access(account_id, auth_provider_id) do
      Safe.transact(fn ->
        {providers, _} = delete_expired_provider(account_id, auth_provider_id)

        {actors, _} =
          if active_provider_exists?(account_id) do
            {0, nil}
          else
            delete_support_actors(account_id)
          end

        {:ok, %{providers: providers, actors: actors}}
      end)
    end

    defp delete_expired_provider(_account_id, nil), do: {0, nil}

    defp delete_expired_provider(account_id, auth_provider_id) do
      expired_child =
        from(p in FirezoneSupport.AuthProvider,
          where: p.account_id == ^account_id,
          where: p.id == ^auth_provider_id,
          where: p.expires_at <= ^DateTime.utc_now(),
          select: p.id
        )

      from(ap in AuthProvider,
        where: ap.account_id == ^account_id,
        where: ap.type == :firezone_support,
        where: ap.id in subquery(expired_child)
      )
      |> Safe.unscoped()
      |> Safe.delete_all()
    end

    defp active_provider_exists?(account_id) do
      from(p in FirezoneSupport.AuthProvider,
        where: p.account_id == ^account_id,
        where: p.expires_at > ^DateTime.utc_now()
      )
      |> Safe.unscoped()
      |> Safe.exists?()
    end

    defp delete_support_actors(account_id) do
      from(a in Actor,
        where: a.account_id == ^account_id,
        where: a.type == :firezone_support
      )
      |> Safe.unscoped()
      |> Safe.delete_all()
    end
  end
end

defmodule Portal.Workers.SweepExpiredSupportAccess do
  @moduledoc """
  Cron backstop that enqueues DeleteExpiredSupportAccess for expired support
  providers whose scheduled job was lost, and for orphaned support actors whose
  provider is already gone.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  alias Portal.Workers.DeleteExpiredSupportAccess
  alias __MODULE__.Database

  @impl Oban.Worker
  def perform(_job) do
    Enum.each(Database.expired_providers(), fn {account_id, auth_provider_id} ->
      %{"account_id" => account_id, "auth_provider_id" => auth_provider_id}
      |> DeleteExpiredSupportAccess.new()
      |> Oban.insert()
    end)

    Enum.each(Database.orphaned_support_actor_account_ids(), fn account_id ->
      %{"account_id" => account_id, "auth_provider_id" => nil}
      |> DeleteExpiredSupportAccess.new()
      |> Oban.insert()
    end)

    :ok
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Actor
    alias Portal.FirezoneSupport
    alias Portal.Safe

    def expired_providers do
      from(p in FirezoneSupport.AuthProvider,
        where: p.expires_at <= ^DateTime.utc_now(),
        select: {p.account_id, p.id}
      )
      |> Safe.unscoped()
      |> Safe.all()
    end

    def orphaned_support_actor_account_ids do
      from(a in Actor,
        as: :actor,
        where: a.type == :firezone_support,
        where:
          not exists(
            from(p in FirezoneSupport.AuthProvider,
              where: p.account_id == parent_as(:actor).account_id,
              select: 1
            )
          ),
        select: a.account_id,
        distinct: true
      )
      |> Safe.unscoped()
      |> Safe.all()
    end
  end
end

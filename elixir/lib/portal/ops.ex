defmodule Portal.Ops do
  alias __MODULE__.Database
  alias Portal.Banner

  @doc """
  Counts presences grouped by topic prefix.

  Uses `Portal.Presence.list/1` to get the merged/deduplicated presence counts
  across all nodes in the cluster.

  ## Examples

      iex> count_presences()
      [
        {"presences:account_clients", 430},
        {"presences:account_gateways", 421},
        {"presences:actor_clients", 430},
        {"presences:global_relays", 34},
        {"presences:portal_sessions", 8},
        {"presences:sites", 421}
      ]

  """
  def count_presences do
    # Get unique topics from the ETS shard
    topics =
      :ets.tab2list(Portal.Presence_shard0)
      |> Enum.map(fn {{topic, _pid, _id}, _meta, _clock} -> topic end)
      |> Enum.uniq()

    # For each topic, get the merged presence count using Presence.list/1
    # which properly deduplicates entries across cluster nodes
    topics
    |> Enum.map(fn topic ->
      count = topic |> Portal.Presence.list() |> map_size()
      prefix = topic |> String.split(":") |> Enum.take(2) |> Enum.join(":")
      {prefix, count}
    end)
    |> Enum.group_by(fn {prefix, _count} -> prefix end, fn {_prefix, count} -> count end)
    |> Enum.map(fn {prefix, counts} -> {prefix, Enum.sum(counts)} end)
    |> Enum.sort()
  end

  def sync_pricing_plans do
    {:ok, subscriptions} = Portal.Billing.list_all_subscriptions()

    Enum.each(subscriptions, fn subscription ->
      %{
        "object" => "event",
        "data" => %{
          "object" => subscription
        },
        "type" => "customer.subscription.updated"
      }
      |> Portal.Billing.EventHandler.handle_event()
    end)
  end

  @doc """
  To delete an account you need to disable it first by cancelling its subscription in Stripe.
  """
  def delete_disabled_account(id) do
    Database.get_disabled_account!(id)
    |> Database.delete()

    :ok
  end

  def set_banner(message) do
    clear_banner()

    %Banner{}
    |> Banner.changeset(message: message)
    |> Database.insert()
  end

  def clear_banner do
    Database.delete_all(Banner)
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.{Account, Repo}

    def get_disabled_account!(id) do
      from(a in Account,
        where: a.id == ^id,
        where: not is_nil(a.disabled_at)
      )
      # credo:disable-for-next-line Credo.Check.Warning.RepoMissingSubject
      |> Repo.one!()
    end

    def insert(changeset) do
      # credo:disable-for-next-line Credo.Check.Warning.RepoMissingSubject
      Repo.insert(changeset)
    end

    def delete_all(schema) do
      from(s in schema)
      # credo:disable-for-next-line Credo.Check.Warning.RepoMissingSubject
      |> Repo.delete_all()
    end

    def delete(record) do
      # credo:disable-for-next-line Credo.Check.Warning.RepoMissingSubject
      Repo.delete(record)
    end
  end
end

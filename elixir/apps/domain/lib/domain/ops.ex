defmodule Domain.Ops do
  alias __MODULE__.DB
  alias Domain.Banner

  @doc """
  Counts presences grouped by topic prefix.

  ## Examples

      iex> count_presences()
      [
        {"presences:account_clients", 430},
        {"presences:account_gateways", 421},
        {"presences:actor_clients", 430},
        {"presences:global_relays", 34},
        {"presences:portal_sessions", 8},
        {"presences:relays", 34},
        {"presences:sites", 421}
      ]

  """
  def count_presences(shard \\ Domain.Presence_shard0) do
    :ets.tab2list(shard)
    |> Enum.group_by(fn {{topic, _pid, _id}, _meta, _clock} ->
      topic |> String.split(":") |> Enum.take(2) |> Enum.join(":")
    end)
    |> Enum.map(fn {topic_prefix, entries} -> {topic_prefix, length(entries)} end)
  end

  def sync_pricing_plans do
    {:ok, subscriptions} = Domain.Billing.list_all_subscriptions()

    Enum.each(subscriptions, fn subscription ->
      %{
        "object" => "event",
        "data" => %{
          "object" => subscription
        },
        "type" => "customer.subscription.updated"
      }
      |> Domain.Billing.EventHandler.handle_event()
    end)
  end

  @doc """
  To delete an account you need to disable it first by cancelling its subscription in Stripe.
  """
  def delete_disabled_account(id) do
    DB.get_disabled_account!(id)
    |> DB.delete()

    :ok
  end

  def set_banner(message) do
    clear_banner()

    %Banner{}
    |> Banner.changeset(message: message)
    |> DB.insert()
  end

  def clear_banner do
    DB.delete_all(Banner)
  end

  defmodule DB do
    import Ecto.Query
    alias Domain.{Account, Safe}

    def get_disabled_account!(id) do
      from(a in Account,
        where: a.id == ^id,
        where: not is_nil(a.disabled_at)
      )
      |> Safe.unscoped()
      |> Safe.one!()
    end

    def insert(changeset) do
      changeset
      |> Safe.unscoped()
      |> Safe.insert()
    end

    def delete_all(schema) do
      from(s in schema)
      |> Safe.unscoped()
      |> Safe.delete_all()
    end

    def delete(record) do
      record
      |> Safe.unscoped()
      |> Safe.delete()
    end
  end
end

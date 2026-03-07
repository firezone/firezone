defmodule Portal.Ops do
  alias __MODULE__.Database
  alias Portal.{Banner, Mailer}

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

    %Banner{message: message}
    |> Database.insert()
  end

  def clear_banner do
    Database.delete_all(Banner)
  end

  def queue_admin_email(subject, html_body, plaintext_body) do
    queue_admin_email(:all, subject, html_body, plaintext_body)
  end

  def queue_admin_email(account_ids, subject, html_body, plaintext_body)
      when account_ids == :all or is_list(account_ids) do
    Database.get_account_admin_emails_by_account(account_ids)
    |> Enum.each(fn {account_id, admin_emails} ->
      if admin_emails != [] do
        Mailer.default_email()
        |> Swoosh.Email.subject(subject)
        |> Mailer.bcc_recipients(admin_emails)
        |> Swoosh.Email.html_body(html_body)
        |> Swoosh.Email.text_body(plaintext_body)
        |> Mailer.with_account_id(account_id)
        |> Mailer.enqueue()
      end
    end)

    :ok
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.{Account, Actor, Safe}

    def get_disabled_account!(id) do
      from(a in Account,
        where: a.id == ^id,
        where: not is_nil(a.disabled_at)
      )
      |> Safe.unscoped(:replica)
      |> Safe.one!()
    end

    def insert(banner) do
      banner
      |> Safe.unscoped()
      |> Safe.insert()
    end

    def delete_all(schema) do
      from(s in schema)
      |> Safe.unscoped()
      |> Safe.delete_all()
    end

    def delete(banner) do
      banner
      |> Safe.unscoped()
      |> Safe.delete()
    end

    def get_account_admin_emails_by_account(account_ids_or_all) do
      Actor
      |> where([a], a.type == :account_admin_user)
      |> where([a], is_nil(a.disabled_at))
      |> maybe_filter_account_ids(account_ids_or_all)
      |> select([a], {a.account_id, a.email})
      |> Safe.unscoped(:replica)
      |> Safe.all()
      |> Enum.group_by(fn {account_id, _email} -> account_id end, fn {_account_id, email} ->
        email
      end)
    end

    defp maybe_filter_account_ids(query, :all) do
      join(query, :inner, [a], account in Account,
        on: account.id == a.account_id and is_nil(account.disabled_at)
      )
    end

    defp maybe_filter_account_ids(query, account_ids) when is_list(account_ids) do
      where(query, [a], a.account_id in ^account_ids)
    end
  end
end

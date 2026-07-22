defmodule Portal.Ops do
  alias __MODULE__.Database
  alias Portal.{Banner, EmailSuppression, Mailer}
  alias Portal.Workers.DeleteAccount

  @max_bcc_per_message 50
  @max_recipients_per_send_window 100
  @send_window_seconds 5 * 60

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
      # id/created satisfy the ProcessedEvents checks; created=now also makes
      # stale webhook events delivered after the sync get skipped as :old_event
      %{
        "id" => "evt_sync_" <> Ecto.UUID.generate(),
        "object" => "event",
        "created" => System.os_time(:second),
        "livemode" => Map.get(subscription, "livemode", false),
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

  @doc """
  Enqueues account deletion jobs for accounts that are already scheduled for deletion.

  This is intended for operational use during the migration from the old daily deletion
  scanner to one scheduled Oban job per account.
  """
  def schedule_missing_account_deletion_jobs do
    Database.accounts_missing_deletion_jobs()
    |> Enum.reduce_while({:ok, 0}, fn account, {:ok, count} ->
      job = DeleteAccount.new(%{"account_id" => account.id}, scheduled_at: account.scheduled_deletion_at)

      case Oban.insert(job) do
        {:ok, %Oban.Job{conflict?: true}} -> {:cont, {:ok, count}}
        {:ok, _job} -> {:cont, {:ok, count + 1}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc"""
  Set a banner for all accounts. Banners can render HTML tags.
  The available colors are: :warning, :info, :error, :success, :announcement
  """
  def set_banner(message, color \\ :announcement) do
    clear_banner()

    %Banner{message: message, color: color}
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
    emails_by_account =
      Database.get_account_admin_emails_by_account(account_ids)
      |> Enum.map(fn {account_id, admin_emails} ->
        normalized =
          admin_emails
          |> Enum.map(&EmailSuppression.normalize_email/1)
          |> Enum.uniq()

        {account_id, normalized}
      end)
      |> Enum.reject(fn {_account_id, emails} -> emails == [] end)

    total_recipients = Enum.sum(Enum.map(emails_by_account, fn {_, emails} -> length(emails) end))
    total_accounts = length(emails_by_account)

    if total_recipients == 0 do
      IO.puts("No admin recipients found.")
      :ok
    else
      IO.puts(
        "About to send email '#{subject}' to #{total_recipients} unique admin(s) across #{total_accounts} account(s). Continue? [y/N]"
      )

      case IO.gets("") |> String.trim() do
        answer when answer in ["y", "Y"] ->
          enqueue_chunked(emails_by_account, subject, html_body, plaintext_body)

        _ ->
          IO.puts("Aborted.")
          :aborted
      end
    end
  end

  defp enqueue_chunked(emails_by_account, subject, html_body, plaintext_body) do
    first_send_at = DateTime.utc_now()

    emails_by_account
    |> Enum.flat_map(fn {account_id, admin_emails} ->
      Enum.map(admin_emails, &{account_id, &1})
    end)
    |> Enum.chunk_every(@max_recipients_per_send_window)
    |> Enum.with_index()
    |> Enum.each(fn {send_window, window_index} ->
      job_opts = send_window_job_opts(first_send_at, window_index)

      send_window
      |> Enum.group_by(fn {account_id, _email} -> account_id end, fn {_account_id, email} ->
        email
      end)
      |> Enum.each(fn {account_id, admin_emails} ->
        admin_emails
        |> Enum.chunk_every(@max_bcc_per_message)
        |> Enum.each(fn chunk ->
          Mailer.default_email()
          |> Swoosh.Email.subject(subject)
          |> Mailer.bcc_recipients(chunk)
          |> Swoosh.Email.html_body(html_body)
          |> Swoosh.Email.text_body(plaintext_body)
          |> Mailer.with_account_id(account_id)
          |> Mailer.enqueue(job_opts)
        end)
      end)
    end)

    :ok
  end

  defp send_window_job_opts(_first_send_at, 0), do: []

  defp send_window_job_opts(first_send_at, window_index) do
    scheduled_at = DateTime.add(first_send_at, window_index * @send_window_seconds, :second)
    [scheduled_at: scheduled_at]
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

    def accounts_missing_deletion_jobs do
      delete_jobs_query =
        [worker: Portal.Workers.DeleteAccount, state: Oban.Job.unique_states(:incomplete)]
        |> Oban.Job.query()
        |> where([j], fragment("?->>'account_id' = ?::text", j.args, parent_as(:account).id))
        |> select([j], 1)

      from(a in Account,
        as: :account,
        where: not is_nil(a.disabled_at),
        where: not is_nil(a.scheduled_deletion_at),
        where: not exists(delete_jobs_query)
      )
      |> Safe.unscoped()
      |> Safe.all()
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

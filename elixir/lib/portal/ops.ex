defmodule Portal.Ops do
  alias __MODULE__.Database
  alias Portal.{Banner, Billing, EmailSuppression, Mailer}
  alias Portal.Workers.DeleteAccount

  @max_bcc_per_message 50
  @max_recipients_per_send_window 100
  @send_window_seconds 5 * 60

  @doc """
  Counts cluster-wide presences grouped by topic prefix.

  Uses `Portal.Presence.list/1` to get the merged/deduplicated presence counts
  across all nodes in the cluster.

  ## Examples

      iex> count_global_presences()
      [
        {"presences:account_devices", 851},
        {"presences:relays", 34},
        {"presences:portal_sessions", 8}
      ]

  """
  def count_global_presences do
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
    |> sum_presence_counts()
  end

  @doc """
  Counts presences hosted by the current node, grouped by topic prefix.

  Presence keys are deduplicated within each topic to match the semantics of
  `count_global_presences/0`.

  ## Examples

      iex> count_local_presences()
      [
        {"presences:account_devices", 425},
        {"presences:relays", 17},
        {"presences:portal_sessions", 4}
      ]

  """
  def count_local_presences do
    count_presences_on_nodes([node()])
  end

  @doc """
  Counts presences hosted by nodes in `region`, grouped by topic prefix.

  The region is read from each connected node's runtime configuration.

  ## Examples

      iex> count_regional_presences("centralus")
      [
        {"presences:account_devices", 425},
        {"presences:relays", 17},
        {"presences:portal_sessions", 4}
      ]

  """
  def count_regional_presences(region) when is_binary(region) do
    nodes =
      [node() | Node.list()]
      |> Enum.filter(&(node_region(&1) == region))

    count_presences_on_nodes(nodes)
  end

  defp count_presences_on_nodes(nodes) do
    nodes = MapSet.new(nodes)

    Portal.Presence_shard0
    |> :ets.tab2list()
    |> Enum.filter(fn {{_topic, pid, _id}, _meta, _clock} ->
      MapSet.member?(nodes, node(pid))
    end)
    |> Enum.map(fn {{topic, _pid, id}, _meta, _clock} -> {topic, id} end)
    |> Enum.uniq()
    |> Enum.map(fn {topic, _id} ->
      prefix = topic |> String.split(":") |> Enum.take(2) |> Enum.join(":")
      {prefix, 1}
    end)
    |> sum_presence_counts()
  end

  defp node_region(node) do
    if node == node() do
      Portal.Config.get_env(:portal, :region)
    else
      case :rpc.call(node, Portal.Config, :get_env, [:portal, :region], 1_000) do
        {:badrpc, _reason} -> nil
        region -> region
      end
    end
  end

  defp sum_presence_counts(presences) do
    presences
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
    {emails_by_account, dormant} =
      Database.get_account_admin_emails_by_account(account_ids)
      |> Enum.map(fn {account_id, admin_emails} ->
        normalized =
          admin_emails
          |> Enum.map(&EmailSuppression.normalize_email/1)
          |> Enum.uniq()

        {account_id, normalized}
      end)
      |> Enum.reject(fn {_account_id, emails} -> emails == [] end)
      |> split_dormant_accounts()

    total_recipients = Enum.sum(Enum.map(emails_by_account, fn {_, emails} -> length(emails) end))
    total_accounts = length(emails_by_account)

    if dormant != [] do
      IO.puts("Skipping #{length(dormant)} dormant account(s) with no sessions on record.")
    end

    if total_recipients == 0 do
      IO.puts("No admin recipients found.")
      {:error, :no_recipients}
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

  defp split_dormant_accounts(emails_by_account) do
    {paid, unpaid} =
      emails_by_account
      |> Enum.map(&elem(&1, 0))
      |> Database.list_accounts()
      |> Enum.split_with(&Billing.paid_plan?/1)

    notifiable_ids =
      unpaid
      |> Enum.map(& &1.id)
      |> Database.active_account_ids()
      |> Enum.concat(Enum.map(paid, & &1.id))
      |> MapSet.new()

    Enum.split_with(emails_by_account, fn {account_id, _emails} ->
      MapSet.member?(notifiable_ids, account_id)
    end)
  end

  defp enqueue_chunked(emails_by_account, subject, html_body, plaintext_body) do
    first_send_at = DateTime.utc_now()

    emails_by_account
    |> account_send_windows()
    |> Enum.with_index()
    |> Enum.each(&enqueue_send_window(&1, first_send_at, subject, html_body, plaintext_body))

    :ok
  end

  defp account_send_windows([]), do: []

  defp account_send_windows(emails_by_account) do
    {completed_windows, current_window, _recipient_count} =
      Enum.reduce(emails_by_account, {[], [], 0}, &add_account_to_send_window/2)

    Enum.reverse([Enum.reverse(current_window) | completed_windows])
  end

  defp add_account_to_send_window(
         {_account_id, admin_emails} = account,
         {completed_windows, current_window, recipient_count}
       ) do
    account_recipient_count = length(admin_emails)

    # Keep every admin for an account in the same window. An account larger
    # than the target window size gets a window to itself.
    if current_window == [] or
         recipient_count + account_recipient_count <= @max_recipients_per_send_window do
      {completed_windows, [account | current_window], recipient_count + account_recipient_count}
    else
      {[Enum.reverse(current_window) | completed_windows], [account], account_recipient_count}
    end
  end

  defp enqueue_send_window(
         {send_window, window_index},
         first_send_at,
         subject,
         html_body,
         plaintext_body
       ) do
    job_opts = send_window_job_opts(first_send_at, window_index)

    Enum.each(
      send_window,
      &enqueue_account_emails(&1, subject, html_body, plaintext_body, job_opts)
    )
  end

  defp enqueue_account_emails(
         {account_id, admin_emails},
         subject,
         html_body,
         plaintext_body,
         job_opts
       ) do
    admin_emails
    |> Enum.chunk_every(@max_bcc_per_message)
    |> Enum.each(&enqueue_admin_email(&1, account_id, subject, html_body, plaintext_body, job_opts))
  end

  defp enqueue_admin_email(
         recipients,
         account_id,
         subject,
         html_body,
         plaintext_body,
         job_opts
       ) do
    Mailer.default_email()
    |> Swoosh.Email.subject(subject)
    |> Mailer.bcc_recipients(recipients)
    |> Swoosh.Email.html_body(html_body)
    |> Swoosh.Email.text_body(plaintext_body)
    |> Mailer.with_account_id(account_id)
    |> Mailer.enqueue(job_opts)
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
        where: a.is_disabled == true
      )
      |> Safe.unscoped()
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
      |> where([a], a.is_disabled == false)
      |> maybe_filter_account_ids(account_ids_or_all)
      |> select([a], {a.account_id, a.email})
      |> Safe.unscoped()
      |> Safe.all()
      |> Enum.group_by(fn {account_id, _email} -> account_id end, fn {_account_id, email} ->
        email
      end)
    end

    def list_accounts(account_ids) do
      from(a in Account, where: a.id in ^account_ids)
      |> Safe.unscoped()
      |> Safe.all()
    end

    def active_account_ids([]), do: []

    def active_account_ids(account_ids) do
      from(a in Account, as: :accounts)
      |> where([accounts: a], a.id in ^account_ids)
      |> where(
        [accounts: a],
        exists(
          from(sl in Portal.SessionLog,
            where: sl.account_id == parent_as(:accounts).id,
            select: 1
          )
        )
      )
      |> select([accounts: a], a.id)
      |> Safe.unscoped()
      |> Safe.all()
    end

    def accounts_missing_deletion_jobs do
      delete_jobs_query =
        [worker: Portal.Workers.DeleteAccount, state: Oban.Job.unique_states(:incomplete)]
        |> Oban.Job.query()
        |> where([j], fragment("?->>'account_id' = ?::text", j.args, parent_as(:account).id))
        |> select([j], 1)

      from(a in Account,
        as: :account,
        where: a.is_disabled == true,
        where: not is_nil(a.scheduled_deletion_at),
        where: not exists(delete_jobs_query)
      )
      |> Safe.unscoped()
      |> Safe.all()
    end

    defp maybe_filter_account_ids(query, :all) do
      join(query, :inner, [a], account in Account,
        on: account.id == a.account_id and account.is_disabled == false
      )
    end

    defp maybe_filter_account_ids(query, account_ids) when is_list(account_ids) do
      where(query, [a], a.account_id in ^account_ids)
    end
  end
end

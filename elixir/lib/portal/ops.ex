defmodule Portal.Ops do
  alias __MODULE__.Database
  alias Portal.{Banner, Billing, EmailSuppression, Mailer, SlugRegistry}
  alias Portal.Workers.DeleteAccount
  alias Portal.Ops.AuthProviderNotices

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
  Deletes a disabled account at once and queues the cancellation of its Stripe subscriptions.
  """
  def delete_disabled_account(id) do
    {:ok, _account} = Database.delete_disabled_account(id)
    :ok
  end

  @doc """
  Claims every local account slug in the shared slug registry.

  Run this once per region when the registry goes live, and again if the
  registry table is ever lost. A slug that another account already holds in
  the registry is printed and skipped.
  """
  def backfill_slug_registry do
    if SlugRegistry.adapter() == SlugRegistry.Local do
      IO.puts("SLUG_REGISTRY_TABLE_URL is not set, so there is no registry to fill.")
      {:error, :no_registry}
    else
      slugs = Database.list_account_slugs()

      IO.puts(
        "About to claim #{length(slugs)} slug(s) for region #{SlugRegistry.region()} in the slug registry. Continue? [y/N]"
      )

      case IO.gets("") do
        answer when answer in ["y\n", "Y\n"] ->
          claim_slugs(slugs)

        _ ->
          IO.puts("Aborted.")
          :aborted
      end
    end
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

  @doc """
  Sets the Relay throughput limit of each account on a known plan that has no
  limit yet to the value its plan has in Stripe.

  Run this once after the Relay throughput limits ship, then remove it.
  """
  def backfill_relay_throughput_limits do
    Database.accounts_missing_relay_throughput_limit()
    |> Enum.group_by(&plan_relay_throughput_mbps(Billing.plan_type(&1)), & &1.id)
    |> Map.delete(nil)
    |> Enum.reduce({:ok, 0}, fn {mbps, account_ids}, {:ok, count} ->
      {updated, _} = Database.set_relay_throughput_limit(account_ids, mbps)
      {:ok, count + updated}
    end)
  end

  @doc """
  Sets the Relay allocation limit of each account on a known plan that has no
  limit yet to the value its plan has in Stripe.

  Run this once after the Relay allocation limits ship, then remove it.
  """
  def backfill_relay_allocation_limits do
    Database.accounts_missing_relay_allocation_limit()
    |> Enum.group_by(&plan_relay_allocations_count(Billing.plan_type(&1)), & &1.id)
    |> Map.delete(nil)
    |> Enum.reduce({:ok, 0}, fn {count_limit, account_ids}, {:ok, count} ->
      {updated, _} = Database.set_relay_allocation_limit(account_ids, count_limit)
      {:ok, count + updated}
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

  @doc """
  Queues the one-off Entra tenant notice for accounts with enabled users whose
  stored Entra tenants are missing from every enabled Entra provider.

  Rechecks current providers and active admins, shows recipients, and prompts
  once before queuing. Uses the standard dormant-account and batching rules.
  Call after deploying the verified-tenant UI. This function is not idempotent.

  Pass account IDs to notify a subset instead of all qualifying accounts.

      Portal.Ops.notify_entra_auth_provider_admins()
      Portal.Ops.notify_entra_auth_provider_admins([account_id])
  """
  def notify_entra_auth_provider_admins(account_ids \\ :all)
      when account_ids == :all or is_list(account_ids) do
    Database.entra_auth_provider_notices(account_ids)
    |> queue_auth_provider_notices(:entra)
  end

  @doc """
  Queues the one-off Google domain-validation notice for unrestricted, enabled
  Google providers with enabled users whose Google identity email domains are
  outside the known consumer-domain exclusions.

  Rechecks current providers and active admins, shows recipients, and prompts
  once before queuing. Existing providers are not modified. Uses the standard
  dormant-account and batching rules. Call after deploying the updated Google
  verification UI. This function is not idempotent.

      Portal.Ops.notify_google_auth_provider_admins()
      Portal.Ops.notify_google_auth_provider_admins([account_id])
  """
  def notify_google_auth_provider_admins(account_ids \\ :all)
      when account_ids == :all or is_list(account_ids) do
    Database.google_auth_provider_notices(account_ids)
    |> queue_auth_provider_notices(:google)
  end

  defp queue_auth_provider_notices(notices, provider) do
    notices_by_account = Map.new(notices, &{&1.account_id, &1})

    {emails_by_account, dormant} =
      notices_by_account
      |> Map.keys()
      |> Database.get_account_admin_emails_by_account()
      |> Enum.map(fn {account_id, emails} ->
        {account_id, emails |> Enum.map(&EmailSuppression.normalize_email/1) |> Enum.uniq() |> Enum.sort()}
      end)
      |> Enum.reject(fn {_account_id, emails} -> emails == [] end)
      |> split_dormant_accounts()

    emails_by_account = Enum.sort_by(emails_by_account, fn {id, _} -> notices_by_account[id].slug end)

    if dormant != [] do
      IO.puts("Skipping #{length(dormant)} dormant account(s) with no sessions on record.")
    end

    confirm_auth_provider_notices(emails_by_account, notices_by_account, provider)
  end

  defp confirm_auth_provider_notices([], _notices, _provider) do
    IO.puts("No admin recipients found.")
    {:error, :no_recipients}
  end

  defp confirm_auth_provider_notices(emails_by_account, notices, provider) do
    Enum.each(emails_by_account, fn {id, emails} ->
      notice = Map.fetch!(notices, id)
      IO.puts("#{notice.name} (#{notice.slug}): #{Enum.join(emails, ", ")}")
    end)

    count = Enum.sum(Enum.map(emails_by_account, fn {_, emails} -> length(emails) end))
    IO.puts("About to queue #{provider} notices for #{count} admin recipient(s) across #{length(emails_by_account)} account(s). Continue? [y/N]")

    case IO.gets("") do
      answer when answer in ["y\n", "Y\n"] ->
        enqueue_auth_provider_notices(emails_by_account, notices, provider)
      _ ->
        IO.puts("Aborted.")
        :aborted
    end
  end

  defp enqueue_auth_provider_notices(emails_by_account, notices, provider) do
    first_send_at = DateTime.utc_now()

    emails_by_account
    |> account_send_windows()
    |> Enum.with_index()
    |> Enum.each(fn {window, index} ->
      opts = send_window_job_opts(first_send_at, index)
      Enum.each(window, fn {account_id, emails} ->
        email = AuthProviderNotices.email(provider, Map.fetch!(notices, account_id))
        enqueue_auth_provider_notice(email, emails, opts)
      end)
    end)

    :ok
  end

  defp enqueue_auth_provider_notice(email, recipients, job_opts) do
    recipients
    |> Enum.chunk_every(@max_bcc_per_message)
    |> Enum.each(fn chunk ->
      email
      |> Mailer.bcc_recipients(chunk)
      |> Mailer.enqueue(job_opts)
    end)
  end

  @doc """
  Queues the monthly product announcement for every admin who has not turned
  product announcements off in their settings.

  `html_body` is placed as it is inside the usual email layout, between the
  logo and the sign-off, so it must be trusted HTML. `text_body` is the plain
  text version of the same content. Each email gets its own link to turn
  product announcements off.

  A person who is an admin of more than one account gets the email once.
  Accounts on a free plan with no sessions on record are skipped.

  ## Examples

      iex> html = File.read!("/tmp/2026-11.html")
      iex> text = File.read!("/tmp/2026-11.txt")
      iex> queue_product_announcement("What's new in Firezone: November 2026", html, text)

  """
  def queue_product_announcement(subject, html_body, text_body) do
    queue_product_announcement(:all, subject, html_body, text_body)
  end

  def queue_product_announcement(account_ids, subject, html_body, text_body)
      when account_ids == :all or is_list(account_ids) do
    {actors_by_account, dormant} =
      account_ids
      |> Database.product_announcement_recipients()
      |> Enum.group_by(& &1.account_id)
      |> Enum.to_list()
      |> split_dormant_accounts()

    recipients =
      actors_by_account
      |> Enum.flat_map(fn {_account_id, actors} -> actors end)
      |> Enum.sort_by(& &1.inserted_at, DateTime)
      |> Enum.uniq_by(&EmailSuppression.normalize_email(&1.email))

    if dormant != [] do
      IO.puts("Skipping #{length(dormant)} dormant account(s) with no sessions on record.")
    end

    if recipients == [] do
      IO.puts("No admin recipients found.")
      {:error, :no_recipients}
    else
      recipients_by_account = recipients |> Enum.group_by(& &1.account_id) |> Enum.to_list()

      IO.puts(
        "About to send product announcement '#{subject}' to #{length(recipients)} unique admin(s) across #{length(recipients_by_account)} account(s). Continue? [y/N]"
      )

      case IO.gets("") |> String.trim() do
        answer when answer in ["y", "Y"] ->
          enqueue_product_announcement(recipients_by_account, subject, html_body, text_body)

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

  defp enqueue_product_announcement(recipients_by_account, subject, html_body, text_body) do
    first_send_at = DateTime.utc_now()

    recipients_by_account
    |> account_send_windows()
    |> Enum.with_index()
    |> Enum.each(fn {send_window, window_index} ->
      job_opts = send_window_job_opts(first_send_at, window_index)

      for {_account_id, actors} <- send_window, actor <- actors do
        enqueue_product_announcement_email(actor, subject, html_body, text_body, job_opts)
      end
    end)

    :ok
  end

  defp enqueue_product_announcement_email(actor, subject, html_body, text_body, job_opts) do
    Mailer.Notifications.product_announcement_email(subject, html_body, text_body, actor)
    |> Mailer.enqueue(job_opts)
  end

  defp send_window_job_opts(_first_send_at, 0), do: []

  defp send_window_job_opts(first_send_at, window_index) do
    scheduled_at = DateTime.add(first_send_at, window_index * @send_window_seconds, :second)
    [scheduled_at: scheduled_at]
  end

  defp claim_slugs(slugs) do
    slugs
    |> Enum.reduce_while({:ok, 0}, fn %{slug: slug, account_id: account_id}, {:ok, count} ->
      case SlugRegistry.claim(slug, account_id) do
        :ok ->
          {:cont, {:ok, count + 1}}

        {:error, :taken} ->
          IO.puts("#{slug}: another account holds this slug in the registry, skipped (account #{account_id})")
          {:cont, {:ok, count}}

        {:error, :unavailable} ->
          {:halt, {:error, :slug_registry_unavailable}}
      end
    end)
    |> case do
      {:ok, count} ->
        IO.puts("Claimed #{count} slug(s).")
        {:ok, count}

      {:error, :slug_registry_unavailable} = error ->
        IO.puts("The slug registry is unavailable. Fix it and run again.")
        error
    end
  end

  defp plan_relay_throughput_mbps(:starter), do: 5
  defp plan_relay_throughput_mbps(:team), do: 15
  defp plan_relay_throughput_mbps(:business), do: 25
  defp plan_relay_throughput_mbps(:enterprise), do: 50
  defp plan_relay_throughput_mbps(:unknown), do: nil

  defp plan_relay_allocations_count(:starter), do: 64
  defp plan_relay_allocations_count(:team), do: 1024
  defp plan_relay_allocations_count(:business), do: 2048
  defp plan_relay_allocations_count(_plan), do: nil

  defmodule Database do
    import Ecto.Query
    alias Portal.{Account, Actor, ExternalIdentity, Safe}
    alias Portal.Workers.DeleteSubscription

    def delete_disabled_account(id) do
      Safe.transact(fn ->
        account =
          from(a in Account,
            where: a.id == ^id,
            where: a.is_disabled == true
          )
          |> Safe.unscoped()
          |> Safe.one!()

        with {:ok, account} <- account |> Safe.unscoped() |> Safe.delete(),
             {:ok, _job} <- maybe_insert_delete_subscription_job(account) do
          {:ok, account}
        end
      end)
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

    # Temporary selectors for the verified-organization rollout notices.
    @google_issuers ["https://accounts.google.com", "accounts.google.com"]
    @consumer_domains ~w[gmail.com googlemail.com hotmail.com outlook.com yahoo.com icloud.com qq.com]
    @entra_issuer_pattern "^https://login[.]microsoftonline[.]com/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/v2[.]0$"

    def entra_auth_provider_notices(account_ids) do
      from(a in Account,
        as: :accounts,
        join: i in ExternalIdentity, as: :identities, on: i.account_id == a.id,
        join: u in Actor, on: u.account_id == a.id and u.id == i.actor_id,
        where: a.is_disabled == false and is_nil(a.scheduled_deletion_at),
        where: u.is_disabled == false and u.type in [:account_admin_user, :account_user],
        where: fragment("? ~ ?", i.issuer, ^@entra_issuer_pattern),
        where: exists(from(p in Portal.Entra.AuthProvider,
          where: p.account_id == parent_as(:accounts).id and p.is_disabled == false,
          select: 1)),
        where: not exists(from(p in Portal.Entra.AuthProvider,
          where: p.account_id == parent_as(:accounts).id and p.is_disabled == false,
          where: fragment("lower(split_part(?, '/', 4)) = ANY(SELECT unnest(?)::text)",
            parent_as(:identities).issuer, p.tenant_ids),
          select: 1)),
        select: %{account_id: a.id, name: a.name, slug: a.slug,
          tenant_id: fragment("lower(split_part(?, '/', 4))", i.issuer),
          domain: fragment("lower(split_part(btrim(?::text), '@', 2))", i.email)}
      )
      |> filter_notice_accounts(account_ids)
      |> Safe.unscoped()
      |> Safe.all()
      |> Enum.group_by(&{&1.account_id, &1.name, &1.slug})
      |> Enum.map(fn {{account_id, name, slug}, rows} ->
        tenants = rows |> Enum.group_by(& &1.tenant_id)
          |> Enum.map(fn {id, identities} ->
            %{id: id, domains: identities |> Enum.map(& &1.domain) |> Enum.reject(&(&1 in [nil, ""])) |> Enum.uniq() |> Enum.sort()}
          end)
          |> Enum.sort_by(& &1.id)
        %{account_id: account_id, name: name, slug: slug, tenants: tenants}
      end)
    end

    def google_auth_provider_notices(account_ids) do
      from(a in Account,
        as: :accounts,
        join: p in Portal.Google.AuthProvider, on: p.account_id == a.id,
        join: i in ExternalIdentity, on: i.account_id == a.id,
        join: u in Actor, on: u.account_id == a.id and u.id == i.actor_id,
        where: a.is_disabled == false and is_nil(a.scheduled_deletion_at),
        where: p.is_disabled == false and is_nil(p.workspace_domains) and p.is_legacy_unrestricted == true,
        where: u.is_disabled == false and u.type in [:account_admin_user, :account_user],
        where: i.issuer in ^@google_issuers and not is_nil(i.email),
        where: fragment("position('@' in ?::text) > 1", i.email),
        where: fragment("split_part(btrim(?::text), '@', 2) <> ''", i.email),
        group_by: [a.id, a.name, a.slug],
        having: filter(count(i.id), fragment("lower(split_part(btrim(?::text), '@', 2))", i.email) not in ^@consumer_domains) > 0,
        select: %{account_id: a.id, name: a.name, slug: a.slug,
          domains: fragment("array_agg(DISTINCT lower(split_part(btrim(?::text), '@', 2)))", i.email),
          consumer_identity_count: filter(count(i.id), fragment("lower(split_part(btrim(?::text), '@', 2))", i.email) in ^@consumer_domains)}
      )
      |> filter_notice_accounts(account_ids)
      |> Safe.unscoped()
      |> Safe.all()
      |> Enum.map(fn notice ->
        Map.update!(notice, :domains, fn domains ->
          domains |> Enum.reject(&(&1 in @consumer_domains)) |> Enum.sort()
        end)
      end)
    end

    defp filter_notice_accounts(query, :all), do: query
    defp filter_notice_accounts(query, ids), do: where(query, [accounts: a], a.id in ^ids)

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

    def product_announcement_recipients(account_ids_or_all) do
      from(a in Actor,
        where: a.type == :account_admin_user,
        where: a.is_disabled == false,
        where:
          fragment(
            "COALESCE(NULLIF(?->'notifications'->'product_announcements', 'null') @> '[\"email\"]', true)",
            a.preferences
          )
      )
      |> maybe_filter_account_ids(account_ids_or_all)
      |> Safe.unscoped()
      |> Safe.all()
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

    def list_account_slugs do
      from(s in Portal.AccountSlug, select: %{slug: s.slug, account_id: s.account_id}, order_by: s.slug)
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

    def accounts_missing_relay_throughput_limit do
      from(a in Account, where: is_nil(fragment("?->>'relay_throughput_mbps'", a.limits)))
      |> Safe.unscoped()
      |> Safe.all()
    end

    def set_relay_throughput_limit(account_ids, mbps) do
      from(a in Account,
        where: a.id in ^account_ids,
        where: is_nil(fragment("?->>'relay_throughput_mbps'", a.limits)),
        update: [
          set: [
            limits:
              fragment(
                "COALESCE(?, '{}'::jsonb) || jsonb_build_object('relay_throughput_mbps', ?::integer)",
                a.limits,
                ^mbps
              )
          ]
        ]
      )
      |> Safe.unscoped()
      |> Safe.update_all([])
    end

    def accounts_missing_relay_allocation_limit do
      from(a in Account, where: is_nil(fragment("?->>'relay_allocations_count'", a.limits)))
      |> Safe.unscoped()
      |> Safe.all()
    end

    def set_relay_allocation_limit(account_ids, limit) do
      from(a in Account,
        where: a.id in ^account_ids,
        where: is_nil(fragment("?->>'relay_allocations_count'", a.limits)),
        update: [
          set: [
            limits:
              fragment(
                "COALESCE(?, '{}'::jsonb) || jsonb_build_object('relay_allocations_count', ?::integer)",
                a.limits,
                ^limit
              )
          ]
        ]
      )
      |> Safe.unscoped()
      |> Safe.update_all([])
    end

    defp maybe_filter_account_ids(query, :all) do
      join(query, :inner, [a], account in Account,
        on: account.id == a.account_id and account.is_disabled == false
      )
    end

    defp maybe_filter_account_ids(query, account_ids) when is_list(account_ids) do
      where(query, [a], a.account_id in ^account_ids)
    end

    defp maybe_insert_delete_subscription_job(%Account{} = account) do
      customer_id =
        get_in(account, [Access.key(:metadata), Access.key(:stripe), Access.key(:customer_id)])

      if customer_id do
        %{"customer_id" => customer_id}
        |> DeleteSubscription.new()
        |> Oban.insert()
      else
        {:ok, nil}
      end
    end
  end
end

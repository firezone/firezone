defmodule Portal.Mailer do
  alias Swoosh.Mailer
  alias Swoosh.Email
  alias Portal.EmailSuppression
  alias Portal.Mailer.RateLimiter
  alias Portal.Workers.OutboundEmail, as: OutboundEmailWorker
  alias __MODULE__.Database
  require Logger

  # Email addresses ending in any of these suffixes are non-deliverable and are
  # dropped from every recipient field before delivery.
  @blocked_suffixes ["@firezone.invalid"]

  def deliver_with_rate_limit(email, config \\ []) do
    {key, config} = Keyword.pop(config, :rate_limit_key, {email.to, email.subject})

    {rate_limit, config} = Keyword.pop(config, :rate_limit, 10)
    {rate_limit_interval, config} = Keyword.pop(config, :rate_limit_interval, :timer.minutes(2))

    RateLimiter.rate_limit(key, rate_limit, rate_limit_interval, fn ->
      # Tracking depends on the message id ACS returns and the ACS Event Grid
      # delivery webhooks; revert by pointing the adapter env var elsewhere.
      if effective_adapter(config) == Swoosh.Adapters.AzureCommunicationServices do
        deliver_and_track(email, config)
      else
        deliver(email, config)
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Delivers an email via configured Swoosh adapter.

  If adapter is not configured or is set to nil, the delivery will be ignored and
  function will return `{:ok, %{}}`.

  Notice: this code is copied from `Swoosh.Mailer.deliver/2` and modified to
  not send emails if adapter is not configured. This is needed to avoid
  custom adapter implementation that does nothing.
  """
  def deliver(email, config \\ []) do
    opts = Mailer.parse_config(:portal, __MODULE__, [], config)
    metadata = %{email: email, config: config, mailer: __MODULE__}

    deliver_with_mailer_config(email, opts, metadata)
  end

  @doc """
  Delivers an email synchronously and, on success, inserts a tracked row when
  the adapter returns a message id (ACS). Used by the primary mailer call sites
  so delivery report webhooks can update those messages too.
  """
  def deliver_and_track(email, config \\ []) do
    # Filter before delivering so the tracked rows only contain recipients the
    # message was actually sent to.
    email = email |> drop_blocked_recipients() |> drop_suppressed_recipients()

    case deliver(email, config) do
      {:ok, result} = ok ->
        maybe_insert_tracked(email, result)
        ok

      {:error, _reason} = error ->
        error
    end
  end

  def deliver_secondary(email, config \\ []) do
    opts =
      Portal.Config.fetch_env!(:portal, Portal.Mailer.Secondary)
      |> Keyword.merge(config)

    metadata = %{email: email, config: config, mailer: Portal.Mailer.Secondary}

    deliver_with_mailer_config(email, opts, metadata)
  end

  defp deliver_with_mailer_config(email, opts, metadata) do
    if opts[:adapter] do
      email = email |> drop_blocked_recipients() |> drop_suppressed_recipients()

      if has_recipients?(email) do
        email = put_adapter_client_options(email, opts)
        metadata = %{metadata | email: email}

        deliver_with_telemetry(email, opts, metadata)
      else
        Logger.info("Skipping email because all recipients are undeliverable or suppressed",
          email_subject: inspect(email.subject)
        )

        {:ok, %{}}
      end
    else
      Logger.info("Emails are not configured", email_subject: inspect(email.subject))
      {:ok, %{}}
    end
  end

  defp put_adapter_client_options(%Email{} = email, opts) do
    req_opts =
      opts[:req_opts]
      |> List.wrap()
      |> Keyword.merge(email.private[:client_options] || [])
      |> maybe_put_acs_hmac_auth_plugin(opts)

    case req_opts do
      [] -> email
      _ -> Email.put_private(email, :client_options, req_opts)
    end
  end

  defp maybe_put_acs_hmac_auth_plugin(req_opts, opts) do
    with Swoosh.Adapters.AzureCommunicationServices <- Keyword.get(opts, :adapter),
         access_key when is_binary(access_key) <- Keyword.get(opts, :access_key) do
      plugin = fn req -> Portal.AzureCommunicationServices.HMACAuth.attach(req, access_key) end

      Keyword.update(req_opts, :plugins, [plugin], fn plugins ->
        List.wrap(plugins) ++ [plugin]
      end)
    else
      _ -> req_opts
    end
  end

  defp deliver_with_telemetry(email, opts, metadata) do
    :telemetry.span([:swoosh, :deliver], metadata, fn ->
      case Mailer.deliver(email, opts) do
        {:ok, result} -> {{:ok, result}, Map.put(metadata, :result, result)}
        {:error, error} -> {{:error, error}, Map.put(metadata, :error, error)}
      end
    end)
  end

  defp render_template(view, template, format, assigns) do
    heex = apply(view, String.to_existing_atom("#{template}_#{format}"), [assigns])
    assigns = Keyword.merge(assigns, inner_content: heex)
    Phoenix.Template.render_to_string(view, "#{template}_#{format}", format, assigns)
  end

  def render_body(%Swoosh.Email{} = email, view, template, assigns) do
    assigns = assigns ++ [email: email]

    email
    |> Email.html_body(render_template(view, template, "html", assigns))
    |> Email.text_body(render_template(view, template, "text", assigns))
  end

  def render_text_body(%Swoosh.Email{} = email, view, template, assigns) do
    assigns = assigns ++ [email: email]

    email
    |> Email.text_body(render_template(view, template, "text", assigns))
  end

  def active? do
    mailer_config = Portal.Config.fetch_env!(:portal, Portal.Mailer)
    mailer_config[:from_email] && mailer_config[:adapter]
  end

  def default_email do
    # Fail hard if email not configured
    from_email =
      Portal.Config.fetch_env!(:portal, Portal.Mailer)
      |> Keyword.fetch!(:from_email)

    Email.new()
    |> Email.from({"Firezone Notifications", from_email})
  end

  def with_account_id(%Email{} = email, account_id) when is_binary(account_id) do
    Email.put_private(email, :account_id, account_id)
  end

  def bcc_recipients(%Email{} = email, recipients) when is_list(recipients) do
    Enum.reduce(recipients, email, fn recipient, acc ->
      Email.bcc(acc, recipient)
    end)
  end

  @doc """
  Enqueues an email for delivery via the secondary ACS adapter.

  Checks the suppression table before inserting the Oban job. Returns
  `{:ok, :suppressed}` if all recipients are suppressed. The suppression
  table is checked again right before the queued job delivers.
  """
  def enqueue(%Email{} = email) do
    account_id = email.private[:account_id]
    email = email |> drop_blocked_recipients() |> drop_suppressed_recipients()

    if has_recipients?(email) do
      %{"account_id" => account_id, "request" => serialize(email)}
      |> OutboundEmailWorker.new()
      |> Oban.insert()
    else
      Logger.info("Skipping queued email because all recipients are suppressed",
        account_id: account_id,
        subject: inspect(email.subject)
      )

      {:ok, :suppressed}
    end
  end

  def insert_tracked_delivery(account_id, message_id, subject, recipients) do
    Database.insert_tracked(account_id, message_id, subject, recipients)
  end

  defp maybe_insert_tracked(%Email{} = email, result) do
    with message_id when is_binary(message_id) <- result_message_id(result),
         [_ | _] = recipients <- email_addresses(email) do
      account_id = email.private[:account_id]

      case Database.insert_tracked(account_id, message_id, email.subject, recipients) do
        {:ok, _entry} ->
          :ok

        {:error, reason} ->
          Logger.error("Failed to persist tracked outbound email; email was already sent",
            account_id: account_id,
            message_id: message_id,
            reason: inspect(reason)
          )

          :ok
      end
    else
      _ -> :ok
    end
  end

  defp result_message_id(result) when is_map(result), do: result[:id] || result["id"]
  defp result_message_id(_), do: nil

  defp effective_adapter(config) do
    Mailer.parse_config(:portal, __MODULE__, [], config)[:adapter]
  end

  defp email_addresses(%Email{} = email) do
    (List.wrap(email.to) ++ List.wrap(email.cc) ++ List.wrap(email.bcc))
    |> Enum.map(fn
      {_, addr} -> addr
      addr when is_binary(addr) -> addr
    end)
    |> Enum.reject(&undeliverable_address?/1)
    |> Enum.uniq()
  end

  defp serialize(%Email{} = email) do
    %{
      "to" => serialize_addresses(email.to),
      "cc" => serialize_addresses(email.cc),
      "bcc" => serialize_addresses(email.bcc),
      "from" =>
        case email.from do
          {name, addr} -> %{"name" => name, "address" => addr}
          addr -> %{"name" => "", "address" => addr}
        end,
      "subject" => email.subject,
      "html_body" => email.html_body,
      "text_body" => email.text_body
    }
  end

  defp serialize_addresses(addresses) do
    addresses
    |> List.wrap()
    |> Enum.map(fn
      {name, addr} -> %{"name" => name, "address" => addr}
      addr when is_binary(addr) -> %{"name" => "", "address" => addr}
    end)
    |> Enum.uniq_by(fn %{"address" => addr} -> EmailSuppression.normalize_email(addr) end)
  end

  defp drop_suppressed_recipients(%Email{} = email) do
    suppressed_emails =
      email
      |> email_addresses()
      |> Database.suppressed_recipient_addresses()

    if suppressed_emails == [] do
      email
    else
      %{
        email
        | to: reject_suppressed_addresses(email.to, suppressed_emails),
          cc: reject_suppressed_addresses(email.cc, suppressed_emails),
          bcc: reject_suppressed_addresses(email.bcc, suppressed_emails)
      }
    end
  end

  defp reject_suppressed_addresses(recipients, suppressed_emails) do
    recipients
    |> List.wrap()
    |> Enum.reject(fn
      {_name, address} -> EmailSuppression.normalize_email(address) in suppressed_emails
      address when is_binary(address) -> EmailSuppression.normalize_email(address) in suppressed_emails
    end)
  end

  defp drop_blocked_recipients(%Email{} = email) do
    %{
      email
      | to: reject_blocked_addresses(email.to),
        cc: reject_blocked_addresses(email.cc),
        bcc: reject_blocked_addresses(email.bcc)
    }
  end

  defp reject_blocked_addresses(recipients) do
    recipients
    |> List.wrap()
    |> Enum.reject(fn
      {_name, address} -> undeliverable_address?(address)
      address when is_binary(address) -> undeliverable_address?(address)
    end)
  end

  defp has_recipients?(%Email{} = email) do
    Enum.any?([email.to, email.cc, email.bcc], fn field ->
      field |> List.wrap() |> Enum.any?()
    end)
  end

  defp undeliverable_address?(address) do
    normalized = EmailSuppression.normalize_email(address)
    Enum.any?(@blocked_suffixes, &String.ends_with?(normalized, &1))
  end

  defmodule Database do
    import Ecto.Query
    require Logger

    alias Portal.Safe
    alias Portal.{EmailSuppression, OutboundEmail, OutboundEmailDelivery, Repo}

    @db_opts [timeout: 20_000, pool_timeout: 20_000]

    def suppressed_recipient_addresses(recipients) do
      addresses =
        recipients
        |> Enum.map(&EmailSuppression.normalize_email/1)

      if addresses == [] do
        []
      else
        from(s in EmailSuppression, where: s.email in ^addresses, select: s.email)
        |> Safe.unscoped(:replica)
        |> Safe.all()
      end
    end

    def insert_tracked(account_id, message_id, subject, recipients) do
      now = DateTime.utc_now()
      recipients = normalize_recipients(recipients)

      case do_insert_tracked(account_id, message_id, subject, recipients, now) do
        {:error, %Ecto.Changeset{} = changeset} when not is_nil(account_id) ->
          if account_does_not_exist?(changeset) do
            # The account was deleted out from under us (e.g. a deletion-complete
            # email racing teardown). Still persist the tracking record, just
            # without the account_id, which the FK now allows (ON DELETE SET NULL).
            Logger.info(
              "Persisting tracked outbound email without account_id; account no longer exists",
              account_id: account_id,
              message_id: message_id
            )

            do_insert_tracked(nil, message_id, subject, recipients, now)
          else
            {:error, changeset}
          end

        result ->
          result
      end
    end

    defp do_insert_tracked(account_id, message_id, subject, recipients, now) do
      Safe.transact(
        fn ->
          with {:ok, entry} <- insert_entry(account_id, message_id, subject, recipients, now) do
            Safe.insert_all(
              Repo,
              OutboundEmailDelivery,
              delivery_rows(account_id, message_id, recipients, now),
              @db_opts
            )

            {:ok, entry}
          end
        end,
        @db_opts
      )
    end

    defp account_does_not_exist?(%Ecto.Changeset{errors: errors}) do
      match?({_, [{:constraint, :assoc} | _]}, Keyword.get(errors, :account))
    end

    defp normalize_recipients(recipients) do
      recipients
      |> Enum.map(&EmailSuppression.normalize_email/1)
      |> Enum.uniq()
    end

    defp delivery_rows(account_id, message_id, recipients, now) do
      Enum.map(recipients, fn email ->
        %{
          account_id: account_id,
          message_id: message_id,
          email: email,
          status: :pending,
          inserted_at: now,
          updated_at: now
        }
      end)
    end

    defp insert_entry(account_id, message_id, subject, recipients, now) do
      attrs = %{
        account_id: account_id,
        message_id: message_id,
        subject: subject,
        recipients: recipients,
        inserted_at: now,
        updated_at: now
      }

      changeset =
        %OutboundEmail{}
        |> Ecto.Changeset.change(attrs)
        |> OutboundEmail.changeset()

      Safe.insert(
        Repo,
        changeset,
        @db_opts
      )
    end
  end
end

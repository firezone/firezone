defmodule Portal.Mailer do
  alias Swoosh.Mailer
  alias Swoosh.Email
  alias Portal.EmailSuppression
  alias Portal.Mailer.RateLimiter
  alias Portal.Workers.OutboundEmail, as: OutboundEmailWorker
  alias __MODULE__.Database
  require Logger

  @recipient_fields [{"to", :to}, {"cc", :cc}, {"bcc", :bcc}]

  def deliver_with_rate_limit(email, config \\ []) do
    {key, config} = Keyword.pop(config, :rate_limit_key, {email.to, email.subject})

    {rate_limit, config} = Keyword.pop(config, :rate_limit, 10)
    {rate_limit_interval, config} = Keyword.pop(config, :rate_limit_interval, :timer.minutes(2))

    RateLimiter.rate_limit(key, rate_limit, rate_limit_interval, fn ->
      deliver(email, config)
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

  def deliver_secondary(email, config \\ []) do
    opts =
      Portal.Config.fetch_env!(:portal, Portal.Mailer.Secondary)
      |> Keyword.merge(config)

    metadata = %{email: email, config: config, mailer: Portal.Mailer.Secondary}

    deliver_with_mailer_config(email, opts, metadata)
  end

  defp deliver_with_mailer_config(email, opts, metadata) do
    if opts[:adapter] do
      deliver_with_telemetry(email, opts, metadata)
    else
      Logger.info("Emails are not configured", email_subject: inspect(email.subject))
      {:ok, %{}}
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

  # sobelow_skip ["DOS.StringToAtom"]
  defp render_template(view, template, format, assigns) do
    heex = apply(view, String.to_atom("#{template}_#{format}"), [assigns])
    assigns = Keyword.merge(assigns, inner_content: heex)
    Phoenix.Template.render_to_string(view, "#{template}_#{format}", "html", assigns)
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
  `{:ok, :suppressed}` if all recipients are suppressed.
  """
  def enqueue(%Email{} = email) do
    account_id = require_account_id!(email)
    request = serialize(email)

    case drop_suppressed_recipients(request) do
      {:ok, filtered_request} ->
        %{"account_id" => account_id, "request" => filtered_request}
        |> OutboundEmailWorker.new()
        |> Oban.insert()

      :fully_suppressed ->
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

  defp require_account_id!(%Email{} = email) do
    case email.private[:account_id] do
      account_id when is_binary(account_id) -> account_id
      _ -> raise ArgumentError, "call Portal.Mailer.with_account_id/2 before enqueue/1"
    end
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
  end

  defp drop_suppressed_recipients(request) do
    suppressed_emails =
      request
      |> recipient_addresses()
      |> Database.suppressed_recipient_addresses()

    filtered_request =
      Enum.reduce(@recipient_fields, request, fn {field, _kind}, acc ->
        recipients = Map.get(acc, field, [])

        Map.put(
          acc,
          field,
          Enum.reject(recipients, fn %{"address" => address} ->
            EmailSuppression.normalize_email(address) in suppressed_emails
          end)
        )
      end)

    case recipient_addresses(filtered_request) do
      [] -> :fully_suppressed
      _ -> {:ok, filtered_request}
    end
  end

  defp recipient_addresses(request) do
    Enum.flat_map(@recipient_fields, fn {field, _kind} ->
      Enum.map(Map.get(request, field, []), fn %{"address" => address} -> address end)
    end)
  end

  defmodule Database do
    import Ecto.Query

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

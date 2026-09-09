defmodule Portal.Analytics do
  @moduledoc """
  Reports consented account conversions without blocking signup or billing on ad APIs.
  """

  alias Portal.Analytics.OpenAI
  alias __MODULE__.Database
  require Logger

  def registration_completed(account, actor) do
    enqueue(account, actor.email, "registration_completed", "customer_action",
      id: "registration_#{account.id}",
      timestamp_ms: DateTime.to_unix(account.inserted_at, :millisecond),
      path: "/sign_up"
    )
  end

  def subscription_created(account, subscription_id, timestamp) do
    enqueue(account, account.metadata.stripe.billing_email, "subscription_created", "plan_enrollment",
      id: "team_#{subscription_id}",
      timestamp_ms: timestamp * 1000,
      path: "/#{account.slug}/settings/account"
    )
  end

  defp enqueue(account, email, event_type, data_type, opts) do
    enqueue_openai(account, email, event_type, data_type, opts)
    Portal.Analytics.GoogleAds.enqueue(account, email, event_type, opts)
    :ok
  end

  defp enqueue_openai(account, email, event_type, data_type, opts) do
    attribution = account.metadata.marketing_attribution

    if OpenAI.enabled?() and marketing_allowed?(attribution) and is_binary(email) and
         String.trim(email) != "" do
      event = %{
        "id" => opts[:id],
        "type" => event_type,
        "timestamp_ms" => opts[:timestamp_ms],
        "source_url" => PortalWeb.Endpoint.url() <> opts[:path],
        "action_source" => "web",
        "user" => %{"emails_sha256" => [hash_email(email)]},
        "data" => %{"type" => data_type}
      }

      event =
        if attribution["oppref"],
          do: Map.put(event, "oppref", attribution["oppref"]),
          else: event

      case OpenAI.new(%{"account_id" => account.id, "event" => event}) |> Oban.insert() do
        {:ok, _job} -> :ok
        {:error, _reason} -> Logger.warning("Could not enqueue OpenAI conversion", event: event_type)
      end
    end

    :ok
  rescue
    _ ->
      Logger.warning("Could not enqueue OpenAI conversion", event: event_type)
      :ok
  end

  def marketing_allowed?(%{"marketing_allowed" => true, "captured_at" => captured_at})
      when is_integer(captured_at) do
    age = System.os_time(:second) - captured_at
    age >= 0 and age <= 90 * 24 * 60 * 60
  end

  def marketing_allowed?(_), do: false

  def hash_email(email) do
    email
    |> String.trim()
    |> String.downcase()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # Refresh the consent snapshot before opening Stripe, including explicit opt-outs.
  def update_marketing_attribution(_account, nil), do: :ok

  def update_marketing_attribution(account, attribution) do
    Database.update_marketing_attribution(account.id, attribution)
    :ok
  rescue
    _ ->
      Logger.warning("Could not update marketing attribution")
      :ok
  end

  defmodule Database do
    import Ecto.Query
    import Ecto.Changeset
    alias Portal.{Account, Safe}

    def account(id) do
      from(a in Account, where: a.id == ^id) |> Safe.unscoped() |> Safe.one()
    end

    def update_marketing_attribution(id, attribution) do
      Safe.transact(fn ->
        account =
          from(a in Account, where: a.id == ^id, lock: "FOR UPDATE")
          |> Safe.unscoped()
          |> Safe.one!()

        account
        |> cast(%{metadata: %{marketing_attribution: attribution}}, [])
        |> cast_embed(:metadata)
        |> Safe.unscoped()
        |> Safe.update()
      end)
    end
  end
end

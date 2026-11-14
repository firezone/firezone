defmodule Portal.Billing.YCDeal do
  @moduledoc """
  YC deal coupons take 100% off for 12 months, but only up to a total
  discount that Stripe cannot enforce. The cap is the `yc_deal_cap` metadata
  of each coupon, in the smallest currency unit.

  Plan changes in the Customer Portal are invoiced and charged at once, so the
  cap is enforced after the fact: when the YC discounts of a customer pass the
  cap, the coupon comes off the subscription and the excess is billed on its
  next invoice. Totals are cumulative, so a skipped event is caught up by the
  next one.

  Webhook events use the account's default API version, so only the invoice ID
  and customer come from the event. Everything else is read from the invoice
  list, which uses the version the portal pins.
  """

  alias Portal.Billing.Stripe.APIClient
  require Logger

  @cap_key "yc_deal_cap"
  @overage_key "yc_deal_overage"
  @counted_statuses ["open", "paid", "uncollectible"]

  def enforce_cap(
        %{"id" => invoice_id, "customer" => customer_id, "total_discount_amounts" => [_ | _]}
      )
      when is_binary(customer_id) do
    api_token = Portal.Config.fetch_env!(:portal, Portal.Billing) |> Keyword.fetch!(:secret_key)

    with {:ok, invoices} <- APIClient.list_all_customer_invoices(api_token, customer_id),
         {used, cap} when cap > 0 <- usage(invoices),
         {:ok, items} <- APIClient.list_all_customer_invoice_items(api_token, customer_id) do
      due = used - cap - billed_overage(items)

      if due > 0,
        do: bill_overage(api_token, Enum.find(invoices, &(&1["id"] == invoice_id)), due),
        else: :ok
    else
      {_used, 0} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def enforce_cap(_invoice), do: :ok

  defp usage(invoices) do
    for %{"status" => status, "total_discount_amounts" => amounts} <- invoices,
        status in @counted_statuses,
        %{"amount" => amount, "discount" => %{"coupon" => %{"metadata" => %{@cap_key => cap}}}} <-
          amounts,
        {cap, ""} <- [Integer.parse(cap)],
        reduce: {0, 0} do
      {used, max_cap} -> {used + amount, max(max_cap, cap)}
    end
  end

  defp billed_overage(items) do
    for %{"amount" => amount, "metadata" => %{@overage_key => _}} <- items, reduce: 0 do
      total -> total + amount
    end
  end

  # The discount comes off first: if billing the excess then fails, the retried
  # event still sees it as due and bills it. The amount is part of the
  # idempotency key because a retry can see a different amount due.
  defp bill_overage(_api_token, nil, _due), do: {:error, :invoice_not_listed}

  defp bill_overage(api_token, invoice, due) do
    subscription_id = invoice["subscription"]

    attrs =
      [
        {"customer", invoice["customer"]},
        {"amount", due},
        {"currency", invoice["currency"]},
        {"description", "YC deal discount beyond the deal's limit"},
        {"metadata[#{@overage_key}]", "true"}
      ] ++ if(subscription_id, do: [{"subscription", subscription_id}], else: [])

    with :ok <- remove_discount(api_token, subscription_id),
         {:ok, _item} <-
           APIClient.create_invoice_item(
             api_token,
             attrs,
             "yc-deal-overage-#{invoice["id"]}-#{due}"
           ) do
      Logger.warning("YC deal discount passed its cap; billed the excess on the next invoice",
        customer_id: invoice["customer"],
        invoice_id: invoice["id"],
        amount: due
      )

      :ok
    end
  end

  defp remove_discount(_api_token, nil), do: :ok

  defp remove_discount(api_token, subscription_id) do
    case APIClient.delete_subscription_discount(api_token, subscription_id) do
      {:ok, _response} -> :ok
      {:error, {404, _response}} ->
        Logger.warning("YC deal discount was not on the subscription",
          subscription_id: subscription_id
        )

        :ok

      {:error, reason} -> {:error, reason}
    end
  end
end

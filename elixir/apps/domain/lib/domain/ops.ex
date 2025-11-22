defmodule Domain.Ops do
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
    Domain.Accounts.Account.Query.all()
    |> Domain.Accounts.Account.Query.disabled()
    |> Domain.Accounts.Account.Query.by_id(id)
    |> Domain.Repo.one!()
    |> Domain.Repo.delete(timeout: :infinity)

    :ok
  end
end

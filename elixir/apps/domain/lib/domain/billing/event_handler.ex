defmodule Domain.Billing.EventHandler do
  alias Domain.Repo
  alias Domain.Accounts
  alias Domain.Billing
  require Logger

  # customer is created
  def handle_event(%{
        "object" => "event",
        "data" => %{
          "object" => customer
        },
        "type" => "customer.created"
      }) do
    create_account_from_stripe_customer(customer)
  end

  # customer is updated
  def handle_event(%{
        "object" => "event",
        "data" => %{
          "object" =>
            %{
              "id" => customer_id,
              "name" => customer_name,
              "email" => customer_email,
              "metadata" => customer_metadata
            } = customer
        },
        "type" => "customer.updated"
      }) do
    attrs =
      %{
        name: customer_name,
        metadata: %{stripe: %{billing_email: customer_email}}
      }
      |> put_if_not_nil(:slug, customer_metadata["account_slug"])

    case update_account_by_stripe_customer_id(customer_id, attrs) do
      {:ok, _account} ->
        :ok

      {:error, :customer_not_provisioned} ->
        _ = create_account_from_stripe_customer(customer)
        :ok

      {:error, :not_found} ->
        :ok

      {:error, reason} ->
        :ok =
          Logger.error("Failed to sync account from Stripe",
            customer_id: customer_id,
            reason: inspect(reason)
          )

        :error
    end
  end

  # subscription is ended or deleted
  def handle_event(%{
        "object" => "event",
        "data" => %{
          "object" => %{
            "customer" => customer_id
          }
        },
        "type" => "customer.subscription.deleted"
      }) do
    update_account_by_stripe_customer_id(customer_id, %{
      disabled_at: DateTime.utc_now(),
      disabled_reason: "Stripe subscription deleted"
    })
    |> case do
      {:ok, _account} ->
        :ok

      {:error, reason} ->
        :ok =
          Logger.error("Failed to update account on Stripe subscription event",
            customer_id: customer_id,
            reason: inspect(reason)
          )

        :error
    end
  end

  # subscription is paused
  def handle_event(%{
        "object" => "event",
        "data" => %{
          "object" => %{
            "customer" => customer_id,
            "pause_collection" => %{
              "behavior" => "void"
            }
          }
        },
        "type" => "customer.subscription.updated"
      }) do
    update_account_by_stripe_customer_id(customer_id, %{
      disabled_at: DateTime.utc_now(),
      disabled_reason: "Stripe subscription paused"
    })
    |> case do
      {:ok, _account} ->
        :ok

      {:error, reason} ->
        :ok =
          Logger.error("Failed to update account on Stripe subscription event",
            customer_id: customer_id,
            reason: inspect(reason)
          )

        :error
    end
  end

  def handle_event(%{
        "object" => "event",
        "data" => %{
          "object" => %{
            "customer" => customer_id
          }
        },
        "type" => "customer.subscription.paused"
      }) do
    update_account_by_stripe_customer_id(customer_id, %{
      disabled_at: DateTime.utc_now(),
      disabled_reason: "Stripe subscription paused"
    })
    |> case do
      {:ok, _account} ->
        :ok

      {:error, reason} ->
        :ok =
          Logger.error("Failed to update account on Stripe subscription event",
            customer_id: customer_id,
            reason: inspect(reason)
          )

        :error
    end
  end

  # subscription is resumed, created or updated
  def handle_event(%{
        "object" => "event",
        "data" => %{
          "object" => %{
            "id" => subscription_id,
            "customer" => customer_id,
            "metadata" => subscription_metadata,
            "items" => %{
              "data" => [
                %{
                  "plan" => %{
                    "product" => product_id
                  },
                  "quantity" => quantity
                }
              ]
            }
          }
        },
        "type" => "customer.subscription." <> _
      }) do
    {:ok,
     %{
       "name" => product_name,
       "metadata" => product_metadata
     }} = Billing.fetch_product(product_id)

    attrs =
      account_update_attrs(quantity, product_metadata, subscription_metadata)
      |> Map.put(:metadata, %{
        stripe: %{
          subscription_id: subscription_id,
          product_name: product_name
        }
      })
      |> Map.put(:disabled_at, nil)
      |> Map.put(:disabled_reason, nil)

    update_account_by_stripe_customer_id(customer_id, attrs)
    |> case do
      {:ok, _account} ->
        :ok

      {:error, reason} ->
        :ok =
          Logger.error("Failed to update account on Stripe subscription event",
            customer_id: customer_id,
            reason: inspect(reason)
          )

        :error
    end
  end

  def handle_event(%{"object" => "event", "data" => %{}}) do
    :ok
  end

  defp create_account_from_stripe_customer(%{
         "id" => customer_id,
         "name" => customer_name,
         "email" => account_email,
         "metadata" => %{
           "company_website" => company_website,
           "account_owner_first_name" => account_owner_first_name,
           "account_owner_last_name" => account_owner_last_name,
           "admin_email" => account_admin_email
         }
       }) do
    uri = URI.parse(company_website)
    account_slug = uri.host |> String.split(".") |> List.delete_at(-1) |> Enum.join("_")

    attrs = %{
      name: customer_name,
      slug: account_slug,
      metadata: %{
        stripe: %{
          customer_id: customer_id,
          billing_email: account_email || account_admin_email
        }
      }
    }

    Repo.transaction(fn ->
      {:ok, _account} =
        with {:ok, account} <- Domain.Accounts.create_account(attrs),
             {:ok, account} <- Billing.update_customer(account),
             {:ok, account} <- Domain.Billing.create_subscription(account) do
          {:ok, _everyone_group} =
            Domain.Actors.create_managed_group(account, %{
              name: "Everyone",
              membership_rules: [%{operator: true}]
            })

          {:ok, magic_link_provider} =
            Domain.Auth.create_provider(account, %{
              name: "Email",
              adapter: :email,
              adapter_config: %{}
            })

          {:ok, actor} =
            Domain.Actors.create_actor(account, %{
              type: :account_admin_user,
              name: account_owner_first_name <> " " <> account_owner_last_name
            })

          {:ok, _identity} =
            Domain.Auth.upsert_identity(actor, magic_link_provider, %{
              provider_identifier: account_admin_email,
              provider_identifier_confirmation: account_admin_email
            })

          {:ok, account}
        end
    end)
    |> case do
      {:ok, _} ->
        :ok

      {:error, %Ecto.Changeset{} = changeset} ->
        :ok =
          Logger.error("Failed to create account from Stripe",
            customer_id: customer_id,
            reason: inspect(changeset)
          )

        :ok

      {:error, reason} ->
        :ok =
          Logger.error("Failed to create account from Stripe",
            customer_id: customer_id,
            reason: inspect(reason)
          )

        :error
    end
  end

  defp create_account_from_stripe_customer(%{
         "id" => customer_id,
         "name" => customer_name,
         "metadata" => customer_metadata
       }) do
    :ok =
      Logger.warning("Failed to create account from Stripe",
        customer_id: customer_id,
        customer_metadata: inspect(customer_metadata),
        customer_name: customer_name,
        reason: "missing custom metadata keys"
      )

    :ok
  end

  defp update_account_by_stripe_customer_id(customer_id, attrs) do
    with {:ok, account_id} <- Billing.fetch_customer_account_id(customer_id) do
      Accounts.update_account_by_id(account_id, attrs)
    end
  end

  defp account_update_attrs(quantity, product_metadata, subscription_metadata) do
    limit_fields = Accounts.Limits.__schema__(:fields) |> Enum.map(&to_string/1)

    features_and_limits =
      Map.merge(product_metadata, subscription_metadata)
      |> Enum.flat_map(fn
        {feature, "true"} ->
          [{feature, true}]

        {feature, "false"} ->
          [{feature, false}]

        {key, value} ->
          if key in limit_fields do
            [{key, cast_limit(value)}]
          else
            []
          end
      end)
      |> Enum.into(%{})

    {monthly_active_users_count, features_and_limits} =
      Map.pop(features_and_limits, "monthly_active_users_count", quantity)

    {limits, features} = Map.split(features_and_limits, limit_fields)

    limits = Map.merge(limits, %{"monthly_active_users_count" => monthly_active_users_count})

    %{
      features: features,
      limits: limits
    }
  end

  defp cast_limit(number) when is_number(number), do: number
  defp cast_limit("unlimited"), do: nil
  defp cast_limit(binary) when is_binary(binary), do: String.to_integer(binary)

  defp put_if_not_nil(map, _key, nil), do: map
  defp put_if_not_nil(map, key, value), do: Map.put(map, key, value)
end

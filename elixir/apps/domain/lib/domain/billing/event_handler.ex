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
        name: customer_metadata["account_name"] || customer_name,
        legal_name: customer_name,
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
            "trial_end" => trial_end,
            "status" => status,
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
        "type" => "customer.subscription." <> event_type
      })
      when event_type in [
             "created",
             "resumed",
             "updated"
           ] do
    {:ok,
     %{
       "name" => product_name,
       "metadata" => product_metadata
     }} = Billing.fetch_product(product_id)

    subscription_trialing? = not is_nil(trial_end) and status in ["trialing", "paused"]

    attrs =
      account_update_attrs(quantity, product_metadata, subscription_metadata, %{
        "subscription_id" => subscription_id,
        "product_name" => product_name,
        "trial_ends_at" => if(subscription_trialing?, do: DateTime.from_unix!(trial_end))
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

  defp create_account_from_stripe_customer(%{"metadata" => %{"account_id" => _account_id}}) do
    :ok
  end

  defp create_account_from_stripe_customer(%{
         "id" => customer_id,
         "name" => customer_name,
         "email" => account_email,
         "metadata" =>
           %{
             "company_website" => company_website,
             "account_owner_first_name" => account_owner_first_name,
             "account_owner_last_name" => account_owner_last_name
           } = metadata
       }) do
    uri = URI.parse(company_website)

    account_slug =
      cond do
        not is_nil(metadata["account_slug"]) ->
          metadata["account_slug"]

        uri.host ->
          uri.host
          |> String.split(".")
          |> List.delete_at(-1)
          |> Enum.join("_")
          |> String.replace("-", "_")

        uri.path ->
          uri.path
          |> String.split(".")
          |> List.delete_at(-1)
          |> Enum.join("_")
          |> String.replace("-", "_")

        true ->
          Accounts.generate_unique_slug()
      end

    attrs = %{
      name: metadata["account_name"] || customer_name,
      legal_name: customer_name,
      slug: account_slug,
      metadata: %{
        stripe: %{
          customer_id: customer_id,
          billing_email: account_email
        }
      }
    }

    Repo.transaction(fn ->
      :ok =
        with {:ok, account} <- Domain.Accounts.create_account(attrs),
             {:ok, account} <- Billing.update_customer(account),
             {:ok, account} <- Domain.Billing.create_subscription(account) do
          {:ok, _everyone_group} =
            Domain.Actors.create_managed_group(account, %{
              name: "Everyone",
              membership_rules: [%{operator: true}]
            })

          {:ok, email_provider} =
            Domain.Auth.create_provider(account, %{
              name: "Email (OTP)",
              adapter: :email,
              adapter_config: %{}
            })

          {:ok, actor} =
            Domain.Actors.create_actor(account, %{
              type: :account_admin_user,
              name: account_owner_first_name <> " " <> account_owner_last_name
            })

          {:ok, _identity} =
            Domain.Auth.upsert_identity(actor, email_provider, %{
              provider_identifier: metadata["account_admin_email"] || account_email,
              provider_identifier_confirmation: metadata["account_admin_email"] || account_email
            })

          {:ok, _gateway_group} = Domain.Gateways.create_group(account, %{name: "Default Site"})

          {:ok, internet_gateway_group} = Domain.Gateways.create_internet_group(account)

          {:ok, _resource} =
            Domain.Resources.create_internet_resource(account, internet_gateway_group)

          :ok
        else
          {:error, %Ecto.Changeset{errors: [{:slug, {"has already been taken", _}} | _]}} ->
            :ok

          {:error, reason} ->
            {:error, reason}
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

  defp account_update_attrs(
         quantity,
         product_metadata,
         subscription_metadata,
         stripe_metadata_overrides
       ) do
    # feature_fields = Accounts.Features.__schema__(:fields) |> Enum.map(&to_string/1)
    limit_fields = Accounts.Limits.__schema__(:fields) |> Enum.map(&to_string/1)
    metadata_fields = ["support_type"]

    params =
      Map.merge(product_metadata, subscription_metadata)
      |> Enum.flat_map(fn
        {feature, "true"} ->
          [{feature, true}]

        {feature, "false"} ->
          [{feature, false}]

        {key, value} ->
          cond do
            key in limit_fields ->
              [{key, cast_limit(value)}]

            key in metadata_fields ->
              [{key, value}]

            true ->
              []
          end
      end)
      |> Enum.into(%{})

    {users_count, params} = Map.pop(params, "users_count", quantity)
    {metadata, params} = Map.split(params, metadata_fields)
    {limits, features} = Map.split(params, limit_fields)
    limits = Map.merge(limits, %{"users_count" => users_count})

    %{
      features: features,
      limits: limits,
      metadata: %{stripe: Map.merge(metadata, stripe_metadata_overrides)}
    }
  end

  defp cast_limit(number) when is_number(number), do: number
  defp cast_limit("unlimited"), do: nil
  defp cast_limit(binary) when is_binary(binary), do: String.to_integer(binary)

  defp put_if_not_nil(map, _key, nil), do: map
  defp put_if_not_nil(map, key, value), do: Map.put(map, key, value)
end

defmodule Domain.Repo.Seeds do
  @moduledoc """
  Seeds the database with initial data.
  """
  alias Domain.{
    Repo,
    Accounts,
    Auth,
    AuthProviders,
    Actors,
    Relays,
    Gateways,
    Resources,
    Policies,
    Flows,
    Tokens,
    EmailOTP,
    Userpass,
    OIDC,
    Google,
    Entra
  }

  # Populate these in your .env
  defp google_idp_id do
    System.get_env("GOOGLE_IDP_ID")
  end

  defp entra_idp_id do
    System.get_env("ENTRA_IDP_ID")
  end

  defp entra_tenant_id do
    System.get_env("ENTRA_TENANT_ID")
  end

  # Helper function to create auth providers with the new structure
  defp create_auth_provider(provider_module, attrs, subject) do
    provider_id = Ecto.UUID.generate()

    # First create the base auth_provider record using Repo directly
    {:ok, _base_provider} =
      Repo.insert(%AuthProviders.AuthProvider{
        id: provider_id,
        account_id: subject.account.id
      })

    # Then create the provider-specific record using Repo directly (seeds don't need authorization)
    attrs_with_id =
      attrs
      |> Map.put(:id, provider_id)
      |> Map.put(:account_id, subject.account.id)
      |> Map.put(:created_by, :system)

    changeset =
      struct(provider_module, attrs_with_id)
      |> Ecto.Changeset.change()
      |> provider_module.changeset()

    Repo.insert(changeset)
  end

  def seed do
    # Seeds can be run both with MIX_ENV=prod and MIX_ENV=test, for test env we don't have
    # an adapter configured and creation of email provider will fail, so we will override it here.
    System.put_env("OUTBOUND_EMAIL_ADAPTER", "Elixir.Swoosh.Adapters.Mailgun")

    # Ensure seeds are deterministic
    :rand.seed(:exsss, {1, 2, 3})

    # This function is used to update fields if STATIC_SEEDS is set,
    # which helps with static docker-compose environment for local development.
    maybe_repo_update = fn resource, values ->
      if System.get_env("STATIC_SEEDS") == "true" do
        Ecto.Changeset.change(resource, values)
        |> Repo.update!()
      else
        resource
      end
    end

    {:ok, account} =
      Accounts.create_account(%{
        name: "Firezone Account",
        slug: "firezone",
        config: %{
          search_domain: "httpbin.search.test"
        }
      })

    account =
      account
      |> Ecto.Changeset.change(
        features: %{
          policy_conditions: true,
          multi_site_resources: true,
          traffic_filters: true,
          self_hosted_relays: true,
          idp_sync: true,
          rest_api: true,
          internet_resource: true
        }
      )
      |> Repo.update!()

    account =
      maybe_repo_update.(account,
        id: "c89bcc8c-9392-4dae-a40d-888aef6d28e0",
        metadata: %{
          stripe: %{
            customer_id: "cus_PZKIfcHB6SSBA4",
            subscription_id: "sub_1OkGm2ADeNU9NGxvbrCCw6m3",
            product_name: "Enterprise",
            billing_email: "fin@firez.one",
            support_type: "email"
          }
        },
        limits: %{
          users_count: 15,
          monthly_active_users_count: 10,
          service_accounts_count: 10,
          gateway_groups_count: 3,
          account_admin_users_count: 5
        }
      )

    {:ok, other_account} =
      Accounts.create_account(%{
        name: "Other Corp Account",
        slug: "not_firezone"
      })

    other_account = maybe_repo_update.(other_account, id: "9b9290bf-e1bc-4dd3-b401-511908262690")

    IO.puts("Created accounts: ")

    for item <- [account, other_account] do
      IO.puts("  #{item.id}: #{item.name}")
    end

    IO.puts("")

    {:ok, internet_gateway_group} =
      Gateways.create_internet_group(account)

    {:ok, other_internet_gateway_group} =
      Gateways.create_internet_group(other_account)

    Domain.Resources.create_internet_resource(account, internet_gateway_group)
    Domain.Resources.create_internet_resource(other_account, other_internet_gateway_group)

    IO.puts("")

    {:ok, everyone_group} =
      Domain.Actors.create_managed_group(account, %{
        name: "Everyone"
      })

    {:ok, _everyone_group} =
      Domain.Actors.create_managed_group(other_account, %{
        name: "Everyone"
      })

    # TODO: IDP REFACTOR
    # This conditional can be removed once all accounts are migrated
    new_auth? = System.get_env("LEGACY_AUTH") != "true"

    {email_provider, oidc_provider, userpass_provider, _google_provider, _entra_provider} =
      if new_auth? do
        # New auth system - create proper auth providers
        system_subject = %Auth.Subject{
          account: account,
          actor: %Actors.Actor{type: :system, id: Ecto.UUID.generate(), name: "System"},
          identity: nil,
          token_id: nil,
          expires_at: nil,
          context: %Auth.Context{type: :browser, remote_ip: {127, 0, 0, 1}, user_agent: "seeds/1"},
          permissions:
            MapSet.new([
              %Domain.Auth.Permission{resource: Domain.EmailOTP.AuthProvider, action: :manage},
              %Domain.Auth.Permission{resource: Domain.Userpass.AuthProvider, action: :manage},
              %Domain.Auth.Permission{resource: Domain.OIDC.AuthProvider, action: :manage},
              %Domain.Auth.Permission{resource: Domain.Google.AuthProvider, action: :manage},
              %Domain.Auth.Permission{resource: Domain.Entra.AuthProvider, action: :manage}
            ])
        }

        {:ok, email_otp} =
          create_auth_provider(EmailOTP.AuthProvider, %{name: "Email OTP"}, system_subject)

        {:ok, userpass} =
          create_auth_provider(
            Userpass.AuthProvider,
            %{name: "Username & Password"},
            system_subject
          )

        {:ok, oidc} =
          create_auth_provider(
            OIDC.AuthProvider,
            %{
              is_verified: true,
              name: "OIDC",
              issuer: "https://common.auth0.com",
              client_id: "CLIENT_ID",
              client_secret: "CLIENT_SECRET",
              discovery_document_uri: "https://common.auth0.com/.well-known/openid-configuration",
              scope: "openid email profile groups"
            },
            system_subject
          )

        {:ok, google} =
          create_auth_provider(
            Google.AuthProvider,
            %{
              is_verified: true,
              name: "Google",
              issuer: "https://accounts.google.com",
              domain: "firezone.dev"
            },
            system_subject
          )

        {:ok, entra} =
          create_auth_provider(
            Entra.AuthProvider,
            %{
              is_verified: true,
              name: "Entra",
              issuer: "https://login.microsoftonline.com/#{entra_tenant_id()}/v2.0",
              tenant_id: entra_tenant_id()
            },
            system_subject
          )

        {email_otp, oidc, userpass, google, entra}
      else
        # Legacy auth system
        {:ok, email} =
          Auth.create_provider(account, %{
            name: "Email",
            adapter: :email,
            adapter_config: %{}
          })

        {:ok, oidc} =
          Auth.create_provider(account, %{
            name: "OIDC",
            adapter: :openid_connect,
            adapter_config: %{
              "client_id" => "CLIENT_ID",
              "client_secret" => "CLIENT_SECRET",
              "response_type" => "code",
              "scope" => "openid email name groups",
              "discovery_document_uri" =>
                "https://common.auth0.com/.well-known/openid-configuration"
            }
          })

        {:ok, userpass} =
          Auth.create_provider(account, %{
            name: "UserPass",
            adapter: :userpass,
            adapter_config: %{}
          })

        {email, oidc, userpass, nil, nil}
      end

    {:ok, _other_email_provider} =
      Auth.create_provider(other_account, %{
        name: "email",
        adapter: :email,
        adapter_config: %{}
      })

    {:ok, other_userpass_provider} =
      Auth.create_provider(other_account, %{
        name: "UserPass",
        adapter: :userpass,
        adapter_config: %{}
      })

    unprivileged_actor_email = "firezone-unprivileged-1@localhost.local"
    admin_actor_email = "firezone@localhost.local"

    {:ok, unprivileged_actor} =
      Actors.create_actor(account, %{
        type: :account_user,
        name: "Firezone Unprivileged"
      })

    unprivileged_actor =
      if new_auth? do
        # In NEW_AUTH, actors must have emails
        unprivileged_actor
        |> Ecto.Changeset.change(email: unprivileged_actor_email)
        |> Repo.update!()
      else
        unprivileged_actor
      end

    other_actors_with_emails =
      for i <- 1..10 do
        email = "user-#{i}@localhost.local"

        {:ok, actor} =
          Actors.create_actor(account, %{
            type: :account_user,
            name: "Firezone Unprivileged #{i}"
          })

        actor =
          if new_auth? do
            # In NEW_AUTH, actors must have emails
            actor
            |> Ecto.Changeset.change(email: email)
            |> Repo.update!()
          else
            actor
          end

        {actor, email}
      end

    other_actors = Enum.map(other_actors_with_emails, fn {actor, _email} -> actor end)

    {:ok, admin_actor} =
      Actors.create_actor(account, %{
        type: :account_admin_user,
        name: "Firezone Admin"
      })

    admin_actor =
      if new_auth? do
        # In NEW_AUTH, actors must have emails
        admin_actor
        |> Ecto.Changeset.change(email: admin_actor_email)
        |> Repo.update!()
      else
        admin_actor
      end

    {:ok, service_account_actor} =
      Actors.create_actor(account, %{
        "type" => :service_account,
        "name" => "Backup Manager"
      })

    {unprivileged_actor_email_identity, unprivileged_actor_userpass_identity} =
      if new_auth? do
        # New auth system: create ONE identity for local auth (works with both EmailOTP and Userpass)
        password_hash = Domain.Crypto.hash(:argon2, "Firezone1234")

        {:ok, identity} =
          Repo.insert(%Auth.Identity{
            actor_id: unprivileged_actor.id,
            account_id: account.id,
            issuer: "firezone",
            idp_id: unprivileged_actor_email,
            name: "Firezone Unprivileged",
            password_hash: password_hash,
            created_by: :system
          })

        # Return the same identity for both email and userpass (same user, different auth methods)
        {identity, identity}
      else
        # Legacy auth system uses Auth module
        {:ok, email_identity} =
          Auth.create_identity(unprivileged_actor, email_provider, %{
            provider_identifier: unprivileged_actor_email,
            provider_identifier_confirmation: unprivileged_actor_email
          })

        {:ok, userpass_identity} =
          Auth.create_identity(unprivileged_actor, userpass_provider, %{
            provider_identifier: unprivileged_actor_email,
            provider_virtual_state: %{
              "password" => "Firezone1234",
              "password_confirmation" => "Firezone1234"
            }
          })

        {email_identity, userpass_identity}
      end

    _unprivileged_actor_userpass_identity =
      maybe_repo_update.(unprivileged_actor_userpass_identity,
        id: "7da7d1cd-111c-44a7-b5ac-4027b9d230e5"
      )

    {admin_actor_email_identity, _admin_actor_userpass_identity, admin_actor_oidc_identity} =
      if new_auth? do
        # New auth system: create ONE identity for local auth (EmailOTP + Userpass)
        password_hash = Domain.Crypto.hash(:argon2, "Firezone1234")

        {:ok, local_identity} =
          Repo.insert(%Auth.Identity{
            actor_id: admin_actor.id,
            account_id: account.id,
            issuer: "firezone",
            idp_id: admin_actor_email,
            name: "Firezone Admin",
            password_hash: password_hash,
            created_by: :system
          })

        # Create separate OIDC identity (different issuer)
        {:ok, oidc_identity} =
          Repo.insert(%Auth.Identity{
            actor_id: admin_actor.id,
            account_id: account.id,
            issuer: "https://common.auth0.com",
            idp_id: admin_actor_email,
            name: "Firezone Admin",
            created_by: :system
          })

        {:ok, _google_identity} =
          Repo.insert(%Auth.Identity{
            actor_id: admin_actor.id,
            account_id: account.id,
            issuer: "https://accounts.google.com",
            idp_id: google_idp_id(),
            name: "Firezone Admin",
            created_by: :system
          })

        {:ok, _entra_identity} =
          Repo.insert(%Auth.Identity{
            actor_id: admin_actor.id,
            account_id: account.id,
            issuer: "https://login.microsoftonline.com/#{entra_tenant_id()}/v2.0",
            idp_id: entra_idp_id(),
            name: "Firezone Admin",
            created_by: :system
          })

        {local_identity, local_identity, oidc_identity}
      else
        # Legacy auth system
        {:ok, email_identity} =
          Auth.create_identity(admin_actor, email_provider, %{
            provider_identifier: admin_actor_email,
            provider_identifier_confirmation: admin_actor_email
          })

        {:ok, userpass_identity} =
          Auth.create_identity(admin_actor, userpass_provider, %{
            provider_identifier: admin_actor_email,
            provider_virtual_state: %{
              "password" => "Firezone1234",
              "password_confirmation" => "Firezone1234"
            }
          })

        {:ok, oidc_identity} =
          Auth.create_identity(admin_actor, oidc_provider, %{
            provider_identifier: admin_actor_email,
            provider_identifier_confirmation: admin_actor_email
          })

        {email_identity, userpass_identity, oidc_identity}
      end

    unless new_auth? do
      # Legacy system: update OIDC identity with provider-specific fields
      admin_actor_oidc_identity
      |> Ecto.Changeset.change(
        created_by: :provider,
        provider_id: oidc_provider.id,
        provider_identifier: admin_actor_email,
        provider_state: %{"claims" => %{"email" => admin_actor_email, "group" => "users"}}
      )
      |> Repo.update!()
    end

    for {actor, email} <- other_actors_with_emails do
      {:ok, identity} =
        if new_auth? do
          Repo.insert(%Auth.Identity{
            actor_id: actor.id,
            account_id: account.id,
            issuer: "https://common.auth0.com",
            idp_id: email,
            name: actor.name,
            created_by: :system
          })
        else
          Auth.create_identity(actor, oidc_provider, %{
            provider_identifier: email,
            provider_identifier_confirmation: email
          })
        end

      identity =
        unless new_auth? do
          # Legacy system: update identity with provider-specific fields
          identity
          |> Ecto.Changeset.change(
            created_by: :provider,
            provider_id: oidc_provider.id,
            provider_identifier: email,
            provider_state: %{"claims" => %{"email" => email, "group" => "users"}}
          )
          |> Repo.update!()
        else
          # New auth system: identity is already created with all necessary fields
          identity
        end

      context = %Auth.Context{
        type: :browser,
        user_agent: "Windows/10.0.22631 seeds/1",
        remote_ip: {172, 28, 0, 100},
        remote_ip_location_region: "UA",
        remote_ip_location_city: "Kyiv",
        remote_ip_location_lat: 50.4333,
        remote_ip_location_lon: 30.5167
      }

      {:ok, token} =
        Auth.create_token(identity, context, "n", nil)

      {:ok, subject} = Auth.build_subject(token, context)

      count = Enum.random([1, 1, 1, 1, 1, 2, 2, 2, 3, 3, 240])

      for i <- 0..count do
        user_agent =
          Enum.random([
            "iOS/12.7 (iPhone) connlib/1.5.0",
            "Android/14 connlib/1.4.1",
            "Windows/10.0.22631 connlib/1.3.412",
            "Ubuntu/22.4.0 connlib/1.2.2"
          ])

        client_name = String.split(user_agent, "/") |> List.first()

        {:ok, _client} =
          Domain.Clients.upsert_client(
            %{
              name: "My #{client_name} #{i}",
              external_id: Ecto.UUID.generate(),
              public_key: :crypto.strong_rand_bytes(32) |> Base.encode64(),
              identifier_for_vendor: Ecto.UUID.generate()
            },
            %{
              subject
              | context: %{subject.context | user_agent: user_agent}
            }
          )
      end
    end

    # Other Account Users
    other_unprivileged_actor_email = "other-unprivileged-1@localhost.local"
    other_admin_actor_email = "other@localhost.local"

    {:ok, other_unprivileged_actor} =
      Actors.create_actor(other_account, %{
        type: :account_user,
        name: "Other Unprivileged"
      })

    {:ok, other_admin_actor} =
      Actors.create_actor(other_account, %{
        type: :account_admin_user,
        name: "Other Admin"
      })

    {:ok, _other_unprivileged_actor_userpass_identity} =
      Auth.create_identity(other_unprivileged_actor, other_userpass_provider, %{
        provider_identifier: other_unprivileged_actor_email,
        provider_virtual_state: %{
          "password" => "Firezone1234",
          "password_confirmation" => "Firezone1234"
        }
      })

    {:ok, _other_admin_actor_userpass_identity} =
      Auth.create_identity(other_admin_actor, other_userpass_provider, %{
        provider_identifier: other_admin_actor_email,
        provider_virtual_state: %{
          "password" => "Firezone1234",
          "password_confirmation" => "Firezone1234"
        }
      })

    unprivileged_actor_context = %Auth.Context{
      type: :browser,
      user_agent: "iOS/18.1.0 connlib/1.3.5",
      remote_ip: {172, 28, 0, 100},
      remote_ip_location_region: "UA",
      remote_ip_location_city: "Kyiv",
      remote_ip_location_lat: 50.4333,
      remote_ip_location_lon: 30.5167
    }

    nonce = "n"

    {:ok, unprivileged_actor_token} =
      Auth.create_token(unprivileged_actor_email_identity, unprivileged_actor_context, nonce, nil)

    {:ok, unprivileged_subject} =
      Auth.build_subject(unprivileged_actor_token, unprivileged_actor_context)

    admin_actor_context = %Auth.Context{
      type: :browser,
      user_agent: "Mac OS/14.1.2 connlib/1.2.1",
      remote_ip: {100, 64, 100, 58},
      remote_ip_location_region: "UA",
      remote_ip_location_city: "Kyiv",
      remote_ip_location_lat: 50.4333,
      remote_ip_location_lon: 30.5167
    }

    {:ok, admin_actor_token} =
      Auth.create_token(admin_actor_email_identity, admin_actor_context, nonce, nil)

    {:ok, admin_subject} =
      Auth.build_subject(admin_actor_token, admin_actor_context)

    {:ok, service_account_actor_encoded_token} =
      Auth.create_service_account_token(
        service_account_actor,
        %{
          "name" => "tok-#{Ecto.UUID.generate()}",
          "expires_at" => DateTime.utc_now() |> DateTime.add(365, :day)
        },
        admin_subject
      )

    {unprivileged_actor_email_token, admin_actor_email_token} =
      if new_auth? do
        # New auth system: email tokens are generated during sign-in flow, not pre-generated
        {"<generated during sign-in>", "<generated during sign-in>"}
      else
        # Legacy system: pre-generate email tokens
        {:ok, unprivileged_identity_with_token} =
          Domain.Auth.Adapters.Email.request_sign_in_token(
            unprivileged_actor_email_identity,
            unprivileged_actor_context
          )

        unprivileged_token =
          unprivileged_identity_with_token.provider_virtual_state.nonce <>
            unprivileged_identity_with_token.provider_virtual_state.fragment

        {:ok, admin_identity_with_token} =
          Domain.Auth.Adapters.Email.request_sign_in_token(
            admin_actor_email_identity,
            admin_actor_context
          )

        admin_token =
          admin_identity_with_token.provider_virtual_state.nonce <>
            admin_identity_with_token.provider_virtual_state.fragment

        {unprivileged_token, admin_token}
      end

    IO.puts("Created users: ")

    for {type, login, password, email_token} <- [
          {unprivileged_actor.type, unprivileged_actor_email, "Firezone1234",
           unprivileged_actor_email_token},
          {admin_actor.type, admin_actor_email, "Firezone1234", admin_actor_email_token}
        ] do
      IO.puts(
        "  #{login}, #{type}, password: #{password}, email token: #{email_token} (exp in 15m)"
      )
    end

    IO.puts("  #{service_account_actor.name} token: #{service_account_actor_encoded_token}")
    IO.puts("")

    {:ok, user_iphone} =
      Domain.Clients.upsert_client(
        %{
          name: "FZ User iPhone",
          external_id: Ecto.UUID.generate(),
          public_key: :crypto.strong_rand_bytes(32) |> Base.encode64(),
          identifier_for_vendor: "APPL-#{Ecto.UUID.generate()}"
        },
        %{
          unprivileged_subject
          | context: %{
              unprivileged_subject.context
              | user_agent: "iOS/12.7 (iPhone) connlib/0.7.412"
            }
        }
      )

    {:ok, _user_android_phone} =
      Domain.Clients.upsert_client(
        %{
          name: "FZ User Android",
          external_id: Ecto.UUID.generate(),
          public_key: :crypto.strong_rand_bytes(32) |> Base.encode64(),
          identifier_for_vendor: "GOOG-#{Ecto.UUID.generate()}"
        },
        %{
          unprivileged_subject
          | context: %{unprivileged_subject.context | user_agent: "Android/14 connlib/0.7.412"}
        }
      )

    {:ok, _user_windows_laptop} =
      Domain.Clients.upsert_client(
        %{
          name: "FZ User Surface",
          external_id: Ecto.UUID.generate(),
          public_key: :crypto.strong_rand_bytes(32) |> Base.encode64(),
          device_uuid: "WIN-#{Ecto.UUID.generate()}"
        },
        %{
          unprivileged_subject
          | context: %{
              unprivileged_subject.context
              | user_agent: "Windows/10.0.22631 connlib/0.7.412"
            }
        }
      )

    {:ok, _user_linux_laptop} =
      Domain.Clients.upsert_client(
        %{
          name: "FZ User Rendering Station",
          external_id: Ecto.UUID.generate(),
          public_key: :crypto.strong_rand_bytes(32) |> Base.encode64(),
          device_uuid: "UB-#{Ecto.UUID.generate()}"
        },
        %{
          unprivileged_subject
          | context: %{unprivileged_subject.context | user_agent: "Ubuntu/22.4.0 connlib/0.7.412"}
        }
      )

    {:ok, _admin_iphone} =
      Domain.Clients.upsert_client(
        %{
          name: "FZ Admin Laptop",
          external_id: Ecto.UUID.generate(),
          public_key: :crypto.strong_rand_bytes(32) |> Base.encode64(),
          device_serial: "FVFHF246Q72Z",
          device_uuid: "#{Ecto.UUID.generate()}"
        },
        %{
          admin_subject
          | context: %{admin_subject.context | user_agent: "Mac OS/14.5 connlib/0.7.412"}
        }
      )

    IO.puts("Clients created")
    IO.puts("")

    IO.puts("Created Actor Groups: ")

    # Collect all actors for this account
    all_actors = [
      unprivileged_actor,
      admin_actor,
      service_account_actor | other_actors
    ]

    actor_ids = Enum.map(all_actors, & &1.id)
    # Total number of actors
    max_members = length(actor_ids)

    # Create groups in chunks and collect their IDs
    group_ids =
      1..10_000
      # Process in chunks to manage memory
      |> Enum.chunk_every(1000)
      |> Enum.flat_map(fn chunk ->
        group_attrs =
          Enum.map(chunk, fn i ->
            base_attrs = %{
              name: "#{Domain.Accounts.generate_unique_slug()}-#{i}",
              type: :static,
              created_by: :provider,
              created_by_subject: %{"name" => "Provider", "email" => nil},
              account_id: admin_subject.account.id,
              inserted_at: DateTime.utc_now(),
              updated_at: DateTime.utc_now()
            }

            # In legacy mode, link groups to providers; in NEW_AUTH, groups are provider-agnostic
            if new_auth? do
              base_attrs
            else
              Map.merge(base_attrs, %{
                provider_id: oidc_provider.id,
                provider_identifier: Ecto.UUID.generate()
              })
            end
          end)

        {_, inserted_groups} =
          Repo.insert_all(
            Domain.Actors.Group,
            group_attrs,
            returning: [:id]
          )

        Enum.map(inserted_groups, & &1.id)
      end)

    # Create memberships
    memberships =
      group_ids
      |> Enum.chunk_every(1000)
      |> Enum.flat_map(fn group_chunk ->
        Enum.flat_map(group_chunk, fn group_id ->
          # Determine random number of members (1 to max_members)
          num_members = :rand.uniform(max_members)

          # Select random actor IDs
          member_ids =
            actor_ids
            # Uses seeded random
            |> Enum.shuffle()
            |> Enum.take(num_members)

          # Create membership attributes
          Enum.map(member_ids, fn actor_id ->
            %{
              group_id: group_id,
              actor_id: actor_id,
              account_id: admin_subject.account.id
            }
          end)
        end)
      end)

    # Bulk insert memberships
    memberships
    |> Enum.chunk_every(1000)
    |> Enum.each(fn chunk ->
      Repo.insert_all(Domain.Actors.Membership, chunk)
    end)

    {:ok, eng_group} = Actors.create_group(%{name: "Engineering", type: :static}, admin_subject)
    {:ok, finance_group} = Actors.create_group(%{name: "Finance", type: :static}, admin_subject)

    {:ok, synced_group} =
      Actors.create_group(
        %{name: "Group:Synced Group with long name", type: :static},
        admin_subject
      )

    for group <- [eng_group, finance_group, synced_group] do
      IO.puts("  Name: #{group.name}  ID: #{group.id}")
    end

    eng_group
    |> Repo.preload(:memberships)
    |> Actors.update_group(
      %{memberships: [%{actor_id: admin_subject.actor.id}]},
      admin_subject
    )

    finance_group
    |> Repo.preload(:memberships)
    |> Actors.update_group(
      %{memberships: [%{actor_id: unprivileged_subject.actor.id}]},
      admin_subject
    )

    synced_group
    |> Repo.preload(:memberships)
    |> Actors.update_group(
      %{
        memberships: [
          %{actor_id: admin_subject.actor.id},
          %{actor_id: unprivileged_subject.actor.id}
        ]
      },
      admin_subject
    )

    unless new_auth? do
      # Legacy system: link group to provider
      synced_group
      |> Ecto.Changeset.change(
        created_by: :provider,
        provider_id: oidc_provider.id,
        provider_identifier: "dummy_oidc_group_id"
      )
      |> Repo.update!()
    end

    unless new_auth? do
      # Legacy system: update provider last_synced_at
      oidc_provider
      |> Ecto.Changeset.change(last_synced_at: DateTime.utc_now())
      |> Repo.update!()
    end

    for name <- [
          "Group:gcp-logging-viewers",
          "Group:gcp-security-admins",
          "Group:gcp-organization-admins",
          "OU:Admins",
          "OU:Product",
          "Group:Engineering",
          "Group:gcp-developers"
        ] do
      {:ok, group} = Actors.create_group(%{name: name, type: :static}, admin_subject)

      group
      |> Repo.preload(:memberships)
      |> Actors.update_group(
        %{memberships: [%{actor_id: admin_subject.actor.id}]},
        admin_subject
      )
    end

    IO.puts("")

    {:ok, global_relay_group} =
      Relays.create_global_group(%{name: "fz-global-relays"})

    {:ok, global_relay_group_token} =
      Tokens.create_token(%{
        "type" => :relay_group,
        "secret_fragment" => Domain.Crypto.random_token(32, encoder: :hex32),
        "relay_group_id" => global_relay_group.id
      })

    global_relay_group_token =
      global_relay_group_token
      |> maybe_repo_update.(
        id: "e82fcdc1-057a-4015-b90b-3b18f0f28053",
        secret_salt: "lZWUdgh-syLGVDsZEu_29A",
        secret_fragment: "C14NGA87EJRR03G4QPR07A9C6G784TSSTHSF4TI5T0GD8D6L0VRG====",
        secret_hash: "c3c9a031ae98f111ada642fddae546de4e16ceb85214ab4f1c9d0de1fc472797"
      )

    global_relay_group_encoded_token = Tokens.encode_fragment!(global_relay_group_token)

    IO.puts("Created global relay groups:")
    IO.puts("  #{global_relay_group.name} token: #{global_relay_group_encoded_token}")

    IO.puts("")

    relay_context = %Auth.Context{
      type: :relay_group,
      user_agent: "Ubuntu/14.04 connlib/0.7.412",
      remote_ip: {100, 64, 100, 58}
    }

    {:ok, global_relay} =
      Relays.upsert_relay(
        global_relay_group,
        %{
          ipv4: {189, 172, 72, 111},
          ipv6: {0, 0, 0, 0, 0, 0, 0, 1}
        },
        relay_context
      )

    for i <- 1..5 do
      {:ok, _global_relay} =
        Relays.upsert_relay(
          global_relay_group,
          %{
            ipv4: {189, 172, 72, 111 + i},
            ipv6: {0, 0, 0, 0, 0, 0, 0, i}
          },
          %{relay_context | remote_ip: %Postgrex.INET{address: {189, 172, 72, 111 + i}}}
        )
    end

    IO.puts("Created global relays:")
    IO.puts("  Group #{global_relay_group.name}:")
    IO.puts("    IPv4: #{global_relay.ipv4} IPv6: #{global_relay.ipv6}")
    IO.puts("")

    relay_group =
      account
      |> Relays.Group.Changeset.create(%{name: "mycorp-aws-relays"}, admin_subject)
      |> Repo.insert!()

    {:ok, relay_group_token} =
      Tokens.create_token(%{
        "type" => :relay_group,
        "secret_fragment" => Domain.Crypto.random_token(32, encoder: :hex32),
        "account_id" => admin_subject.account.id,
        "relay_group_id" => global_relay_group.id
      })

    relay_group_token =
      relay_group_token
      |> maybe_repo_update.(
        id: "549c4107-1492-4f8f-a4ec-a9d2a66d8aa9",
        secret_salt: "jaJwcwTRhzQr15SgzTB2LA",
        secret_fragment: "PU5AITE1O8VDVNMHMOAC77DIKMOGTDIA672S6G1AB02OS34H5ME0====",
        secret_hash: "af133f7efe751ca978ec3e5fadf081ce9ab50138ff52862395858c3d2c11c0c5"
      )

    relay_group_encoded_token = Tokens.encode_fragment!(relay_group_token)

    IO.puts("Created relay groups:")
    IO.puts("  #{relay_group.name} token: #{relay_group_encoded_token}")
    IO.puts("")

    {:ok, relay} =
      Relays.upsert_relay(
        relay_group,
        %{
          ipv4: {189, 172, 73, 111},
          ipv6: {0, 0, 0, 0, 0, 0, 0, 1}
        },
        %Auth.Context{
          type: :relay_group,
          user_agent: "iOS/12.7 (iPhone) connlib/0.7.412",
          remote_ip: %Postgrex.INET{address: {189, 172, 73, 111}}
        }
      )

    for i <- 1..5 do
      {:ok, _relay} =
        Relays.upsert_relay(
          relay_group,
          %{
            ipv4: {189, 172, 73, 111 + i},
            ipv6: {0, 0, 0, 0, 0, 0, 0, i}
          },
          %Auth.Context{
            type: :relay_group,
            user_agent: "iOS/12.7 (iPhone) connlib/0.7.412",
            remote_ip: %Postgrex.INET{address: {189, 172, 73, 111}}
          }
        )
    end

    IO.puts("Created relays:")
    IO.puts("  Group #{relay_group.name}:")
    IO.puts("    IPv4: #{relay.ipv4} IPv6: #{relay.ipv6}")
    IO.puts("")

    gateway_group =
      account
      |> Gateways.Group.Changeset.create(
        %{name: "mycro-aws-gws", tokens: [%{}]},
        admin_subject
      )
      |> Repo.insert!()

    {:ok, gateway_group_token} =
      Tokens.create_token(
        %{
          "type" => :gateway_group,
          "secret_fragment" => Domain.Crypto.random_token(32, encoder: :hex32),
          "account_id" => admin_subject.account.id,
          "gateway_group_id" => gateway_group.id
        },
        admin_subject
      )

    gateway_group_token =
      gateway_group_token
      |> maybe_repo_update.(
        id: "2274560b-e97b-45e4-8b34-679c7617e98d",
        secret_salt: "uQyisyqrvYIIitMXnSJFKQ",
        secret_fragment: "O02L7US2J3VINOMPR9J6IL88QIQP6UO8AQVO6U5IPL0VJC22JGH0====",
        secret_hash: "876f20e8d4de25d5ffac40733f280782a7d8097347d77415ab6e4e548f13d2ee"
      )

    gateway_group_encoded_token = Tokens.encode_fragment!(gateway_group_token)

    IO.puts("Created gateway groups:")
    IO.puts("  #{gateway_group.name} token: #{gateway_group_encoded_token}")
    IO.puts("")

    {:ok, gateway1} =
      Gateways.upsert_gateway(
        gateway_group,
        %{
          external_id: Ecto.UUID.generate(),
          name: "gw-#{Domain.Crypto.random_token(5, encoder: :user_friendly)}",
          public_key: :crypto.strong_rand_bytes(32) |> Base.encode64()
        },
        %Auth.Context{
          type: :gateway_group,
          user_agent: "iOS/12.7 (iPhone) connlib/0.7.412",
          remote_ip: %Postgrex.INET{address: {189, 172, 73, 153}}
        }
      )

    {:ok, gateway2} =
      Gateways.upsert_gateway(
        gateway_group,
        %{
          external_id: Ecto.UUID.generate(),
          name: "gw-#{Domain.Crypto.random_token(5, encoder: :user_friendly)}",
          public_key: :crypto.strong_rand_bytes(32) |> Base.encode64()
        },
        %Auth.Context{
          type: :gateway_group,
          user_agent: "iOS/12.7 (iPhone) connlib/0.7.412",
          remote_ip: %Postgrex.INET{address: {164, 112, 78, 62}}
        }
      )

    for i <- 1..10 do
      {:ok, _gateway} =
        Gateways.upsert_gateway(
          gateway_group,
          %{
            external_id: Ecto.UUID.generate(),
            name: "gw-#{Domain.Crypto.random_token(5, encoder: :user_friendly)}",
            public_key: :crypto.strong_rand_bytes(32) |> Base.encode64()
          },
          %Auth.Context{
            type: :gateway_group,
            user_agent: "iOS/12.7 (iPhone) connlib/0.7.412",
            remote_ip: %Postgrex.INET{address: {164, 112, 78, 62 + i}}
          }
        )
    end

    IO.puts("Created gateways:")
    gateway_name = "#{gateway_group.name}-#{gateway1.name}"
    IO.puts("  #{gateway_name}:")
    IO.puts("    External UUID: #{gateway1.external_id}")
    IO.puts("    Public Key: #{gateway1.public_key}")
    IO.puts("    IPv4: #{gateway1.ipv4} IPv6: #{gateway1.ipv6}")
    IO.puts("")

    gateway_name = "#{gateway_group.name}-#{gateway2.name}"
    IO.puts("  #{gateway_name}:")
    IO.puts("    External UUID: #{gateway1.external_id}")
    IO.puts("    Public Key: #{gateway2.public_key}")
    IO.puts("    IPv4: #{gateway2.ipv4} IPv6: #{gateway2.ipv6}")
    IO.puts("")

    {:ok, dns_google_resource} =
      Resources.create_resource(
        %{
          type: :dns,
          name: "foobar.com",
          address: "foobar.com",
          address_description: "https://foobar.com/",
          connections: [%{gateway_group_id: gateway_group.id}],
          filters: []
        },
        admin_subject
      )

    {:ok, firez_one} =
      Resources.create_resource(
        %{
          type: :dns,
          name: "**.firez.one",
          address: "**.firez.one",
          address_description: "https://firez.one/",
          connections: [%{gateway_group_id: gateway_group.id}],
          filters: []
        },
        admin_subject
      )

    {:ok, firezone_dev} =
      Resources.create_resource(
        %{
          type: :dns,
          name: "*.firezone.dev",
          address: "*.firezone.dev",
          address_description: "https://firezone.dev/",
          connections: [%{gateway_group_id: gateway_group.id}],
          filters: []
        },
        admin_subject
      )

    {:ok, example_dns} =
      Resources.create_resource(
        %{
          type: :dns,
          name: "example.com",
          address: "example.com",
          address_description: "https://example.com:1234/",
          connections: [%{gateway_group_id: gateway_group.id}],
          filters: []
        },
        admin_subject
      )

    {:ok, ip6only} =
      Resources.create_resource(
        %{
          type: :dns,
          name: "ip6only",
          address: "ip6only.me",
          address_description: "https://ip6only.me/",
          connections: [%{gateway_group_id: gateway_group.id}],
          filters: []
        },
        admin_subject
      )

    {:ok, address_description_null_resource} =
      Resources.create_resource(
        %{
          type: :dns,
          name: "Example",
          address: "*.example.com",
          connections: [%{gateway_group_id: gateway_group.id}],
          filters: []
        },
        admin_subject
      )

    {:ok, dns_gitlab_resource} =
      Resources.create_resource(
        %{
          type: :dns,
          name: "gitlab.mycorp.com",
          address: "gitlab.mycorp.com",
          address_description: "https://gitlab.mycorp.com/",
          connections: [%{gateway_group_id: gateway_group.id}],
          filters: [
            %{ports: ["80", "433"], protocol: :tcp},
            %{ports: ["53"], protocol: :udp},
            %{protocol: :icmp}
          ]
        },
        admin_subject
      )

    {:ok, ip_resource} =
      Resources.create_resource(
        %{
          type: :ip,
          name: "Public DNS",
          address: "1.2.3.4",
          address_description: "http://1.2.3.4:3000/",
          connections: [%{gateway_group_id: gateway_group.id}],
          filters: [
            %{ports: ["80", "433"], protocol: :tcp},
            %{ports: ["53"], protocol: :udp},
            %{protocol: :icmp}
          ]
        },
        admin_subject
      )

    {:ok, cidr_resource} =
      Resources.create_resource(
        %{
          type: :cidr,
          name: "MyCorp Network",
          address: "172.20.0.1/16",
          address_description: "172.20.0.1/16",
          connections: [%{gateway_group_id: gateway_group.id}],
          filters: []
        },
        admin_subject
      )

    {:ok, ipv6_resource} =
      Resources.create_resource(
        %{
          type: :cidr,
          name: "MyCorp Network (IPv6)",
          address: "172:20:0::1/64",
          address_description: "172:20:0::1/64",
          connections: [%{gateway_group_id: gateway_group.id}],
          filters: []
        },
        admin_subject
      )

    {:ok, dns_httpbin_resource} =
      Resources.create_resource(
        %{
          type: :dns,
          name: "**.httpbin",
          address: "**.httpbin",
          address_description: "http://httpbin/",
          connections: [%{gateway_group_id: gateway_group.id}],
          filters: [
            %{ports: ["80", "433"], protocol: :tcp},
            %{ports: ["53"], protocol: :udp},
            %{protocol: :icmp}
          ]
        },
        admin_subject
      )

    {:ok, search_domain_resource} =
      Resources.create_resource(
        %{
          type: :dns,
          name: "**.httpbin.search.test",
          address: "**.httpbin.search.test",
          address_description: "http://httpbin/",
          connections: [%{gateway_group_id: gateway_group.id}],
          filters: [
            %{ports: ["80", "433"], protocol: :tcp},
            %{ports: ["53"], protocol: :udp},
            %{protocol: :icmp}
          ]
        },
        admin_subject
      )

    IO.puts("Created resources:")
    IO.puts("  #{dns_google_resource.address} - DNS - gateways: #{gateway_name}")
    IO.puts("  #{address_description_null_resource.address} - DNS - gateways: #{gateway_name}")
    IO.puts("  #{dns_gitlab_resource.address} - DNS - gateways: #{gateway_name}")
    IO.puts("  #{firez_one.address} - DNS - gateways: #{gateway_name}")
    IO.puts("  #{firezone_dev.address} - DNS - gateways: #{gateway_name}")
    IO.puts("  #{example_dns.address} - DNS - gateways: #{gateway_name}")
    IO.puts("  #{ip_resource.address} - IP - gateways: #{gateway_name}")
    IO.puts("  #{cidr_resource.address} - CIDR - gateways: #{gateway_name}")
    IO.puts("  #{ipv6_resource.address} - CIDR - gateways: #{gateway_name}")
    IO.puts("  #{dns_httpbin_resource.address} - DNS - gateways: #{gateway_name}")
    IO.puts("  #{search_domain_resource.address} - DNS - gateways: #{gateway_name}")
    IO.puts("")

    {:ok, policy} =
      Policies.create_policy(
        %{
          name: "All Access To Google",
          actor_group_id: everyone_group.id,
          resource_id: dns_google_resource.id
        },
        admin_subject
      )

    {:ok, _} =
      Policies.create_policy(
        %{
          name: "All Access To firez.one",
          actor_group_id: synced_group.id,
          resource_id: firez_one.id
        },
        admin_subject
      )

    {:ok, _} =
      Policies.create_policy(
        %{
          name: "All Access To firez.one",
          actor_group_id: everyone_group.id,
          resource_id: example_dns.id
        },
        admin_subject
      )

    {:ok, _} =
      Policies.create_policy(
        %{
          name: "All Access To firezone.dev",
          actor_group_id: everyone_group.id,
          resource_id: firezone_dev.id
        },
        admin_subject
      )

    {:ok, _} =
      Policies.create_policy(
        %{
          name: "All Access To ip6only.me",
          actor_group_id: synced_group.id,
          resource_id: ip6only.id
        },
        admin_subject
      )

    {:ok, _} =
      Policies.create_policy(
        %{
          name: "All access to Google",
          actor_group_id: everyone_group.id,
          resource_id: address_description_null_resource.id
        },
        admin_subject
      )

    {:ok, _} =
      Policies.create_policy(
        %{
          name: "Eng Access To Gitlab",
          actor_group_id: eng_group.id,
          resource_id: dns_gitlab_resource.id
        },
        admin_subject
      )

    {:ok, _} =
      Policies.create_policy(
        %{
          name: "All Access To Network",
          actor_group_id: synced_group.id,
          resource_id: cidr_resource.id
        },
        admin_subject
      )

    {:ok, _} =
      Policies.create_policy(
        %{
          name: "All Access To Network",
          actor_group_id: synced_group.id,
          resource_id: ipv6_resource.id
        },
        admin_subject
      )

    {:ok, _} =
      Policies.create_policy(
        %{
          name: "All Access To **.httpbin",
          actor_group_id: everyone_group.id,
          resource_id: dns_httpbin_resource.id
        },
        admin_subject
      )

    {:ok, _} =
      Policies.create_policy(
        %{
          name: "All Access To **.httpbin.search.test",
          actor_group_id: everyone_group.id,
          resource_id: search_domain_resource.id
        },
        admin_subject
      )

    IO.puts("Policies Created")
    IO.puts("")

    {:ok, unprivileged_subject_client_token} =
      Auth.create_token(
        unprivileged_actor_email_identity,
        %{unprivileged_actor_context | type: :client},
        nonce,
        nil
      )

    unprivileged_subject_client_token =
      maybe_repo_update.(unprivileged_subject_client_token,
        id: "7da7d1cd-111c-44a7-b5ac-4027b9d230e5",
        secret_salt: "kKKA7dtf3TJk0-1O2D9N1w",
        secret_fragment: "AiIy_6pBk-WLeRAPzzkCFXNqIZKWBs2Ddw_2vgIQvFg",
        secret_hash: "5c1d6795ea1dd08b6f4fd331eeaffc12032ba171d227f328446f2d26b96437e5"
      )

    IO.puts("Created client tokens:")

    IO.puts(
      "  #{unprivileged_actor_email} token: #{nonce <> Domain.Tokens.encode_fragment!(unprivileged_subject_client_token)}"
    )

    IO.puts("")

    membership =
      Repo.get_by(Domain.Actors.Membership,
        group_id: synced_group.id,
        actor_id: unprivileged_actor.id
      )

    {:ok, _flow} =
      Flows.create_flow(
        user_iphone,
        gateway1,
        cidr_resource.id,
        policy.id,
        membership.id,
        unprivileged_subject,
        unprivileged_subject.expires_at
      )
  end
end

Domain.Repo.Seeds.seed()

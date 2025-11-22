defmodule Domain.Repo.Seeds do
  @moduledoc """
  Seeds the database with initial data.
  """
  alias Domain.{
    Repo,
    Accounts,
    Auth,
    AuthProvider,
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
    Entra,
    ExternalIdentity
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
      Repo.insert(%AuthProvider{
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

    # Create auth providers for main account
    system_subject = %Auth.Subject{
      account: account,
      actor: %Actors.Actor{type: :system, id: Ecto.UUID.generate(), name: "System"},
      token_id: Ecto.UUID.generate(),
      auth_provider_id: nil,
      expires_at: DateTime.utc_now() |> DateTime.add(1, :hour),
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

    {:ok, _email_provider} =
      create_auth_provider(EmailOTP.AuthProvider, %{name: "Email OTP"}, system_subject)

    {:ok, _userpass_provider} =
      create_auth_provider(
        Userpass.AuthProvider,
        %{name: "Username & Password"},
        system_subject
      )

    {:ok, _oidc_provider} =
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

    {:ok, _google_provider} =
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

    {:ok, _entra_provider} =
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

    # Create auth providers for other_account
    other_system_subject = %Auth.Subject{
      account: other_account,
      actor: %Actors.Actor{type: :system, id: Ecto.UUID.generate(), name: "System"},
      token_id: Ecto.UUID.generate(),
      auth_provider_id: nil,
      expires_at: DateTime.utc_now() |> DateTime.add(1, :hour),
      context: %Auth.Context{type: :browser, remote_ip: {127, 0, 0, 1}, user_agent: "seeds/1"},
      permissions:
        MapSet.new([
          %Domain.Auth.Permission{resource: Domain.EmailOTP.AuthProvider, action: :manage},
          %Domain.Auth.Permission{resource: Domain.Userpass.AuthProvider, action: :manage}
        ])
    }

    {:ok, _other_email_provider} =
      create_auth_provider(EmailOTP.AuthProvider, %{name: "Email OTP"}, other_system_subject)

    {:ok, _other_userpass_provider} =
      create_auth_provider(
        Userpass.AuthProvider,
        %{name: "Username & Password"},
        other_system_subject
      )

    unprivileged_actor_email = "firezone-unprivileged-1@localhost.local"
    admin_actor_email = "firezone@localhost.local"

    {:ok, unprivileged_actor} =
      Repo.insert(%Actors.Actor{
        account_id: account.id,
        type: :account_user,
        name: "Firezone Unprivileged",
        email: unprivileged_actor_email,
        created_by: :system
      })

    other_actors_with_emails =
      for i <- 1..10 do
        email = "user-#{i}@localhost.local"

        {:ok, actor} =
          Repo.insert(%Actors.Actor{
            account_id: account.id,
            type: :account_user,
            name: "Firezone Unprivileged #{i}",
            email: email,
            created_by: :system
          })

        {actor, email}
      end

    other_actors = Enum.map(other_actors_with_emails, fn {actor, _email} -> actor end)

    {:ok, admin_actor} =
      Repo.insert(%Actors.Actor{
        account_id: account.id,
        type: :account_admin_user,
        name: "Firezone Admin",
        email: admin_actor_email,
        created_by: :system
      })

    {:ok, service_account_actor} =
      Repo.insert(%Actors.Actor{
        account_id: account.id,
        type: :service_account,
        name: "Backup Manager",
        created_by: :system
      })

    # Set password on actors (no identity needed for userpass/email)
    password_hash = Domain.Crypto.hash(:argon2, "Firezone1234")

    unprivileged_actor =
      unprivileged_actor
      |> Ecto.Changeset.change(password_hash: password_hash)
      |> Repo.update!()

    admin_actor =
      admin_actor
      |> Ecto.Changeset.change(password_hash: password_hash)
      |> Repo.update!()

    # Create separate OIDC identity (different issuer)
    {:ok, _admin_actor_oidc_identity} =
      Repo.insert(%ExternalIdentity{
        actor_id: admin_actor.id,
        account_id: account.id,
        issuer: "https://common.auth0.com",
        idp_id: "oidc:#{admin_actor_email}",
        name: "Firezone Admin",
        created_by: :system
      })

    {:ok, _google_identity} =
      Repo.insert(%ExternalIdentity{
        actor_id: admin_actor.id,
        account_id: account.id,
        issuer: "https://accounts.google.com",
        idp_id: "google:#{google_idp_id()}",
        name: "Firezone Admin",
        created_by: :system
      })

    {:ok, _entra_identity} =
      Repo.insert(%ExternalIdentity{
        actor_id: admin_actor.id,
        account_id: account.id,
        issuer: "https://login.microsoftonline.com/#{entra_tenant_id()}/v2.0",
        idp_id: "entra:#{entra_idp_id()}",
        name: "Firezone Admin",
        created_by: :system
      })

    for {actor, email} <- other_actors_with_emails do
      {:ok, identity} =
        Repo.insert(%ExternalIdentity{
          actor_id: actor.id,
          account_id: account.id,
          issuer: "https://common.auth0.com",
          idp_id: "oidc:#{email}",
          name: actor.name,
          created_by: :system
        })

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
        Repo.insert(%Tokens.Token{
          type: :browser,
          account_id: account.id,
          actor_id: identity.actor_id,
          expires_at: DateTime.utc_now() |> DateTime.add(90, :day),
          secret_nonce: "n",
          secret_fragment: Domain.Crypto.random_token(32),
          secret_salt: Domain.Crypto.random_token(16),
          secret_hash: "placeholder",
          created_by: :actor
        })

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
      Repo.insert(%Actors.Actor{
        account_id: other_account.id,
        type: :account_user,
        name: "Other Unprivileged",
        email: other_unprivileged_actor_email,
        created_by: :system
      })

    {:ok, other_admin_actor} =
      Repo.insert(%Actors.Actor{
        account_id: other_account.id,
        type: :account_admin_user,
        name: "Other Admin",
        email: other_admin_actor_email,
        created_by: :system
      })

    # Set password on other_account actors (no identity needed for userpass/email)
    password_hash = Domain.Crypto.hash(:argon2, "Firezone1234")

    _other_unprivileged_actor =
      other_unprivileged_actor
      |> Ecto.Changeset.change(password_hash: password_hash)
      |> Repo.update!()

    _other_admin_actor =
      other_admin_actor
      |> Ecto.Changeset.change(password_hash: password_hash)
      |> Repo.update!()

    _unprivileged_actor_context = %Auth.Context{
      type: :browser,
      user_agent: "iOS/18.1.0 connlib/1.3.5",
      remote_ip: {172, 28, 0, 100},
      remote_ip_location_region: "UA",
      remote_ip_location_city: "Kyiv",
      remote_ip_location_lat: 50.4333,
      remote_ip_location_lon: 30.5167
    }

    # Create client token for unprivileged actor so flows can reference it
    {:ok, unprivileged_client_token} =
      Repo.insert(%Tokens.Token{
        type: :client,
        account_id: account.id,
        actor_id: unprivileged_actor.id,
        secret_nonce: Ecto.UUID.generate(),
        secret_fragment: Ecto.UUID.generate(),
        secret_salt: Ecto.UUID.generate(),
        secret_hash: Ecto.UUID.generate(),
        expires_at: DateTime.utc_now() |> DateTime.add(7, :day),
        created_by: :system,
        created_by_subject: nil
      })

    # For seeds, create a system subject for admin operations
    # In real usage, subjects are created during sign-in flow
    admin_subject = %Auth.Subject{
      account: account,
      actor: admin_actor,
      token_id: Ecto.UUID.generate(),
      auth_provider_id: nil,
      expires_at: DateTime.utc_now() |> DateTime.add(1, :hour),
      context: %Auth.Context{
        type: :browser,
        remote_ip: {127, 0, 0, 1},
        user_agent: "seeds/1"
      },
      permissions: Auth.fetch_type_permissions!(admin_actor.type)
    }

    unprivileged_subject = %Auth.Subject{
      account: account,
      actor: unprivileged_actor,
      token_id: unprivileged_client_token.id,
      auth_provider_id: nil,
      expires_at: unprivileged_client_token.expires_at,
      context: %Auth.Context{
        type: :browser,
        remote_ip: {127, 0, 0, 1},
        user_agent: "seeds/1"
      },
      permissions: Auth.fetch_type_permissions!(unprivileged_actor.type)
    }

    {:ok, service_account_actor_encoded_token} =
      Auth.create_service_account_token(
        service_account_actor,
        %{
          "name" => "tok-#{Ecto.UUID.generate()}",
          "expires_at" => DateTime.utc_now() |> DateTime.add(365, :day)
        },
        admin_subject
      )

    # Email tokens are generated during sign-in flow, not pre-generated
    unprivileged_actor_email_token = "<generated during sign-in>"
    admin_actor_email_token = "<generated during sign-in>"

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
            %{
              name: "#{Domain.Accounts.generate_unique_slug()}-#{i}",
              type: :static,
              created_by: :system,
              created_by_subject: nil,
              account_id: admin_subject.account.id,
              inserted_at: DateTime.utc_now(),
              updated_at: DateTime.utc_now()
            }
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

    now = DateTime.utc_now()

    admin_subject_data = %{
      "ip" => to_string(:inet.ntoa(admin_subject.context.remote_ip)),
      "user_agent" => admin_subject.context.user_agent,
      "email" => admin_subject.actor.email,
      "id" => admin_subject.actor.id
    }

    group_values = [
      %{
        id: Ecto.UUID.generate(),
        name: "Engineering",
        type: :static,
        account_id: account.id,
        inserted_at: now,
        updated_at: now,
        created_by: :actor,
        created_by_subject: admin_subject_data
      },
      %{
        id: Ecto.UUID.generate(),
        name: "Finance",
        type: :static,
        account_id: account.id,
        inserted_at: now,
        updated_at: now,
        created_by: :actor,
        created_by_subject: admin_subject_data
      },
      %{
        id: Ecto.UUID.generate(),
        name: "Group:Synced Group with long name",
        type: :static,
        account_id: account.id,
        inserted_at: now,
        updated_at: now,
        created_by: :actor,
        created_by_subject: admin_subject_data
      }
    ]

    {3, group_results} =
      Repo.insert_all(Domain.Actors.Group, group_values, returning: [:id, :name])

    for group <- group_results do
      IO.puts("  Name: #{group.name}  ID: #{group.id}")
    end

    # Reload as structs for further use
    [eng_group_id, finance_group_id, synced_group_id] = Enum.map(group_results, & &1.id)

    eng_group = Repo.get!(Domain.Actors.Group, eng_group_id)
    finance_group = Repo.get!(Domain.Actors.Group, finance_group_id)
    synced_group = Repo.get!(Domain.Actors.Group, synced_group_id)

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

    {:ok, synced_group} =
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

    extra_group_names = [
      "Group:gcp-logging-viewers",
      "Group:gcp-security-admins",
      "Group:gcp-organization-admins",
      "OU:Admins",
      "OU:Product",
      "Group:Engineering",
      "Group:gcp-developers"
    ]

    extra_group_values =
      Enum.map(extra_group_names, fn name ->
        %{
          id: Ecto.UUID.generate(),
          name: name,
          type: :static,
          account_id: account.id,
          inserted_at: now,
          updated_at: now,
          created_by: :actor,
          created_by_subject: admin_subject_data
        }
      end)

    {_count, extra_group_results} =
      Repo.insert_all(Domain.Actors.Group, extra_group_values, returning: [:id])

    for %{id: group_id} <- extra_group_results do
      group = Repo.get!(Domain.Actors.Group, group_id)

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

alias Domain.{Repo, Accounts, Auth, Actors, Relays, Gateways, Resources, Policies, Flows, Tokens}

# Seeds can be run both with MIX_ENV=prod and MIX_ENV=test, for test env we don't have
# an adapter configured and creation of email provider will fail, so we will override it here.
System.put_env("OUTBOUND_EMAIL_ADAPTER", "Elixir.Swoosh.Adapters.Mailgun")

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
    slug: "firezone"
  })

account
|> Ecto.Changeset.change(
  features: %{
    flow_activities: true,
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

for account <- [account, other_account] do
  Domain.Resources.create_internet_resource(account)
end

{:ok, everyone_group} =
  Domain.Actors.create_managed_group(account, %{
    name: "Everyone",
    membership_rules: [%{operator: true}]
  })

{:ok, _everyone_group} =
  Domain.Actors.create_managed_group(other_account, %{
    name: "Everyone",
    membership_rules: [%{operator: true}]
  })

{:ok, email_provider} =
  Auth.create_provider(account, %{
    name: "Email",
    adapter: :email,
    adapter_config: %{}
  })

{:ok, oidc_provider} =
  Auth.create_provider(account, %{
    name: "OIDC",
    adapter: :openid_connect,
    adapter_config: %{
      "client_id" => "CLIENT_ID",
      "client_secret" => "CLIENT_SECRET",
      "response_type" => "code",
      "scope" => "openid email name groups",
      "discovery_document_uri" => "https://common.auth0.com/.well-known/openid-configuration"
    }
  })

{:ok, userpass_provider} =
  Auth.create_provider(account, %{
    name: "UserPass",
    adapter: :userpass,
    adapter_config: %{}
  })

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

other_actors =
  for i <- 1..10 do
    {:ok, actor} =
      Actors.create_actor(account, %{
        type: :account_user,
        name: "Firezone Unprivileged #{i}"
      })

    actor
  end

{:ok, admin_actor} =
  Actors.create_actor(account, %{
    type: :account_admin_user,
    name: "Firezone Admin"
  })

{:ok, service_account_actor} =
  Actors.create_actor(account, %{
    "type" => :service_account,
    "name" => "Backup Manager"
  })

{:ok, unprivileged_actor_email_identity} =
  Auth.create_identity(unprivileged_actor, email_provider, %{
    provider_identifier: unprivileged_actor_email,
    provider_identifier_confirmation: unprivileged_actor_email
  })

{:ok, unprivileged_actor_userpass_identity} =
  Auth.create_identity(unprivileged_actor, userpass_provider, %{
    provider_identifier: unprivileged_actor_email,
    provider_virtual_state: %{
      "password" => "Firezone1234",
      "password_confirmation" => "Firezone1234"
    }
  })

_unprivileged_actor_userpass_identity =
  maybe_repo_update.(unprivileged_actor_userpass_identity,
    id: "7da7d1cd-111c-44a7-b5ac-4027b9d230e5"
  )

{:ok, admin_actor_email_identity} =
  Auth.create_identity(admin_actor, email_provider, %{
    provider_identifier: admin_actor_email,
    provider_identifier_confirmation: admin_actor_email
  })

{:ok, _admin_actor_userpass_identity} =
  Auth.create_identity(admin_actor, userpass_provider, %{
    provider_identifier: admin_actor_email,
    provider_virtual_state: %{
      "password" => "Firezone1234",
      "password_confirmation" => "Firezone1234"
    }
  })

{:ok, admin_actor_oidc_identity} =
  Auth.create_identity(admin_actor, oidc_provider, %{
    provider_identifier: admin_actor_email,
    provider_identifier_confirmation: admin_actor_email
  })

admin_actor_oidc_identity
|> Ecto.Changeset.change(
  created_by: :provider,
  provider_id: oidc_provider.id,
  provider_identifier: admin_actor_email,
  provider_state: %{"claims" => %{"email" => admin_actor_email, "group" => "users"}}
)
|> Repo.update!()

for actor <- other_actors do
  email = "user-#{System.unique_integer([:positive, :monotonic])}@localhost.local"

  {:ok, identity} =
    Auth.create_identity(actor, oidc_provider, %{
      provider_identifier: email,
      provider_identifier_confirmation: email
    })

  identity =
    identity
    |> Ecto.Changeset.change(
      created_by: :provider,
      provider_id: oidc_provider.id,
      provider_identifier: email,
      provider_state: %{"claims" => %{"email" => email, "group" => "users"}}
    )
    |> Repo.update!()

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

{:ok, unprivileged_actor_email_identity} =
  Domain.Auth.Adapters.Email.request_sign_in_token(
    unprivileged_actor_email_identity,
    unprivileged_actor_context
  )

unprivileged_actor_email_token =
  unprivileged_actor_email_identity.provider_virtual_state.nonce <>
    unprivileged_actor_email_identity.provider_virtual_state.fragment

{:ok, admin_actor_email_identity} =
  Domain.Auth.Adapters.Email.request_sign_in_token(
    admin_actor_email_identity,
    admin_actor_context
  )

admin_actor_email_token =
  admin_actor_email_identity.provider_virtual_state.nonce <>
    admin_actor_email_identity.provider_virtual_state.fragment

IO.puts("Created users: ")

for {type, login, password, email_token} <- [
      {unprivileged_actor.type, unprivileged_actor_email, "Firezone1234",
       unprivileged_actor_email_token},
      {admin_actor.type, admin_actor_email, "Firezone1234", admin_actor_email_token}
    ] do
  IO.puts("  #{login}, #{type}, password: #{password}, email token: #{email_token} (exp in 15m)")
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
      | context: %{unprivileged_subject.context | user_agent: "iOS/12.7 (iPhone) connlib/0.7.412"}
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

for _i <- 1..300 do
  Actors.create_group(
    %{name: Domain.Accounts.generate_unique_slug(), type: :static},
    admin_subject
  )
end

{:ok, eng_group} = Actors.create_group(%{name: "Engineering", type: :static}, admin_subject)
{:ok, finance_group} = Actors.create_group(%{name: "Finance", type: :static}, admin_subject)

{:ok, synced_group} =
  Actors.create_group(%{name: "Group:Synced Group with long name", type: :static}, admin_subject)

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

synced_group
|> Ecto.Changeset.change(
  created_by: :provider,
  provider_id: oidc_provider.id,
  provider_identifier: "dummy_oidc_group_id"
)
|> Repo.update!()

oidc_provider
|> Ecto.Changeset.change(last_synced_at: DateTime.utc_now())
|> Repo.update!()

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
    global_relay_group_token,
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
      global_relay_group_token,
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
    relay_group_token,
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
      relay_group_token,
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

{:ok, _internet_gateway_group} =
  Gateways.create_internet_group(account)

{:ok, _internet_gateway_group} =
  Gateways.create_internet_group(other_account)

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
    gateway_group_token,
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
    gateway_group_token,
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
      gateway_group_token,
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
      name: "google.com",
      address: "google.com",
      address_description: "https://google.com/",
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
      name: "Google",
      address: "*.google.com",
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
      type: :dns,
      name: "CloudFlare DNS",
      address: "1.1.1.1",
      address_description: "http://1.1.1.1:3000/",
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

IO.puts("Created resources:")
IO.puts("  #{dns_google_resource.address} - DNS - gateways: #{gateway_name}")
IO.puts("  #{address_description_null_resource.address} - DNS - gateways: #{gateway_name}")
IO.puts("  #{dns_gitlab_resource.address} - DNS - gateways: #{gateway_name}")
IO.puts("  #{firez_one.address} - DNS - gateways: #{gateway_name}")
IO.puts("  #{firezone_dev.address} - DNS - gateways: #{gateway_name}")
IO.puts("  #{example_dns.address} - DNS - gateways: #{gateway_name}")
IO.puts("  #{ip_resource.address} - IP - gateways: #{gateway_name}")
IO.puts("  #{cidr_resource.address} - CIDR - gateways: #{gateway_name}")
IO.puts("  #{dns_httpbin_resource.address} - DNS - gateways: #{gateway_name}")
IO.puts("")

{:ok, _} =
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
      name: "All Access To dns.httpbin",
      actor_group_id: everyone_group.id,
      resource_id: dns_httpbin_resource.id
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

{:ok, _resource, flow} =
  Flows.authorize_flow(
    user_iphone,
    gateway1,
    cidr_resource.id,
    unprivileged_subject
  )

started_at =
  DateTime.utc_now()
  |> DateTime.truncate(:second)
  |> DateTime.add(5, :minute)

{:ok, destination1} = Domain.Types.ProtocolIPPort.cast("tcp://142.250.217.142:443")
{:ok, destination2} = Domain.Types.ProtocolIPPort.cast("udp://142.250.217.142:111")

random_integer = fn ->
  :math.pow(10, 10)
  |> round()
  |> :rand.uniform()
  |> floor()
  |> Kernel.-(1)
end

activities =
  for i <- 1..200 do
    offset = i * 15
    started_at = DateTime.add(started_at, offset, :minute)
    ended_at = DateTime.add(started_at, 15, :minute)

    %{
      window_started_at: started_at,
      window_ended_at: ended_at,
      destination: Enum.random([destination1, destination2]),
      connectivity_type: :direct,
      rx_bytes: random_integer.(),
      tx_bytes: random_integer.(),
      blocked_tx_bytes: 0,
      flow_id: flow.id,
      account_id: account.id
    }
  end

{:ok, 200} = Flows.upsert_activities(activities)

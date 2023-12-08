alias Domain.{Repo, Accounts, Auth, Actors, Relays, Gateways, Resources, Policies, Flows}

# Seeds can be run both with MIX_ENV=prod and MIX_ENV=test, for test env we don't have
# an adapter configured and creation of email provider will fail, so we will override it here.
System.put_env("OUTBOUND_EMAIL_ADAPTER", "Elixir.Swoosh.Adapters.Postmark")

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

account = maybe_repo_update.(account, id: "c89bcc8c-9392-4dae-a40d-888aef6d28e0")

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

{:ok, email_provider} =
  Auth.create_provider(account, %{
    name: "Email",
    adapter: :email,
    adapter_config: %{}
  })

{:ok, token_provider} =
  Auth.create_provider(account, %{
    name: "Token",
    adapter: :token,
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

unprivileged_actor_email = "firezone-unprivileged-1@localhost"
admin_actor_email = "firezone@localhost"

{:ok, unprivileged_actor} =
  Actors.create_actor(account, %{
    type: :account_user,
    name: "Firezone Unprivileged"
  })

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

unprivileged_actor_userpass_identity =
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

{:ok, service_account_actor_token_identity} =
  Auth.create_identity(service_account_actor, token_provider, %{
    provider_identifier: "tok-#{Ecto.UUID.generate()}",
    provider_virtual_state: %{
      "expires_at" => DateTime.utc_now() |> DateTime.add(365, :day)
    }
  })

# Other Account Users
other_unprivileged_actor_email = "other-unprivileged-1@localhost"
other_admin_actor_email = "other@localhost"

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

unprivileged_actor_token = unprivileged_actor_email_identity.provider_virtual_state.sign_in_token
admin_actor_token = admin_actor_email_identity.provider_virtual_state.sign_in_token

unprivileged_subject =
  Auth.build_subject(
    unprivileged_actor_userpass_identity,
    DateTime.utc_now() |> DateTime.add(365, :day),
    %Auth.Context{
      user_agent: "Debian/11.0.0 connlib/0.1.0",
      remote_ip: {172, 28, 0, 100},
      remote_ip_location_region: "UA",
      remote_ip_location_city: "Kyiv",
      remote_ip_location_lat: 50.4333,
      remote_ip_location_lon: 30.5167
    }
  )

admin_subject =
  Auth.build_subject(
    admin_actor_email_identity,
    nil,
    %Auth.Context{user_agent: "iOS/12.5 (iPhone) connlib/0.7.412", remote_ip: {100, 64, 100, 58}}
  )

IO.puts("Created users: ")

for {type, login, password, email_token} <- [
      {unprivileged_actor.type, unprivileged_actor_email, "Firezone1234",
       unprivileged_actor_token},
      {admin_actor.type, admin_actor_email, "Firezone1234", admin_actor_token}
    ] do
  IO.puts("  #{login}, #{type}, password: #{password}, email token: #{email_token} (exp in 15m)")
end

service_account_token = service_account_actor_token_identity.provider_virtual_state.changes.secret

IO.puts(
  "  #{service_account_actor_token_identity.provider_identifier}," <>
    "#{service_account_actor.type}, token: #{service_account_token}"
)

IO.puts("")

{:ok, user_iphone} =
  Domain.Clients.upsert_client(
    %{
      name: "FZ User iPhone",
      external_id: Ecto.UUID.generate(),
      public_key: :crypto.strong_rand_bytes(32) |> Base.encode64(),
      last_seen_user_agent: "iOS/12.7 (iPhone) connlib/0.7.412"
    },
    unprivileged_subject
  )

{:ok, _admin_iphone} =
  Domain.Clients.upsert_client(
    %{
      name: "FZ Admin iPhone",
      external_id: Ecto.UUID.generate(),
      public_key: :crypto.strong_rand_bytes(32) |> Base.encode64(),
      last_seen_user_agent: "iOS/12.7 (iPhone) connlib/0.7.412"
    },
    admin_subject
  )

IO.puts("Clients created")
IO.puts("")

IO.puts("Created Actor Groups: ")

{:ok, eng_group} = Actors.create_group(%{name: "Engineering"}, admin_subject)
{:ok, finance_group} = Actors.create_group(%{name: "Finance"}, admin_subject)

{:ok, all_group} =
  Actors.create_group(
    %{name: "All Employees", provider_id: oidc_provider.id, provider_identifier: "foo"},
    admin_subject
  )

for group <- [eng_group, finance_group, all_group] do
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

all_group
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

IO.puts("")

{:ok, global_relay_group} =
  Relays.create_global_group(%{
    name: "fz-global-relays",
    tokens: [%{}]
  })

global_relay_group_token = hd(global_relay_group.tokens)

global_relay_group_token =
  maybe_repo_update.(global_relay_group_token,
    id: "c1038e22-0215-4977-9f6c-f65621e0008f",
    hash:
      "$argon2id$v=19$m=65536,t=3,p=4$XBzQrgdRFH5XhiTfWFcGWA$PTTy4D7xtahPbvGTgZLgGS8qHnfd8LJKWAnTdhB4yww",
    value:
      "Obnnb37dBtNQccCU-fBYu1h8NafAp0KyoOwlo2TTIy60ofokIlV60spa12G5pIG-RVKj5qwHVEh1k9n8xBcf9A"
  )

IO.puts("Created global relay groups:")
IO.puts("  #{global_relay_group.name} token: #{Relays.encode_token!(global_relay_group_token)}")

IO.puts("")

{:ok, global_relay} =
  Relays.upsert_relay(global_relay_group_token, %{
    ipv4: {189, 172, 72, 111},
    ipv6: {0, 0, 0, 0, 0, 0, 0, 1},
    last_seen_user_agent: "iOS/12.7 (iPhone) connlib/0.7.412",
    last_seen_remote_ip: %Postgrex.INET{address: {189, 172, 72, 111}}
  })

for i <- 1..5 do
  {:ok, _global_relay} =
    Relays.upsert_relay(global_relay_group_token, %{
      ipv4: {189, 172, 72, 111 + i},
      ipv6: {0, 0, 0, 0, 0, 0, 0, i},
      last_seen_user_agent: "iOS/12.7 (iPhone) connlib/0.7.412",
      last_seen_remote_ip: %Postgrex.INET{address: {189, 172, 72, 111 + i}}
    })
end

IO.puts("Created global relays:")
IO.puts("  Group #{global_relay_group.name}:")
IO.puts("    IPv4: #{global_relay.ipv4} IPv6: #{global_relay.ipv6}")
IO.puts("")

relay_group =
  account
  |> Relays.Group.Changeset.create(
    %{name: "mycorp-aws-relays", tokens: [%{}]},
    admin_subject
  )
  |> Repo.insert!()

relay_group_token = hd(relay_group.tokens)

relay_group_token =
  maybe_repo_update.(relay_group_token,
    id: "7286b53d-073e-4c41-9ff1-cc8451dad299",
    hash:
      "$argon2id$v=19$m=131072,t=8,p=4$aSw/NA3z0vGJjvF3ukOcyg$5MPWPXLETM3iZ19LTihItdVGb7ou/i4/zhpozMrpCFg",
    value: "EX77Ga0HKJUVLgcpMrN6HatdGnfvADYQrRjUWWyTqqt7BaUdEU3o9-FbBlRdINIK"
  )

IO.puts("Created relay groups:")
IO.puts("  #{relay_group.name} token: #{Relays.encode_token!(relay_group_token)}")
IO.puts("")

{:ok, relay} =
  Relays.upsert_relay(relay_group_token, %{
    ipv4: {189, 172, 73, 111},
    ipv6: {0, 0, 0, 0, 0, 0, 0, 1},
    last_seen_user_agent: "iOS/12.7 (iPhone) connlib/0.7.412",
    last_seen_remote_ip: %Postgrex.INET{address: {189, 172, 73, 111}}
  })

for i <- 1..5 do
  {:ok, _relay} =
    Relays.upsert_relay(relay_group_token, %{
      ipv4: {189, 172, 73, 111 + i},
      ipv6: {0, 0, 0, 0, 0, 0, 0, i},
      last_seen_user_agent: "iOS/12.7 (iPhone) connlib/0.7.412",
      last_seen_remote_ip: %Postgrex.INET{address: {189, 172, 73, 111}}
    })
end

IO.puts("Created relays:")
IO.puts("  Group #{relay_group.name}:")
IO.puts("    IPv4: #{relay.ipv4} IPv6: #{relay.ipv6}")
IO.puts("")

gateway_group =
  account
  |> Gateways.Group.Changeset.create(
    %{name: "mycro-aws-gws", routing: "managed", tokens: [%{}]},
    admin_subject
  )
  |> Repo.insert!()

gateway_group_token = hd(gateway_group.tokens)

gateway_group_token =
  maybe_repo_update.(
    gateway_group_token,
    id: "3cef0566-adfd-48fe-a0f1-580679608f6f",
    hash:
      "$argon2id$v=19$m=131072,t=8,p=4$w0aXBd0iv/OTizWGBRTKiw$m6J0YXRsFCO95Q8LeVvH+CxFTy0Li7Lrcs3NDJRykCA",
    value: "jjtzxRFJPZGBc-oCZ9Dy2FwjwaHXMAUdpzuRr2sRropx75-znh_xp_5bT5Ono-rb"
  )

IO.puts("Created gateway groups:")
IO.puts("  #{gateway_group.name} token: #{Gateways.encode_token!(gateway_group_token)}")
IO.puts("")

{:ok, gateway1} =
  Gateways.upsert_gateway(gateway_group_token, %{
    external_id: Ecto.UUID.generate(),
    name: "gw-#{Domain.Crypto.random_token(5, encoder: :user_friendly)}",
    public_key: :crypto.strong_rand_bytes(32) |> Base.encode64(),
    last_seen_user_agent: "iOS/12.7 (iPhone) connlib/0.7.412",
    last_seen_remote_ip: %Postgrex.INET{address: {189, 172, 73, 153}}
  })

{:ok, gateway2} =
  Gateways.upsert_gateway(gateway_group_token, %{
    external_id: Ecto.UUID.generate(),
    name: "gw-#{Domain.Crypto.random_token(5, encoder: :user_friendly)}",
    public_key: :crypto.strong_rand_bytes(32) |> Base.encode64(),
    last_seen_user_agent: "iOS/12.7 (iPhone) connlib/0.7.412",
    last_seen_remote_ip: %Postgrex.INET{address: {164, 112, 78, 62}}
  })

for i <- 1..10 do
  {:ok, _gateway} =
    Gateways.upsert_gateway(gateway_group_token, %{
      external_id: Ecto.UUID.generate(),
      name: "gw-#{Domain.Crypto.random_token(5, encoder: :user_friendly)}",
      public_key: :crypto.strong_rand_bytes(32) |> Base.encode64(),
      last_seen_user_agent: "iOS/12.7 (iPhone) connlib/0.7.412",
      last_seen_remote_ip: %Postgrex.INET{address: {164, 112, 78, 62 + i}}
    })
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
      connections: [%{gateway_group_id: gateway_group.id}],
      filters: [%{protocol: :all}]
    },
    admin_subject
  )

{:ok, t_firez_one} =
  Resources.create_resource(
    %{
      type: :dns,
      name: "t.firez.one",
      address: "t.firez.one",
      connections: [%{gateway_group_id: gateway_group.id}],
      filters: [%{protocol: :all}]
    },
    admin_subject
  )

{:ok, ping_firez_one} =
  Resources.create_resource(
    %{
      type: :dns,
      name: "ping.firez.one",
      address: "ping.firez.one",
      connections: [%{gateway_group_id: gateway_group.id}],
      filters: [%{protocol: :all}]
    },
    admin_subject
  )

{:ok, ip6only} =
  Resources.create_resource(
    %{
      type: :dns,
      name: "ip6only",
      address: "ip6only.me",
      connections: [%{gateway_group_id: gateway_group.id}],
      filters: [%{protocol: :all}]
    },
    admin_subject
  )

{:ok, dns_gitlab_resource} =
  Resources.create_resource(
    %{
      type: :dns,
      name: "gitlab.mycorp.com",
      address: "gitlab.mycorp.com",
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
      connections: [%{gateway_group_id: gateway_group.id}],
      filters: [%{protocol: :all}]
    },
    admin_subject
  )

IO.puts("Created resources:")
IO.puts("  #{dns_google_resource.address} - DNS - gateways: #{gateway_name}")
IO.puts("  #{dns_gitlab_resource.address} - DNS - gateways: #{gateway_name}")
IO.puts("  #{cidr_resource.address} - CIDR - gateways: #{gateway_name}")
IO.puts("")

{:ok, _} = Policies.create_policy(
  %{
    name: "All Access To Google",
    actor_group_id: all_group.id,
    resource_id: dns_google_resource.id
  },
  admin_subject
)

{:ok, _} = Policies.create_policy(
  %{
    name: "All Access To t.firez.one",
    actor_group_id: all_group.id,
    resource_id: t_firez_one.id
  },
  admin_subject
)

{:ok, _} = Policies.create_policy(
  %{
    name: "All Access To ping.firez.one",
    actor_group_id: all_group.id,
    resource_id: ping_firez_one.id
  },
  admin_subject
)

{:ok, _} = Policies.create_policy(
  %{
    name: "All Access To ip6only.me",
    actor_group_id: all_group.id,
    resource_id: ip6only.id
  },
  admin_subject
)

{:ok, _} = Policies.create_policy(
  %{
    name: "Eng Access To Gitlab",
    actor_group_id: eng_group.id,
    resource_id: dns_gitlab_resource.id
  },
  admin_subject
)

{:ok, _} = Policies.create_policy(
  %{
    name: "All Access To Network",
    actor_group_id: all_group.id,
    resource_id: cidr_resource.id
  },
  admin_subject
)

IO.puts("Policies Created")
IO.puts("")

{:ok, unprivileged_subject_client_token} =
  Auth.create_client_token_from_subject(unprivileged_subject)

IO.puts("Created client tokens:")
IO.puts("  #{unprivileged_actor_email} token: #{unprivileged_subject_client_token}")
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

{:ok, destination1} = Domain.Types.IPPort.cast("142.250.217.142:443")
{:ok, destination2} = Domain.Types.IPPort.cast("142.250.217.142:80")

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
      rx_bytes: random_integer.(),
      tx_bytes: random_integer.(),
      flow_id: flow.id,
      account_id: account.id
    }
  end

{:ok, 200} = Flows.upsert_activities(activities)

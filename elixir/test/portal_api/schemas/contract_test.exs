defmodule PortalAPI.Schemas.ContractTest do
  @moduledoc """
  Keeps each response schema aligned with the Ecto struct its JSON view renders.

  Every struct field must be either a documented property, or listed here as
  internal, so a new column reaches the API only once someone decides it
  should. Fields marked `redact: true` on the Ecto schema are internal by
  definition and must never appear as a property.
  """
  use ExUnit.Case, async: true

  alias OpenApiSpex.Schema

  # `computed` names properties the view builds itself rather than copying from
  # the struct. `aliases` maps a property name to the struct field it reads.
  # `optional` names properties the view may omit from the payload.
  @device_internal [
    :account_id,
    :attested?,
    :client_token_id,
    :firezone_id_merged?,
    :gateway_token_id,
    :gateway_token_rotated_at,
    :last_attested_cert_issuer,
    :site_id,
    :type
  ]

  @posture_provider_internal [:error_email_count]

  @contracts [
    %{
      schema: PortalAPI.Schemas.Account.Schema,
      struct: Portal.Account,
      computed: [:limits],
      internal: [
        :admins_limit_exceeded,
        :config,
        :disabled_reason,
        :features,
        :inserted_at,
        :is_disabled,
        :lock_enabled_at,
        :metadata,
        :scheduled_deletion_at,
        :seats_limit_exceeded,
        :service_accounts_limit_exceeded,
        :sites_limit_exceeded,
        :updated_at,
        :users_limit_exceeded,
        :warning_last_sent_at
      ]
    },
    %{
      schema: PortalAPI.Schemas.Actor.Schema,
      struct: Portal.Actor,
      internal: [:account_id, :identity_count, :preferences]
    },
    %{
      schema: PortalAPI.Schemas.Membership.Schema,
      struct: Portal.Actor,
      internal: [
        :account_id,
        :allow_email_otp_sign_in,
        :created_by_directory_id,
        :email,
        :identity_count,
        :inserted_at,
        :is_disabled,
        :last_seen_at,
        :preferences,
        :updated_at
      ]
    },
    %{
      schema: PortalAPI.Schemas.Site.Schema,
      struct: Portal.Site,
      internal: [:account_id, :health_threshold, :inserted_at, :managed_by, :updated_at]
    },
    %{
      schema: PortalAPI.Schemas.Group.Schema,
      struct: Portal.Group,
      computed: [:synced_at],
      internal: [:account_id, :type]
    },
    %{
      schema: PortalAPI.Schemas.Policy.ResponseSchema,
      struct: Portal.Policy,
      computed: [:conditions],
      internal: [:account_id, :group_idp_id, :inserted_at, :updated_at]
    },
    %{
      schema: PortalAPI.Schemas.Resource.Schema,
      struct: Portal.Resource,
      computed: [:filters],
      internal: [:account_id, :inserted_at, :updated_at],
      optional: [:ip_stack, :site_id]
    },
    %{
      schema: PortalAPI.Schemas.Client.GetSchema,
      struct: Portal.Device,
      aliases: [online: :online?, created_at: :inserted_at],
      internal: @device_internal
    },
    %{
      schema: PortalAPI.Schemas.Gateway.Schema,
      struct: Portal.Device,
      aliases: [online: :online?, rotated_at: :gateway_token_rotated_at],
      internal:
        (@device_internal -- [:gateway_token_id, :gateway_token_rotated_at]) ++
          [
            :actor_id,
            :device_serial,
            :device_uuid,
            :firebase_installation_id,
            :firezone_id,
            :hostname,
            :identifier_for_vendor,
            :inserted_at,
            :last_attested_at,
            :last_attested_cert_fingerprint,
            :last_attested_cert_serial,
            :last_attested_device_serial,
            :last_attested_device_uuid,
            :last_attested_mdm_device_id,
            :updated_at,
            :verified_at
          ]
    },
    %{
      schema: PortalAPI.Schemas.PoolMember.Schema,
      struct: Portal.Device,
      internal:
        @device_internal ++
          [
            :actor_id,
            :device_serial,
            :device_uuid,
            :firebase_installation_id,
            :firezone_id,
            :hostname,
            :identifier_for_vendor,
            :inserted_at,
            :ipv4,
            :ipv6,
            :last_attested_at,
            :last_attested_cert_fingerprint,
            :last_attested_cert_serial,
            :last_attested_device_serial,
            :last_attested_device_uuid,
            :last_attested_mdm_device_id,
            :last_seen_remote_ip,
            :last_seen_remote_ip_location_city,
            :last_seen_remote_ip_location_lat,
            :last_seen_remote_ip_location_lon,
            :last_seen_remote_ip_location_region,
            :last_seen_user_agent,
            :last_seen_version,
            :online?,
            :public_key,
            :updated_at,
            :verified_at
          ]
    },
    %{
      schema: PortalAPI.Schemas.ClientToken.Schema,
      struct: Portal.ClientToken,
      internal: [
        :account_id,
        :auth_provider_id,
        :auth_provider_name,
        :auth_provider_type,
        :last_used_device,
        :online?
      ]
    },
    %{
      schema: PortalAPI.Schemas.ClientToken.ResponseSchema,
      struct: Portal.ClientToken,
      computed: [:token],
      internal: [
        :account_id,
        :auth_provider_id,
        :auth_provider_name,
        :auth_provider_type,
        :last_used_device,
        :online?
      ]
    },
    %{
      schema: PortalAPI.Schemas.GatewayToken.Schema,
      struct: Portal.GatewayToken,
      computed: [:token],
      internal: [:account_id, :device_id, :inserted_at, :rotated_at, :rotated_sibling_id, :site_id]
    },
    %{
      schema: PortalAPI.Schemas.ExternalIdentity.Schema,
      struct: Portal.ExternalIdentity,
      computed: [:email, :idp_id, :synced_at],
      internal: [:directory_name, :updated_at]
    },
    %{
      schema: PortalAPI.Schemas.Log.Change,
      struct: Portal.ChangeLog,
      computed: [:type],
      internal: [:account_id, :lsn, :seq, :vsn]
    },
    %{
      schema: PortalAPI.Schemas.Log.Session,
      struct: Portal.SessionLog,
      computed: [:type],
      internal: [:account_id, :seq]
    },
    %{
      schema: PortalAPI.Schemas.Log.Flow,
      struct: Portal.FlowLog,
      computed: [:type, :inner_src_ip, :inner_dst_ip, :outers],
      aliases: [timestamp: :inserted_at, inner_domain: :domain],
      internal: [:account_id, :seq, :start_seq]
    },
    %{
      schema: PortalAPI.Schemas.Log.APIRequest,
      struct: Portal.APIRequestLog,
      computed: [:type, :ip],
      aliases: [timestamp: :inserted_at],
      internal: [:account_id, :seq]
    },
    %{
      schema: PortalAPI.Schemas.EntraAuthProvider.Schema,
      struct: Portal.Entra.AuthProvider,
      internal: [:is_verified]
    },
    %{
      schema: PortalAPI.Schemas.GoogleAuthProvider.Schema,
      struct: Portal.Google.AuthProvider,
      internal: [:is_verified]
    },
    %{
      schema: PortalAPI.Schemas.OktaAuthProvider.Schema,
      struct: Portal.Okta.AuthProvider,
      internal: [:discovery_document_uri, :is_verified]
    },
    %{
      schema: PortalAPI.Schemas.OIDCAuthProvider.Schema,
      struct: Portal.OIDC.AuthProvider,
      internal: [:is_legacy, :is_verified]
    },
    %{
      schema: PortalAPI.Schemas.EmailOTPAuthProvider.Schema,
      struct: Portal.EmailOTP.AuthProvider
    },
    %{
      schema: PortalAPI.Schemas.X509AuthProvider.Schema,
      struct: Portal.X509.AuthProvider
    },
    %{
      schema: PortalAPI.Schemas.EntraDirectory.Schema,
      struct: Portal.Entra.Directory,
      internal: [
        :error_email_count,
        :groups_subscription_id,
        :is_verified,
        :subscriptions_expire_at,
        :users_subscription_id
      ]
    },
    %{
      schema: PortalAPI.Schemas.GoogleDirectory.Schema,
      struct: Portal.Google.Directory,
      internal: [:error_email_count, :is_verified, :sync_all_domains]
    },
    %{
      schema: PortalAPI.Schemas.OktaDirectory.Schema,
      struct: Portal.Okta.Directory,
      internal: [:error_email_count, :is_verified]
    },
    %{
      schema: PortalAPI.Schemas.IntunePostureProvider.Schema,
      struct: Portal.Intune.PostureProvider,
      computed: [:type, :name],
      internal: @posture_provider_internal
    },
    %{
      schema: PortalAPI.Schemas.IruPostureProvider.Schema,
      struct: Portal.Iru.PostureProvider,
      computed: [:type, :name],
      internal: @posture_provider_internal
    },
    %{
      schema: PortalAPI.Schemas.SantaPostureProvider.Schema,
      struct: Portal.Santa.PostureProvider,
      computed: [:type, :name],
      internal: @posture_provider_internal
    },
    %{
      schema: PortalAPI.Schemas.SentinelOnePostureProvider.Schema,
      struct: Portal.SentinelOne.PostureProvider,
      computed: [:type, :name],
      internal: @posture_provider_internal
    },
    %{
      schema: PortalAPI.Schemas.DefenderPostureProvider.Schema,
      struct: Portal.Defender.PostureProvider,
      computed: [:type, :name],
      internal: @posture_provider_internal
    },
    %{schema: PortalAPI.Schemas.IntuneDevice.Schema, struct: Portal.Intune.Device},
    %{schema: PortalAPI.Schemas.IruDevice.Schema, struct: Portal.Iru.Device},
    %{schema: PortalAPI.Schemas.SantaDevice.Schema, struct: Portal.Santa.Device},
    %{schema: PortalAPI.Schemas.SentinelOneDevice.Schema, struct: Portal.SentinelOne.Device},
    %{schema: PortalAPI.Schemas.DefenderDevice.Schema, struct: Portal.Defender.Device}
  ]

  for contract <- @contracts do
    @contract contract

    describe "#{inspect(contract.schema)} against #{inspect(contract.struct)}" do
      test "classifies every struct field as exposed or internal" do
        %{struct: struct, internal: internal, computed: computed} = normalize(@contract)
        redacted = struct.__schema__(:redact_fields)

        unclassified =
          (fields(struct) -- exposed_fields(@contract)) -- (internal ++ computed ++ redacted)

        assert unclassified == [],
               "#{inspect(struct)} has fields that are neither documented by " <>
                 "#{inspect(@contract.schema)} nor listed as internal: #{inspect(unclassified)}"

        assert internal -- fields(struct) == [],
               "internal lists fields #{inspect(struct)} does not have: " <>
                 inspect(internal -- fields(struct))
      end

      test "documents only fields the struct has" do
        %{struct: struct} = @contract
        unknown = exposed_fields(@contract) -- fields(struct)

        assert unknown == [],
               "#{inspect(@contract.schema)} documents fields #{inspect(struct)} does not " <>
                 "have: #{inspect(unknown)}. List them as computed if the view builds them."
      end

      test "never documents a redacted field" do
        %{struct: struct} = @contract
        leaked = exposed_fields(@contract) -- (exposed_fields(@contract) -- struct.__schema__(:redact_fields))

        assert leaked == [],
               "#{inspect(@contract.schema)} documents fields marked redact: true on " <>
                 "#{inspect(struct)}: #{inspect(leaked)}"
      end

      test "property types match the struct's Ecto types" do
        %{struct: struct, aliases: aliases} = normalize(@contract)
        properties = @contract.schema.schema().properties

        mismatches =
          for {property, %Schema{oneOf: nil, anyOf: nil, allOf: nil} = schema} <- properties,
              field = Keyword.get(aliases, property, property),
              field in exposed_fields(@contract),
              expected = expected_type(ecto_type(struct, field)),
              problem = compare(expected, schema),
              do: {property, problem}

        assert mismatches == [],
               "#{inspect(@contract.schema)} property types disagree with " <>
                 "#{inspect(struct)}:\n" <>
                 Enum.map_join(mismatches, "\n", fn {p, m} -> "  #{p}: #{m}" end)
      end

      test "marks every property required unless listed as optional" do
        %{optional: optional} = normalize(@contract)
        schema = @contract.schema.schema()
        not_required = Map.keys(schema.properties) -- List.wrap(schema.required)

        assert Enum.sort(not_required) == Enum.sort(optional),
               "#{inspect(@contract.schema)} must list every property the view always " <>
                 "emits as required. Not required: #{inspect(Enum.sort(not_required))}"
      end
    end
  end

  defp normalize(contract) do
    Map.merge(%{computed: [], internal: [], aliases: [], optional: []}, contract)
  end

  defp fields(struct), do: struct.__schema__(:fields) ++ struct.__schema__(:virtual_fields)

  defp exposed_fields(contract) do
    %{schema: schema, computed: computed, aliases: aliases} = normalize(contract)

    schema.schema().properties
    |> Map.keys()
    |> Kernel.--(computed)
    |> Enum.map(&Keyword.get(aliases, &1, &1))
  end

  defp ecto_type(struct, field) do
    struct.__schema__(:type, field) || struct.__schema__(:virtual_type, field)
  end

  defp expected_type(:binary_id), do: {:string, :uuid}
  defp expected_type(Ecto.UUID), do: {:string, :uuid}
  defp expected_type(:string), do: {:string, nil}
  defp expected_type(:boolean), do: {:boolean, nil}
  defp expected_type(:integer), do: {:integer, nil}
  defp expected_type(:float), do: {:number, nil}
  defp expected_type(:utc_datetime_usec), do: {:string, :"date-time"}
  defp expected_type(:utc_datetime), do: {:string, :"date-time"}
  defp expected_type(:map), do: {:object, nil}
  defp expected_type(:bigint), do: {:integer, nil}
  defp expected_type({:array, _}), do: {:array, nil}
  defp expected_type(Portal.Types.IP), do: {:string, nil}

  defp expected_type({:parameterized, {Ecto.Enum, %{on_load: values}}}) do
    {:enum, values |> Map.keys() |> Enum.sort()}
  end

  defp expected_type(_other), do: nil

  defp compare({:enum, values}, %Schema{type: :string, enum: enum}) when is_list(enum) do
    if Enum.sort(enum) == values do
      nil
    else
      "enum #{inspect(Enum.sort(enum))} differs from Ecto.Enum values #{inspect(values)}"
    end
  end

  defp compare({:enum, values}, %Schema{}), do: "expected a string enum of #{inspect(values)}"

  defp compare({type, format}, %Schema{type: actual, format: actual_format}) do
    cond do
      type != actual -> "expected type #{inspect(type)}, schema says #{inspect(actual)}"
      format && format != actual_format -> "expected format #{inspect(format)}, schema says #{inspect(actual_format)}"
      true -> nil
    end
  end
end

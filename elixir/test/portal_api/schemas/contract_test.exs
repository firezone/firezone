defmodule PortalAPI.Schemas.ContractTest do
  @moduledoc """
  Keeps each response schema aligned with the encoder derived for its struct.

  The encoder decides which struct fields leave the portal; the schema
  documents them. Encoding a bare struct must produce exactly the documented
  properties, property types must match the Ecto types, and a field marked
  `redact: true` must never be documented.
  """
  use ExUnit.Case, async: true

  alias OpenApiSpex.Schema

  # `extras` are properties the controller adds after encoding. `optional` ones
  # are omitted when nil, so a bare struct does not carry them. `aliases` map a
  # property to the struct field it is read from. `attrs` give a bare struct
  # whatever its mapper needs.
  @contracts [
    %{schema: PortalAPI.Schemas.Account.Schema, struct: Portal.Account, extras: [:limits]},
    %{schema: PortalAPI.Schemas.Actor.Schema, struct: Portal.Actor, as: :actor},
    %{schema: PortalAPI.Schemas.Membership.Schema, struct: Portal.Actor, as: :membership},
    %{schema: PortalAPI.Schemas.Site.Schema, struct: Portal.Site},
    %{schema: PortalAPI.Schemas.Group.Schema, struct: Portal.Group, attrs: %{sync_state: nil}},
    %{schema: PortalAPI.Schemas.Policy.ResponseSchema, struct: Portal.Policy},
    %{
      schema: PortalAPI.Schemas.Resource.Schema,
      struct: Portal.Resource,
      optional: [:ip_stack, :site_id]
    },
    %{
      schema: PortalAPI.Schemas.Client.GetSchema,
      struct: Portal.Device,
      as: :client,
      aliases: [online: :online?, created_at: :inserted_at]
    },
    %{
      schema: PortalAPI.Schemas.Gateway.Schema,
      struct: Portal.Device,
      as: :gateway,
      aliases: [online: :online?, rotated_at: :gateway_token_rotated_at]
    },
    %{schema: PortalAPI.Schemas.PoolMember.Schema, struct: Portal.Device, as: :pool_member},
    %{schema: PortalAPI.Schemas.ClientToken.Schema, struct: Portal.ClientToken},
    %{
      schema: PortalAPI.Schemas.ClientToken.ResponseSchema,
      struct: Portal.ClientToken,
      extras: [:token]
    },
    %{schema: PortalAPI.Schemas.GatewayToken.Schema, struct: Portal.GatewayToken, extras: [:token]},
    %{
      schema: PortalAPI.Schemas.ExternalIdentity.Schema,
      struct: Portal.ExternalIdentity,
      attrs: %{idp_id: "issuer:123", sync_state: nil}
    },
    %{schema: PortalAPI.Schemas.Log.Change, struct: Portal.ChangeLog},
    %{schema: PortalAPI.Schemas.Log.Session, struct: Portal.SessionLog},
    %{
      schema: PortalAPI.Schemas.Log.Flow,
      struct: Portal.FlowLog,
      aliases: [timestamp: :inserted_at, inner_domain: :domain]
    },
    %{
      schema: PortalAPI.Schemas.Log.APIRequest,
      struct: Portal.APIRequestLog,
      aliases: [timestamp: :inserted_at]
    },
    %{schema: PortalAPI.Schemas.EntraAuthProvider.Schema, struct: Portal.Entra.AuthProvider},
    %{schema: PortalAPI.Schemas.GoogleAuthProvider.Schema, struct: Portal.Google.AuthProvider},
    %{schema: PortalAPI.Schemas.OktaAuthProvider.Schema, struct: Portal.Okta.AuthProvider},
    %{schema: PortalAPI.Schemas.OIDCAuthProvider.Schema, struct: Portal.OIDC.AuthProvider},
    %{schema: PortalAPI.Schemas.EmailOTPAuthProvider.Schema, struct: Portal.EmailOTP.AuthProvider},
    %{schema: PortalAPI.Schemas.X509AuthProvider.Schema, struct: Portal.X509.AuthProvider},
    %{schema: PortalAPI.Schemas.EntraDirectory.Schema, struct: Portal.Entra.Directory},
    %{schema: PortalAPI.Schemas.GoogleDirectory.Schema, struct: Portal.Google.Directory},
    %{schema: PortalAPI.Schemas.OktaDirectory.Schema, struct: Portal.Okta.Directory},
    %{
      schema: PortalAPI.Schemas.IntunePostureProvider.Schema,
      struct: Portal.Intune.PostureProvider,
      attrs: %{posture_provider: %{name: "Intune"}}
    },
    %{
      schema: PortalAPI.Schemas.IruPostureProvider.Schema,
      struct: Portal.Iru.PostureProvider,
      attrs: %{posture_provider: %{name: "Iru"}}
    },
    %{
      schema: PortalAPI.Schemas.SantaPostureProvider.Schema,
      struct: Portal.Santa.PostureProvider,
      attrs: %{posture_provider: %{name: "Santa"}}
    },
    %{
      schema: PortalAPI.Schemas.SentinelOnePostureProvider.Schema,
      struct: Portal.SentinelOne.PostureProvider,
      attrs: %{posture_provider: %{name: "SentinelOne"}}
    },
    %{
      schema: PortalAPI.Schemas.DefenderPostureProvider.Schema,
      struct: Portal.Defender.PostureProvider,
      attrs: %{posture_provider: %{name: "Defender"}}
    },
    %{schema: PortalAPI.Schemas.IntuneDevice.Schema, struct: Portal.Intune.Device},
    %{schema: PortalAPI.Schemas.IruDevice.Schema, struct: Portal.Iru.Device},
    %{schema: PortalAPI.Schemas.SantaDevice.Schema, struct: Portal.Santa.Device},
    %{schema: PortalAPI.Schemas.SentinelOneDevice.Schema, struct: Portal.SentinelOne.Device},
    %{schema: PortalAPI.Schemas.DefenderDevice.Schema, struct: Portal.Defender.Device}
  ]

  for contract <- @contracts do
    @contract Map.merge(%{extras: [], aliases: [], attrs: %{}, optional: []}, contract)

    describe "#{inspect(contract.schema)} against #{inspect(contract.struct)}" do
      test "encodes exactly the documented properties" do
        encoded = @contract.struct |> struct(@contract.attrs) |> PortalAPI.JSON.encode(opts(@contract))
        documented = Map.keys(@contract.schema.schema().properties)
        emitted = Enum.uniq(Map.keys(encoded) ++ @contract.extras ++ @contract.optional)

        assert Enum.sort(emitted) == Enum.sort(documented),
               """
               #{inspect(@contract.schema)} and the encoder for #{inspect(@contract.struct)} disagree.
                 encoded but not documented: #{inspect(Enum.sort(emitted -- documented))}
                 documented but not encoded: #{inspect(Enum.sort(documented -- emitted))}
               """
      end

      test "never documents a redacted field" do
        redacted = @contract.struct.__schema__(:redact_fields)
        documented = @contract.schema.schema().properties |> Map.keys() |> Enum.map(&source(&1, @contract))

        assert documented -- (documented -- redacted) == [],
               "#{inspect(@contract.schema)} documents fields marked redact: true on " <>
                 "#{inspect(@contract.struct)}: #{inspect(documented -- (documented -- redacted))}"
      end

      test "property types match the struct's Ecto types" do
        struct = @contract.struct

        mismatches =
          for {property, %Schema{oneOf: nil, anyOf: nil, allOf: nil} = schema} <-
                @contract.schema.schema().properties,
              field = source(property, @contract),
              field in fields(struct),
              expected = expected_type(ecto_type(struct, field)),
              problem = compare(expected, schema),
              do: {property, problem}

        assert mismatches == [],
               "#{inspect(@contract.schema)} property types disagree with #{inspect(struct)}:\n" <>
                 Enum.map_join(mismatches, "\n", fn {p, m} -> "  #{p}: #{m}" end)
      end

      test "marks every property required unless listed as optional" do
        schema = @contract.schema.schema()
        not_required = Map.keys(schema.properties) -- List.wrap(schema.required)

        assert Enum.sort(not_required) == Enum.sort(@contract.optional),
               "#{inspect(@contract.schema)} must list every property the payload always " <>
                 "carries as required. Not required: #{inspect(Enum.sort(not_required))}"
      end
    end
  end

  defp opts(%{as: as}), do: [as: as]
  defp opts(_contract), do: []

  defp source(property, contract), do: Keyword.get(contract.aliases, property, property)

  defp fields(struct), do: struct.__schema__(:fields) ++ struct.__schema__(:virtual_fields)

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
      type != actual ->
        "expected type #{inspect(type)}, schema says #{inspect(actual)}"

      format && format != actual_format ->
        "expected format #{inspect(format)}, schema says #{inspect(actual_format)}"

      true ->
        nil
    end
  end
end

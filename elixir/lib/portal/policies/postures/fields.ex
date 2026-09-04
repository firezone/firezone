defmodule Portal.Policies.Postures.Fields.Classifier do
  @moduledoc false

  @bookkeeping ~w[account_id posture_provider_id inserted_at updated_at]a

  @doc """
  Classifies every column of a mirror schema, raising on one that has no
  posture type, so a column a sync adds is either classified or fails the
  build.
  """
  @spec classify!(module(), keyword()) :: %{atom() => atom()}
  def classify!(schema, opts) do
    excluded = @bookkeeping ++ Keyword.fetch!(opts, :excluded)

    overridden =
      for {type, fields} <- Keyword.take(opts, [:enum_string, :version]),
          field <- fields,
          into: %{},
          do: {field, type}

    unknown_overrides = Map.keys(overridden) -- schema.__schema__(:fields)

    if unknown_overrides != [] do
      raise ArgumentError,
            "#{inspect(schema)} has no columns #{inspect(Enum.sort(unknown_overrides))}"
    end

    classified =
      for field <- schema.__schema__(:fields) -- excluded, into: %{} do
        {field, Map.get(overridden, field) || base_type!(schema, field)}
      end

    Map.put(classified, :enrolled, :boolean)
  end

  defp base_type!(schema, field) do
    case schema.__schema__(:type, field) do
      :string -> :string
      :boolean -> :boolean
      :integer -> :integer
      :float -> :float
      :utc_datetime_usec -> :datetime
      :date -> :date
      Portal.Types.IP -> :ip
      {:array, :string} -> :string_array
      :map -> :json
      {:array, :map} -> :json
      other -> raise ArgumentError, "#{inspect(schema)}.#{field} has no posture type for #{inspect(other)}"
    end
  end
end

defmodule Portal.Policies.Postures.Fields do
  @moduledoc """
  The fields a posture may reference, per provider type, and the semantic
  type of each. Types decide which operators apply and how values parse.

  Provider registries are derived from the mirror schemas. The `firezone`
  registry is an explicit allowlist over `Portal.Device`, which carries far
  more than telemetry, and leaves out what the existing conditions cover.
  """

  alias Portal.Policies.Postures.Fields.Classifier

  @providers ~w[firezone intune iru defender santa sentinelone]a

  @types ~w[string enum_string boolean integer float version datetime date ip string_array json]a

  @string_operators ~w[
    is is_not is_in is_not_in contains does_not_contain starts_with ends_with matches does_not_match
  ]a

  @operators %{
    string: @string_operators,
    enum_string: @string_operators,
    boolean: ~w[is]a,
    integer: ~w[eq ne gt gte lt lte]a,
    float: ~w[eq ne gt gte lt lte]a,
    version: ~w[is is_not gt gte lt lte]a,
    datetime: ~w[before after within_last not_within_last]a,
    date: ~w[before after within_last not_within_last]a,
    ip: ~w[is_in_cidr is_not_in_cidr]a,
    string_array: ~w[contains does_not_contain contains_any_of contains_all_of is_empty is_not_empty]a,
    json: ~w[is_empty is_not_empty]a
  }

  @universal_operators ~w[exists does_not_exist]a

  @all_operators @operators |> Map.values() |> List.flatten() |> Enum.concat(@universal_operators) |> Enum.uniq()

  @firezone %{
    name: :string,
    hostname: :string,
    device_serial: :string,
    device_uuid: :string,
    identifier_for_vendor: :string,
    last_attested_device_serial: :string,
    last_attested_device_uuid: :string,
    last_attested_mdm_device_id: :string,
    last_attested_cert_serial: :string,
    last_attested_cert_fingerprint: :string,
    last_attested_at: :datetime,
    last_seen_version: :version,
    last_seen_user_agent: :string,
    last_seen_remote_ip_location_city: :string,
    ipv4: :ip,
    ipv6: :ip,
    attested: :boolean
  }

  @mirrors [
    {:intune, Portal.Intune.Device,
     excluded: [:intune_id],
     enum_string: ~w[
       compliance_state management_state management_agent managed_device_owner_type
       device_enrollment_type device_registration_state partner_reported_threat_state
       exchange_access_state exchange_access_state_reason attestation_status
     ]a,
     version: ~w[
       os_version attestation_content_version attestation_boot_manager_version
       attestation_code_integrity_check_version attestation_boot_app_security_version
       attestation_boot_manager_security_version attestation_tpm_version
     ]a},
    {:iru, Portal.Iru.Device,
     excluded: [:iru_id],
     enum_string: ~w[
       platform lost_mode_status external_boot_level secure_boot_level filevault_key_type
       firewall_logging_option cellular_technology device_family
     ]a,
     version: ~w[
       os_version display_os_version supplemental_os_version_extra agent_version
       firewall_version gatekeeper_version gatekeeper_opaque_version xprotect_version
       malware_removal_tool_version
     ]a},
    {:defender, Portal.Defender.Device,
     excluded: [:defender_id],
     enum_string: ~w[
       os_platform os_architecture health_status onboarding_status managed_by
       managed_by_status risk_score exposure_level device_value exclusion_reason
     ]a,
     version: ~w[agent_version]a},
    {:santa, Portal.Santa.Device,
     excluded: [:id, :santa_id],
     enum_string: ~w[os_type last_seen_client_mode configured_client_mode]a,
     version: ~w[os_version santa_version santanetd_version]a},
    {:sentinelone, Portal.SentinelOne.Device,
     excluded: [:uuid, :license_key],
     enum_string: ~w[
       os_arch os_type machine_type network_status scan_status mitigation_mode
       mitigation_mode_suspicious console_migration_status apps_vulnerability_status
       location_type ranger_status operational_state remote_profiling_state
       detection_state proxy_method installer_type
     ]a,
     version: ~w[agent_version ranger_version os_revision]a}
  ]

  @registry @mirrors
            |> Map.new(fn {provider, schema, opts} -> {provider, Classifier.classify!(schema, opts)} end)
            |> Map.put(:firezone, @firezone)

  @provider_names Map.new(@providers, &{Atom.to_string(&1), &1})
  @operator_names Map.new(@all_operators, &{Atom.to_string(&1), &1})

  @field_names Map.new(@registry, fn {provider, fields} ->
                 {provider, Map.new(fields, fn {field, _type} -> {Atom.to_string(field), field} end)}
               end)

  @spec providers() :: [atom()]
  def providers, do: @providers

  @spec types() :: [atom()]
  def types, do: @types

  @spec registry() :: %{atom() => %{atom() => atom()}}
  def registry, do: @registry

  @spec operators(atom()) :: [atom()]
  def operators(type) when type in @types, do: Map.fetch!(@operators, type) ++ @universal_operators

  @spec universal_operators() :: [atom()]
  def universal_operators, do: @universal_operators

  @doc "Resolves a provider name from the wire without creating atoms."
  @spec fetch_provider(String.t()) :: {:ok, atom()} | :error
  def fetch_provider(name) when is_binary(name), do: Map.fetch(@provider_names, name)

  @doc "Resolves a field name from the wire to its atom and type without creating atoms."
  @spec fetch_field(atom(), String.t()) :: {:ok, atom(), atom()} | :error
  def fetch_field(provider, name) when is_binary(name) do
    with {:ok, field} <- Map.fetch(@field_names[provider] || %{}, name) do
      {:ok, field, Map.fetch!(@registry[provider], field)}
    end
  end

  @doc "Resolves an operator name from the wire without creating atoms."
  @spec fetch_operator(String.t()) :: {:ok, atom()} | :error
  def fetch_operator(name) when is_binary(name), do: Map.fetch(@operator_names, name)
end

defmodule Portal.Policies.Postures.FieldsTest do
  use ExUnit.Case, async: true

  alias Portal.Policies.Postures.Fields
  alias Portal.Policies.Postures.Fields.Classifier

  @mirrors %{
    intune: Portal.Intune.Device,
    iru: Portal.Iru.Device,
    defender: Portal.Defender.Device,
    santa: Portal.Santa.Device,
    sentinelone: Portal.SentinelOne.Device
  }

  defmodule Unmapped do
    use Ecto.Schema

    @primary_key false
    schema "unmapped" do
      field :blob, :binary
    end
  end

  defmodule Mapped do
    use Ecto.Schema

    @primary_key false
    schema "mapped" do
      field :account_id, :binary_id
      field :text, :string
      field :flag, :boolean
      field :count, :integer
      field :ratio, :float
      field :at, :utc_datetime_usec
      field :on, :date
      field :ip, Portal.Types.IP
      field :tags, {:array, :string}
      field :blob, :map
      field :blobs, {:array, :map}
      field :label, :string
      field :release, :string
    end
  end

  test "providers/0 lists firezone and every mirror" do
    assert Fields.providers() == [:firezone, :intune, :iru, :defender, :santa, :sentinelone]
  end

  test "types/0 lists every semantic type and each has operators" do
    assert Fields.types() ==
             ~w[string enum_string boolean integer float version datetime date ip string_array json]a

    for type <- Fields.types() do
      operators = Fields.operators(type)
      assert :exists in operators
      assert :does_not_exist in operators
      assert length(operators) > 2
    end
  end

  test "universal_operators/0 apply to every type" do
    assert Fields.universal_operators() == [:exists, :does_not_exist]
  end

  test "registry/0 covers every provider" do
    assert Map.keys(Fields.registry()) |> Enum.sort() == Enum.sort(Fields.providers())
  end

  for {provider, schema} <- @mirrors do
    test "registry/0 classifies every telemetry column of #{provider}" do
      registry = Fields.registry()[unquote(provider)]
      columns = unquote(schema).__schema__(:fields)

      excluded =
        ~w[account_id posture_provider_id inserted_at updated_at]a ++
          ~w[intune_id iru_id defender_id id santa_id uuid license_key]a

      for column <- columns -- excluded do
        assert {:ok, type} = Map.fetch(registry, column)
        assert type in Fields.types()
      end

      for column <- excluded do
        refute Map.has_key?(registry, column)
      end

      assert registry.enrolled == :boolean
    end
  end

  test "registry/0 for firezone is an allowlist that leaves conditions and secrets out" do
    firezone = Fields.registry().firezone

    assert firezone.attested == :boolean
    assert firezone.last_seen_version == :version
    assert firezone.ipv4 == :ip
    assert firezone.last_attested_at == :datetime

    for column <- ~w[last_seen_remote_ip last_seen_remote_ip_location_region verified_at psk_base
                     public_key last_attested_cert_issuer firebase_installation_id enrolled]a do
      refute Map.has_key?(firezone, column)
    end

    for {column, _type} <- firezone, column != :attested do
      assert column in Portal.Device.__schema__(:fields)
    end
  end

  test "registry/0 applies the semantic overrides" do
    registry = Fields.registry()

    assert registry.intune.compliance_state == :enum_string
    assert registry.intune.os_version == :version
    assert registry.intune.jail_broken == :boolean
    assert registry.intune.android_security_patch_level == :date
    assert registry.intune.device_action_results == :json
    assert registry.iru.device_capacity_gb == :float
    assert registry.iru.tags == :string_array
    assert registry.defender.last_ip_address == :ip
    assert registry.defender.os_build == :integer
    assert registry.defender.version == :string
    assert registry.santa.sip_status == :integer
    assert registry.sentinelone.os_revision == :version
    assert registry.sentinelone.cloud_providers == :json
    assert registry.sentinelone.group_ip == :string
  end

  test "fetch_provider/1 resolves known names only" do
    assert Fields.fetch_provider("intune") == {:ok, :intune}
    assert Fields.fetch_provider("firezone") == {:ok, :firezone}
    assert Fields.fetch_provider("jamf") == :error
    assert Fields.fetch_provider("") == :error
  end

  test "fetch_field/2 resolves a field with its type" do
    assert Fields.fetch_field(:intune, "compliance_state") == {:ok, :compliance_state, :enum_string}
    assert Fields.fetch_field(:firezone, "attested") == {:ok, :attested, :boolean}
    assert Fields.fetch_field(:intune, "account_id") == :error
    assert Fields.fetch_field(:intune, "nope") == :error
    assert Fields.fetch_field(:jamf, "serial_number") == :error
  end

  test "fetch_operator/1 resolves known operators only" do
    assert Fields.fetch_operator("within_last") == {:ok, :within_last}
    assert Fields.fetch_operator("exists") == {:ok, :exists}
    assert Fields.fetch_operator("like") == :error
  end

  test "operators/1 per type" do
    assert Fields.operators(:boolean) == [:is, :exists, :does_not_exist]
    assert :matches in Fields.operators(:string)
    assert :matches in Fields.operators(:enum_string)
    assert Fields.operators(:integer) == Fields.operators(:float)
    assert :within_last in Fields.operators(:datetime)
    assert :within_last in Fields.operators(:date)
    assert Fields.operators(:ip) == [:is_in_cidr, :is_not_in_cidr, :exists, :does_not_exist]
    assert :contains_all_of in Fields.operators(:string_array)
    assert Fields.operators(:json) == [:is_empty, :is_not_empty, :exists, :does_not_exist]
    assert Fields.operators(:version) == [:is, :is_not, :gt, :gte, :lt, :lte, :exists, :does_not_exist]
  end

  describe "Classifier.classify!/2" do
    test "raises on an override naming a column the schema lacks" do
      assert_raise ArgumentError, ~r/has no columns \[:nope\]/, fn ->
        Classifier.classify!(Portal.Santa.Device, excluded: [:id, :santa_id], version: [:nope])
      end
    end

    test "raises on a column type with no posture type" do
      assert_raise ArgumentError, ~r/blob has no posture type for :binary/, fn ->
        Classifier.classify!(Unmapped, excluded: [])
      end
    end

    test "maps every supported column type" do
      assert Classifier.classify!(Mapped, excluded: [], enum_string: [:label], version: [:release]) == %{
               text: :string,
               flag: :boolean,
               count: :integer,
               ratio: :float,
               at: :datetime,
               on: :date,
               ip: :ip,
               tags: :string_array,
               blob: :json,
               blobs: :json,
               label: :enum_string,
               release: :version,
               enrolled: :boolean
             }
    end

    test "excludes bookkeeping and the given columns" do
      classified = Classifier.classify!(Portal.Santa.Device, excluded: [:id, :santa_id])
      refute Map.has_key?(classified, :account_id)
      refute Map.has_key?(classified, :santa_id)
      assert classified.hostname == :string
      assert classified.enrolled == :boolean
    end
  end
end

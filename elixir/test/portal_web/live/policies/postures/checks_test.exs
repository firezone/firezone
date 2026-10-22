defmodule PortalWeb.Policies.Postures.ChecksTest do
  use ExUnit.Case, async: true

  alias Portal.Policies.Postures
  alias PortalWeb.Policies.Postures.Checks

  test "every check expands to a valid tree and names its providers truthfully" do
    for check <- Checks.all() do
      assert {:ok, postures} = Postures.cast(check.expansion), "#{check.name} does not parse"
      assert Postures.to_map(postures) == check.expansion
      assert providers(check.expansion) == Enum.sort(check.providers), "#{check.name} lists the wrong providers"
      assert check.platforms != []
    end
  end

  test "platforms follow from the fields each check reads" do
    expected = %{
      compliant: ~w[windows macos ios android]a,
      disk_encryption: ~w[windows macos linux ios android]a,
      endpoint_protection: ~w[windows macos linux ios android]a,
      no_active_threats: ~w[windows macos linux]a,
      firewall: ~w[windows macos linux]a,
      not_jailbroken: ~w[ios android]a,
      recently_seen: ~w[windows macos linux ios android]a,
      secure_boot: ~w[windows macos]a,
      corporate_owned: ~w[windows macos ios android]a,
      supervised: ~w[macos ios]a,
      app_allowlisting: ~w[macos]a,
      agent_up_to_date: ~w[windows macos linux]a,
      os_up_to_date: ~w[windows macos ios android]a,
      client_up_to_date: ~w[windows macos linux ios android]a,
      managed: ~w[windows macos ios android]a
    }

    assert Map.new(Checks.all(), &{&1.name, &1.platforms}) == expected
  end

  test "a check keeps its tree from before Sophos joined it" do
    {:ok, check} = Checks.fetch(:disk_encryption)

    assert check.previous == [
             %{
               "or" => [
                 %{"field" => "intune.is_encrypted", "op" => "is", "value" => true},
                 %{"field" => "intune.attestation_bit_locker_enabled", "op" => "is", "value" => true},
                 %{"field" => "iru.filevault_enabled", "op" => "is", "value" => true}
               ]
             }
           ]

    {:ok, compliant} = Checks.fetch(:compliant)
    assert compliant.previous == []
  end

  test "names/0 and fetch/1 agree" do
    for name <- Checks.names() do
      assert {:ok, %{name: ^name}} = Checks.fetch(name)
      assert {:ok, %{name: ^name}} = Checks.fetch(Atom.to_string(name))
    end

    assert Checks.fetch(:bogus) == :error
    assert Checks.fetch("bogus") == :error
  end

  defp providers(%{"field" => field}), do: [field |> String.split(".") |> hd() |> String.to_existing_atom()]
  defp providers(%{"not" => node}), do: providers(node)
  defp providers(%{"and" => nodes}), do: nodes |> Enum.flat_map(&providers/1) |> Enum.uniq() |> Enum.sort()
  defp providers(%{"or" => nodes}), do: nodes |> Enum.flat_map(&providers/1) |> Enum.uniq() |> Enum.sort()
end

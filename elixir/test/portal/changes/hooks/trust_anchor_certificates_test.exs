defmodule Portal.Changes.Hooks.TrustAnchorCertificatesTest do
  use Portal.DataCase, async: true

  import Portal.Changes.Hooks.TrustAnchorCertificates
  alias Portal.{Changes.Change, PubSub, TrustAnchorCertificate}

  setup do
    account_id = Ecto.UUID.generate()
    certificate_id = Ecto.UUID.generate()

    data = %{
      "id" => certificate_id,
      "account_id" => account_id,
      "trust_anchor_id" => Ecto.UUID.generate(),
      "fingerprint" => "AB:CD"
    }

    :ok = PubSub.Changes.subscribe(account_id, :trust_anchor_certificates)

    %{certificate_id: certificate_id, data: data}
  end

  test "does not broadcast an inserted certificate", %{data: data} do
    assert :ok = on_insert(1, data)
    refute_receive %Change{}
  end

  test "does not broadcast an updated certificate", %{data: data} do
    assert :ok = on_update(2, data, data)
    refute_receive %Change{}
  end

  test "broadcasts a deleted certificate", %{data: data, certificate_id: certificate_id} do
    assert :ok = on_delete(3, data)

    assert_receive %Change{
      lsn: 3,
      op: :delete,
      old_struct: %TrustAnchorCertificate{id: ^certificate_id}
    }
  end
end

defmodule Portal.Authentication.SubjectTest do
  use Portal.DataCase, async: true

  import Portal.SubjectFixtures
  alias Portal.Authentication.Subject

  test "snapshots present attestation fields as JSON-safe values" do
    subject = subject_fixture()
    device = %Portal.Device{
      last_attested_device_serial: "serial",
      last_attested_device_uuid: "uuid",
      last_attested_mdm_device_id: "mdm",
      last_attested_cert_serial: "ABCD",
      last_attested_cert_fingerprint: "fingerprint",
      last_attested_cert_issuer: <<0, 255, 128>>,
      last_attested_at: ~U[2026-09-01 12:00:00.000000Z]
    }

    snapshot = subject |> Subject.with_device(device) |> Subject.to_map()
    assert snapshot == Map.merge(Subject.to_map(subject), %{
      attested_device_serial: "serial",
      attested_device_uuid: "uuid",
      attested_mdm_device_id: "mdm",
      attested_cert_serial: "ABCD",
      attested_cert_fingerprint: "fingerprint",
      attested_cert_issuer: "AP+A",
      attested_at: "2026-09-01T12:00:00.000000Z"
    })
    assert JSON.decode!(JSON.encode!(snapshot))["attested_cert_issuer"] == "AP+A"
  end

  test "omits absent fields and retains the device's historical attestation" do
    subject = subject_fixture()
    device = %Portal.Device{attested?: false, last_attested_device_serial: "serial"}
    enriched = Subject.with_device(subject, device)
    assert Subject.to_map(enriched) == Map.put(Subject.to_map(subject), :attested_device_serial, "serial")
    assert enriched |> Subject.with_device(%Portal.Device{}) |> Subject.to_map() == Subject.to_map(subject)
  end
end

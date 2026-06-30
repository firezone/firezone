defmodule Portal.TrustAnchorTest do
  use Portal.DataCase, async: true

  import Ecto.Changeset
  import Portal.AccountFixtures
  import Portal.TrustAnchorFixtures

  alias Portal.{TrustAnchor, TrustAnchorCertificate}

  defp build_changeset(attrs) do
    %TrustAnchor{}
    |> cast(attrs, [:name, :certs, :account_id])
    |> TrustAnchor.changeset()
  end

  describe "changeset/1 basic validations" do
    test "validates name is required" do
      changeset = build_changeset(%{certs: [sample_cert_der()]})
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates name length maximum" do
      changeset =
        build_changeset(%{name: String.duplicate("a", 256), certs: [sample_cert_der()]})

      assert %{name: ["should be at most 255 character(s)"]} = errors_on(changeset)
    end

    test "validates certs are required when missing" do
      changeset = build_changeset(%{name: "Corporate Issuing CA"})
      assert %{certs: ["must contain at least one CA certificate"]} = errors_on(changeset)
    end

    test "validates certs are required when empty" do
      changeset = build_changeset(%{name: "Corporate Issuing CA", certs: []})
      assert %{certs: ["must contain at least one CA certificate"]} = errors_on(changeset)
    end

    test "preserves cast errors for invalid cert list types" do
      changeset = build_changeset(%{name: "Corporate Issuing CA", certs: "not-a-list"})
      assert %{certs: ["is invalid"]} = errors_on(changeset)
    end

    test "treats explicit empty certificate entries as missing" do
      changeset =
        %TrustAnchor{}
        |> change(%{name: "Corporate Issuing CA", certs: [""]})
        |> TrustAnchor.changeset()

      assert %{certs: ["must contain at least one CA certificate"]} = errors_on(changeset)
    end

    test "validates cert minimum length" do
      changeset =
        build_changeset(%{
          name: "Corporate Issuing CA",
          certs: [Base.encode64("too short")]
        })

      assert %{certs: ["invalid certificate"]} = errors_on(changeset)
    end

    test "accepts raw DER certificate bytes and stores them as DER" do
      changeset =
        build_changeset(%{
          name: "Corporate Issuing CA",
          certs: [sample_cert_der()]
        })

      assert changeset.valid?
      assert get_change(changeset, :certs) == [sample_cert_der()]
    end

    test "accepts PEM certificate text and normalizes it to DER" do
      changeset =
        build_changeset(%{
          name: "Corporate Issuing CA",
          certs: [sample_cert_pem()]
        })

      assert changeset.valid?
      assert get_change(changeset, :certs) == [sample_cert_der()]
    end

    test "accepts base64 DER certificate text and normalizes it to DER" do
      changeset =
        build_changeset(%{
          name: "Corporate Issuing CA",
          certs: [sample_cert_base64()]
        })

      assert changeset.valid?
      assert get_change(changeset, :certs) == [sample_cert_der()]
    end

    test "accepts CA certificates without a key usage extension" do
      changeset =
        build_changeset(%{
          name: "Corporate Issuing CA",
          certs: [sample_no_key_usage_ca_der()]
        })

      assert changeset.valid?
      assert get_change(changeset, :certs) == [sample_no_key_usage_ca_der()]
    end

    test "accepts PEM bundles and stores individual DER certificates" do
      changeset =
        build_changeset(%{
          name: "Corporate Issuing CA",
          certs: [sample_cert_pem() <> sample_additional_ca_pem()]
        })

      assert changeset.valid?
      assert get_change(changeset, :certs) == [sample_cert_der(), sample_additional_ca_der()]
    end

    test "rejects malformed PEM bundles" do
      changeset =
        build_changeset(%{
          name: "Corporate Issuing CA",
          certs: ["-----BEGIN CERTIFICATE-----"]
        })

      assert %{certs: ["invalid certificate"]} = errors_on(changeset)
    end

    test "rejects PEM payloads with no decoded entries" do
      changeset =
        build_changeset(%{
          name: "Corporate Issuing CA",
          certs: ["-----BEGIN GARBAGE-----\nZm9v\n-----END GARBAGE-----\n"]
        })

      assert %{certs: ["invalid certificate"]} = errors_on(changeset)
    end

    test "rejects invalid certificate data" do
      changeset =
        build_changeset(%{
          name: "Corporate Issuing CA",
          certs: [Base.encode64(String.duplicate("a", 128))]
        })

      assert %{certs: ["invalid certificate"]} = errors_on(changeset)
    end

    test "rejects plain text that is neither PEM nor base64" do
      changeset =
        build_changeset(%{
          name: "Corporate Issuing CA",
          certs: [String.duplicate("!", 128)]
        })

      assert %{certs: ["invalid certificate"]} = errors_on(changeset)
    end

    test "rejects cert bundle entries that are not binaries" do
      changeset =
        %TrustAnchor{}
        |> change(%{name: "Corporate Issuing CA", certs: [sample_cert_der(), 123]})
        |> TrustAnchor.changeset()

      assert %{certs: ["invalid certificate"]} = errors_on(changeset)
    end

    test "rejects PEM input that contains a private key" do
      changeset =
        build_changeset(%{
          name: "Corporate Issuing CA",
          certs: [sample_cert_pem() <> sample_private_key_pem()]
        })

      assert %{certs: ["invalid certificate"]} = errors_on(changeset)
    end

    test "rejects CA certificates whose key usage omits keyCertSign" do
      changeset =
        build_changeset(%{
          name: "Corporate Issuing CA",
          certs: [sample_missing_key_cert_sign_ca_der()]
        })

      assert %{certs: ["all CA certificates must allow certificate signing"]} =
               errors_on(changeset)
    end

    test "rejects non-CA certificates in the uploaded bundle" do
      changeset =
        build_changeset(%{
          name: "Corporate Issuing CA",
          certs: [sample_leaf_cert_der()]
        })

      assert %{certs: ["all certificates must be CA certificates"]} = errors_on(changeset)
    end

    test "rejects PEM bundles that contain a non-CA certificate" do
      changeset =
        build_changeset(%{
          name: "Corporate Issuing CA",
          certs: [sample_cert_pem() <> sample_leaf_cert_pem()]
        })

      assert %{certs: ["all certificates must be CA certificates"]} = errors_on(changeset)
    end
  end

  describe "changeset/1 association constraints" do
    test "enforces account association constraint" do
      {:error, changeset} =
        %TrustAnchor{}
        |> cast(
          %{
            account_id: Ecto.UUID.generate(),
            name: "Corporate Issuing CA",
            certs: [sample_cert_der()]
          },
          [:account_id, :name, :certs]
        )
        |> TrustAnchor.changeset()
        |> Repo.insert()

      assert %{account: ["does not exist"]} = errors_on(changeset)
    end

    test "maps the unique account/name constraint to the name field" do
      account = account_fixture()

      attrs = %{
        name: "Corporate Issuing CA",
        certs: [sample_cert_der()]
      }

      {:ok, _trust_anchor} =
        %TrustAnchor{}
        |> cast(attrs, [:name, :certs])
        |> put_assoc(:account, account)
        |> TrustAnchor.changeset()
        |> Repo.insert()

      {:error, changeset} =
        %TrustAnchor{}
        |> cast(attrs, [:name, :certs])
        |> put_assoc(:account, account)
        |> TrustAnchor.changeset()
        |> Repo.insert()

      assert %{name: ["has already been taken"]} = errors_on(changeset)
    end
  end

  describe "Repo CRUD" do
    test "inserts successfully" do
      account = account_fixture()

      {:ok, trust_anchor} =
        %TrustAnchor{}
        |> cast(
          %{
            name: "Corporate Issuing CA",
            certs: [sample_cert_der()]
          },
          [:name, :certs]
        )
        |> put_assoc(:account, account)
        |> TrustAnchor.changeset()
        |> Repo.insert()

      assert trust_anchor.account_id == account.id
      assert trust_anchor.name == "Corporate Issuing CA"
      assert Enum.map(trust_anchor.certificates, & &1.der) == [sample_cert_der()]
      assert trust_anchor.inserted_at
      assert trust_anchor.updated_at
    end

    test "stores and retrieves multiple certificates successfully" do
      account = account_fixture()

      {:ok, trust_anchor} =
        %TrustAnchor{}
        |> cast(
          %{
            name: "Corporate Issuing CA",
            certs: [sample_cert_pem(), sample_additional_ca_pem()]
          },
          [:name, :certs]
        )
        |> put_assoc(:account, account)
        |> TrustAnchor.changeset()
        |> Repo.insert()

      reloaded_trust_anchor =
        TrustAnchor
        |> Repo.get_by(account_id: trust_anchor.account_id, id: trust_anchor.id)
        |> Repo.preload(:certificates)

      assert reloaded_trust_anchor
      certs = MapSet.new(reloaded_trust_anchor.certificates, & &1.der)
      assert certs == MapSet.new([sample_cert_der(), sample_additional_ca_der()])
    end

    test "updates successfully" do
      trust_anchor = trust_anchor_fixture()

      {:ok, trust_anchor} =
        trust_anchor
        |> change(%{
          name: "Updated Issuing CA",
          certs: [sample_cert_pem(), sample_additional_ca_pem()]
        })
        |> TrustAnchor.changeset()
        |> Repo.update()

      assert trust_anchor.name == "Updated Issuing CA"

      certs = MapSet.new(trust_anchor.certificates, & &1.der)
      assert certs == MapSet.new([sample_cert_der(), sample_additional_ca_der()])
    end

    test "deletes successfully" do
      trust_anchor = trust_anchor_fixture()

      assert {:ok, deleted_trust_anchor} = Repo.delete(trust_anchor)
      assert deleted_trust_anchor.id == trust_anchor.id

      assert is_nil(
               Repo.get_by(TrustAnchor,
                 account_id: trust_anchor.account_id,
                 id: trust_anchor.id
               )
             )

      assert Repo.all(TrustAnchorCertificate) == []
    end

    test "allows the same name in different accounts" do
      name = "Corporate Issuing CA"

      trust_anchor =
        trust_anchor_fixture(%{
          name: name,
          account: account_fixture()
        })

      {:ok, second_trust_anchor} =
        %TrustAnchor{}
        |> cast(
          %{
            name: name,
            certs: [sample_cert_der()]
          },
          [:name, :certs]
        )
        |> put_assoc(:account, account_fixture())
        |> TrustAnchor.changeset()
        |> Repo.insert()

      assert second_trust_anchor.name == trust_anchor.name
      assert second_trust_anchor.account_id != trust_anchor.account_id
    end
  end

  describe "duplicate certificate uniqueness" do
    test "rejects the same certificate added to a different trust anchor in the same account" do
      account = account_fixture()
      trust_anchor_fixture(%{name: "First Anchor", account: account, certs: [sample_cert_der()]})

      {:error, changeset} =
        %TrustAnchor{}
        |> cast(%{name: "Second Anchor", certs: [sample_cert_der()]}, [:name, :certs])
        |> put_assoc(:account, account)
        |> TrustAnchor.changeset()
        |> Repo.insert()

      assert %{certificates: [%{fingerprint: ["this certificate is already used by another trust anchor"]}]} =
               errors_on(changeset)
    end

    test "allows the same certificate across different accounts" do
      trust_anchor_fixture(%{
        name: "First Anchor",
        account: account_fixture(),
        certs: [sample_cert_der()]
      })

      {:ok, second_trust_anchor} =
        %TrustAnchor{}
        |> cast(%{name: "Second Anchor", certs: [sample_cert_der()]}, [:name, :certs])
        |> put_assoc(:account, account_fixture())
        |> TrustAnchor.changeset()
        |> Repo.insert()

      assert Enum.map(second_trust_anchor.certificates, & &1.der) == [sample_cert_der()]
    end

    test "allows replacing a trust anchor's certs with the same fingerprint on update" do
      trust_anchor = trust_anchor_fixture(%{certs: [sample_cert_der()]})

      {:ok, updated} =
        trust_anchor
        |> change(%{certs: [sample_cert_der()]})
        |> TrustAnchor.changeset()
        |> Repo.update()

      assert Enum.map(updated.certificates, & &1.der) == [sample_cert_der()]
    end
  end
end

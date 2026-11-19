defmodule Portal.Ops.AdminTest do
  use Portal.DataCase, async: true

  alias Portal.Ops.{Admin, Passkey, Repo}

  @moduletag :ops_repo

  describe "Portal.Ops.provision_admin/1" do
    test "stores the email in lowercase" do
      assert {:ok, %Admin{email: "ada@firezone.dev"} = admin} = Portal.Ops.provision_admin(" Ada@Firezone.dev ")
      assert Repo.get!(Admin, admin.id).email == "ada@firezone.dev"
    end

    test "returns the existing admin for a provisioned email" do
      {:ok, admin} = Portal.Ops.provision_admin("ada@firezone.dev")

      assert {:ok, %Admin{id: id}} = Portal.Ops.provision_admin("ADA@firezone.dev")
      assert id == admin.id
      assert Repo.aggregate(Admin, :count) == 1
    end

    test "rejects an invalid email" do
      assert {:error, changeset} = Portal.Ops.provision_admin("not an email")
      assert %{email: ["has invalid format"]} = errors_on(changeset)
    end
  end

  describe "Portal.Ops.deprovision_admin/1" do
    test "removes the admin and their passkeys" do
      {:ok, admin} = Portal.Ops.provision_admin("ada@firezone.dev")

      Repo.insert!(%Passkey{
        admin_id: admin.id,
        name: "Laptop",
        credential_id: "cred",
        public_key: Passkey.encode_cose_key(%{1 => 2})
      })

      assert Portal.Ops.deprovision_admin("Ada@firezone.dev") == :ok
      refute Repo.get(Admin, admin.id)
      assert Repo.aggregate(Passkey, :count) == 0
    end

    test "reports an unknown email" do
      assert Portal.Ops.deprovision_admin("nobody@firezone.dev") == {:error, :not_found}
    end
  end

  describe "Portal.Ops.Passkey" do
    test "round-trips a COSE key" do
      cose_key = %{1 => 2, 3 => -7, -1 => 1, -2 => <<1, 2, 3>>, -3 => <<4, 5, 6>>}
      passkey = %Passkey{public_key: Passkey.encode_cose_key(cose_key)}

      assert Passkey.cose_key(passkey) == cose_key
    end
  end
end

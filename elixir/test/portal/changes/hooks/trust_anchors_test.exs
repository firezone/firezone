defmodule Portal.Changes.Hooks.TrustAnchorsTest do
  use Portal.DataCase, async: true

  import Portal.AccountFixtures
  import Portal.TrustAnchorFixtures

  alias Portal.Changes.Change
  alias Portal.Changes.Hooks.TrustAnchorCertificates
  alias Portal.Changes.Hooks.TrustAnchors

  setup do
    account = account_fixture()
    trust_anchor = trust_anchor_fixture(account: account)

    %{account: account, trust_anchor: trust_anchor}
  end

  describe "trust anchors" do
    test "broadcasts every operation", %{account: account, trust_anchor: trust_anchor} do
      :ok = Portal.PubSub.Changes.subscribe(account.id, :trust_anchors)
      data = %{"id" => trust_anchor.id, "account_id" => account.id, "name" => trust_anchor.name}

      assert TrustAnchors.on_insert(0, data) == :ok
      assert_receive %Change{op: :insert}

      assert TrustAnchors.on_update(1, data, data) == :ok
      assert_receive %Change{op: :update}

      # A deleted anchor is the case that matters: a policy naming it has to
      # stop granting access without waiting for each device to reconnect.
      assert TrustAnchors.on_delete(2, data) == :ok
      assert_receive %Change{op: :delete, old_struct: nil, struct: %Portal.TrustAnchor{}}
    end
  end

  describe "trust anchor certificates" do
    test "broadcasts when the material behind an anchor changes", %{
      account: account,
      trust_anchor: trust_anchor
    } do
      # Replacing an anchor's certificates need not write to the anchor row, so
      # the anchor's own hook would not fire for it.
      :ok = Portal.PubSub.Changes.subscribe(account.id, :trust_anchor_certificates)

      data = %{
        "id" => Ecto.UUID.generate(),
        "account_id" => account.id,
        "trust_anchor_id" => trust_anchor.id
      }

      assert TrustAnchorCertificates.on_delete(0, data) == :ok
      assert_receive %Change{op: :delete, struct: %Portal.TrustAnchorCertificate{}}
    end
  end
end

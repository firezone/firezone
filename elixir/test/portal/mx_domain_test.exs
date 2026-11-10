defmodule Portal.MXDomainTest do
  use Portal.DataCase, async: true
  alias Portal.MXDomain

  defp changeset(attrs) do
    %MXDomain{}
    |> Ecto.Changeset.cast(attrs, [:domain, :rating, :note])
    |> MXDomain.changeset()
  end

  describe "changeset/1" do
    test "normalizes the domain" do
      changeset = changeset(%{domain: "  Mail.TM. ", rating: :bad, note: " Disposable "})

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :domain) == "mail.tm"
      assert Ecto.Changeset.get_change(changeset, :note) == "Disposable"
    end

    test "requires a note for bad domains only" do
      refute changeset(%{domain: "mail.tm", rating: :bad}).valid?
      refute changeset(%{domain: "mail.tm", rating: :bad, note: "   "}).valid?
      assert changeset(%{domain: "google.com", rating: :good}).valid?

      assert %{note: ["is required for bad domains"]} =
               errors_on(changeset(%{domain: "mail.tm", rating: :bad}))
    end

    test "rejects names that are not domains" do
      for domain <- ["tm", "mail..tm", "-mail.tm", "user@mail.tm", "mail tm.com", "bücher.example", ""] do
        refute changeset(%{domain: domain, rating: :good}).valid?, "accepted #{inspect(domain)}"
      end
    end

    test "rejects unknown ratings" do
      assert %{rating: ["is invalid"]} = errors_on(changeset(%{domain: "mail.tm", rating: :maybe}))
    end
  end

  describe "candidates/1" do
    test "returns the domain and its parents without the top-level domain" do
      assert MXDomain.candidates("a.in.mail.tm") == ["a.in.mail.tm", "in.mail.tm", "mail.tm"]
      assert MXDomain.candidates("Mail.TM.") == ["mail.tm"]
      assert MXDomain.candidates("localhost") == []
    end
  end
end

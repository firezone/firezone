defmodule Portal.KnownMxDomainTest do
  use Portal.DataCase, async: true

  alias Portal.KnownMxDomain

  defp changeset(domain) do
    %KnownMxDomain{}
    |> Ecto.Changeset.cast(%{domain: domain, verdict: :allow}, [:domain, :verdict])
    |> KnownMxDomain.changeset()
  end

  test "normalizes case, whitespace and dots" do
    assert Ecto.Changeset.get_change(changeset("  Mail.Example.COM. "), :domain) == "mail.example.com"
  end

  test "accepts domains with two or more labels" do
    for domain <- ~w[example.com mail.example.co.uk mx.microsoft a-b.example.com 1and1.com] do
      assert changeset(domain).valid?, domain
    end
  end

  test "rejects malformed domains" do
    long_label = String.duplicate("a", 64)
    too_long = Enum.map_join(1..64, ".", fn _ -> "abc" end)

    for domain <- ["com", "-a.com", "a-.com", "a..com", "a_b.com", "#{long_label}.com", too_long, ""] do
      refute changeset(domain).valid?, domain
    end
  end

  test "needs a verdict of allow or deny" do
    refute %KnownMxDomain{} |> Ecto.Changeset.cast(%{domain: "example.com"}, [:domain]) |> KnownMxDomain.changeset() |> Map.get(:valid?)
    refute %KnownMxDomain{} |> Ecto.Changeset.cast(%{domain: "example.com", verdict: "maybe"}, [:domain, :verdict]) |> Map.get(:valid?)
  end

  test "the database rejects a domain the changeset would refuse" do
    assert_raise Postgrex.Error, ~r/domain_format/, fn ->
      Portal.Repo.insert_all("known_mx_domains", [%{domain: "-bad-.com", verdict: "allow"}])
    end
  end

  test "the database rejects an unknown verdict" do
    assert_raise Postgrex.Error, ~r/verdict_values/, fn ->
      Portal.Repo.insert_all("known_mx_domains", [%{domain: "example.com", verdict: "maybe"}])
    end
  end
end

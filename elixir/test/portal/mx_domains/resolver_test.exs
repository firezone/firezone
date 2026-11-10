defmodule Portal.MXDomains.ResolverTest do
  use ExUnit.Case, async: true
  alias Portal.MXDomains.Resolver

  defp message(records) do
    :inet_dns.make_msg(anlist: Enum.map(records, &:inet_dns.make_rr/1))
  end

  defp mx(preference, host), do: [domain: ~c"example.com", type: :mx, data: {preference, host}]

  describe "mx_hosts/1" do
    test "returns the lowercased mail hosts" do
      assert Resolver.mx_hosts(message([mx(10, ~c"In.Mail.TM"), mx(20, ~c"aspmx.l.google.com")])) ==
               ["in.mail.tm", "aspmx.l.google.com"]
    end

    test "drops a null MX, which says the domain accepts no mail" do
      assert Resolver.mx_hosts(message([mx(0, ~c".")])) == []
      assert Resolver.mx_hosts(message([mx(0, ~c"")])) == []
    end

    test "ignores records other than MX" do
      cname = [domain: ~c"example.com", type: :cname, data: ~c"mail.example.net"]

      assert Resolver.mx_hosts(message([cname, mx(10, ~c"mx.example.net")])) == ["mx.example.net"]
    end

    test "returns no hosts for an empty answer" do
      assert Resolver.mx_hosts(message([])) == []
    end
  end
end

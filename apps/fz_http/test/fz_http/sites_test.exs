defmodule FzHttp.SitesTest do
  use FzHttp.DataCase

  alias FzHttp.Sites

  describe "sites" do
    alias FzHttp.Sites.Site

    import FzHttp.SitesFixtures

    @valid_sites [
      %{
        "dns" => "8.8.8.8",
        "allowed_ips" => "::/0",
        "host" => "172.10.10.10",
        "persistent_keepalive" => "20",
        "mtu" => "1280"
      },
      %{
        "dns" => "8.8.8.8",
        "allowed_ips" => "::/0",
        "host" => "foobar.example.com",
        "persistent_keepalive" => "15",
        "mtu" => "1420"
      }
    ]
    @invalid_site %{
      "dns" => "foobar",
      "allowed_ips" => "foobar",
      "host" => "foobar",
      "persistent_keepalive" => "-120",
      "mtu" => "1501"
    }

    test "get_site/1 returns the site with given id" do
      site = site_fixture()
      assert Sites.get_site!(site.id) == site
    end

    test "get_site!/1 returns the site with the given name" do
      site = Sites.get_site!(name: "default")
      assert site.name == "default"
    end

    test "update_site/2 with valid data updates the site via provided site" do
      site = Sites.get_site!(name: "default")

      for attrs <- @valid_sites do
        assert {:ok, %Site{}} = Sites.update_site(site, attrs)
      end
    end

    test "update_site/2 with invalid data returns error changeset" do
      site = Sites.get_site!(name: "default")
      assert {:error, %Ecto.Changeset{}} = Sites.update_site(site, @invalid_site)
      site = Sites.get_site!(name: "default")

      refute site.dns == "foobar"
      refute site.allowed_ips == "foobar"
      refute site.host == "foobar"
      refute site.persistent_keepalive == -120
      refute site.mtu == 1501
    end

    test "change_site/1 returns a site changeset" do
      site = site_fixture()
      assert %Ecto.Changeset{} = Sites.change_site(site)
    end
  end
end

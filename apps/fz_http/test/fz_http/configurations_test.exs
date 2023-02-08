defmodule FzHttp.ConfigurationsTest do
  use FzHttp.DataCase
  import FzHttp.ConfigurationsFixtures
  import FzHttp.SAMLIdentityProviderFixtures
  alias FzHttp.Configurations.Configuration
  alias FzHttp.Configurations

  describe "trimmed fields" do
    test "trims expected fields" do
      changeset =
        Configurations.new_configuration(%{
          "default_client_dns" => [" foo "],
          "default_client_endpoint" => " foo "
        })

      assert %Ecto.Changeset{
               changes: %{
                 default_client_dns: ["foo"],
                 default_client_endpoint: "foo"
               }
             } = changeset
    end
  end

  describe "auto_create_users?/2" do
    test "raises if provider_id not found" do
      assert_raise(RuntimeError, "Unknown provider foobar", fn ->
        Configurations.auto_create_users?(:openid_connect_providers, "foobar")
      end)
    end

    test "returns true for found provider_id" do
      configuration(%{
        saml_identity_providers: [
          %{
            "id" => "test",
            "metadata" => metadata(),
            "auto_create_users" => true,
            "label" => "SAML"
          }
        ]
      })

      assert Configurations.auto_create_users?(:saml_identity_providers, "test")
    end

    test "returns false for found provider_id" do
      configuration(%{
        saml_identity_providers: [
          %{
            "id" => "test",
            "metadata" => metadata(),
            "auto_create_users" => false,
            "label" => "SAML"
          }
        ]
      })

      refute Configurations.auto_create_users?(:saml_identity_providers, "test")
    end
  end

  describe "update_configuration/2 with name-based default_client_dns" do
    test "update_configuration/2 allows hosts for DNS" do
      configuration = configuration(%{})
      attrs = %{default_client_dns: ["foobar.com"]}
      assert {:ok, _configuration} = Configurations.update_configuration(configuration, attrs)
    end

    test "update_configuration/2 allows list hosts for DNS" do
      configuration = configuration(%{})
      attrs = %{default_client_dns: ["foobar.com", "google.com"]}
      assert {:ok, _configuration} = Configurations.update_configuration(configuration, attrs)
    end
  end

  describe "configurations" do
    @valid_configurations [
      %{
        "default_client_dns" => ["8.8.8.8"],
        "default_client_allowed_ips" => ["::/0"],
        "default_client_endpoint" => "172.10.10.10",
        "default_client_persistent_keepalive" => "20",
        "default_client_mtu" => "1280"
      },
      %{
        "default_client_dns" => ["8.8.8.8"],
        "default_client_allowed_ips" => ["::/0"],
        "default_client_endpoint" => "foobar.example.com",
        "default_client_persistent_keepalive" => "15",
        "default_client_mtu" => "1280"
      }
    ]
    @invalid_configuration %{
      "default_client_dns" => "foobar",
      "default_client_allowed_ips" => "foobar",
      "default_client_endpoint" => "foobar",
      "default_client_persistent_keepalive" => "-120",
      "default_client_mtu" => "1501"
    }

    test "get_configuration/1 returns the configuration" do
      configuration = configuration(%{})
      assert Configurations.get_configuration!() == configuration
    end

    test "update_configuration/2 with valid data updates the configuration via provided configuration" do
      configuration = Configurations.get_configuration!()

      for attrs <- @valid_configurations do
        assert {:ok, %Configuration{}} = Configurations.update_configuration(configuration, attrs)
      end
    end

    test "update_configuration/2 with invalid data returns error changeset" do
      configuration = Configurations.get_configuration!()

      assert {:error, %Ecto.Changeset{}} =
               Configurations.update_configuration(configuration, @invalid_configuration)

      configuration = Configurations.get_configuration!()

      refute configuration.default_client_dns == "foobar"
      refute configuration.default_client_allowed_ips == "foobar"
      refute configuration.default_client_endpoint == "foobar"
      refute configuration.default_client_persistent_keepalive == -120
      refute configuration.default_client_mtu == 1501
    end

    test "change_configuration/1 returns a configuration changeset" do
      configuration = configuration(%{})
      assert %Ecto.Changeset{} = Configurations.change_configuration(configuration)
    end
  end
end

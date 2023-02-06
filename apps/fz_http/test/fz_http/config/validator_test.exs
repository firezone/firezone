defmodule FzHttp.Config.ValidatorTest do
  use ExUnit.Case, async: true
  import FzHttp.Config.Validator
  alias FzHttp.Types

  describe "validate/4" do
    test "validates an array of integers" do
      assert validate(:key, "1,2,3", {:array, ",", :integer}, []) ==
               {:error, {"1,2,3", ["must be an array"]}}

      assert validate(:key, "1,2,3", {:array, :integer}, []) ==
               {:error, {"1,2,3", ["must be an array"]}}

      assert validate(:key, ~w"1 2 3", {:array, ",", :integer}, []) == {:ok, [1, 2, 3]}

      assert validate(:key, ~w"1 2 3", {:array, :integer}, []) == {:ok, [1, 2, 3]}
    end

    test "validates one of types" do
      type = {:one_of, [:integer, :boolean]}
      assert validate(:key, 1, type, []) == {:ok, 1}
      assert validate(:key, true, type, []) == {:ok, true}

      assert validate(:key, "invalid", type, []) ==
               {:error, {"invalid", ["must be one of: integer, boolean"]}}

      type = {:one_of, [Types.IP, Types.CIDR]}

      assert validate(:key, "1.1.1.1", type, []) ==
               {:ok, %Postgrex.INET{address: {1, 1, 1, 1}, netmask: nil}}

      assert validate(:key, "127.0.0.1/24", type, []) ==
               {:ok, %Postgrex.INET{address: {127, 0, 0, 1}, netmask: 24}}

      assert validate(:key, "invalid", type, []) ==
               {:error,
                {"invalid", ["must be one of: Elixir.FzHttp.Types.IP, Elixir.FzHttp.Types.CIDR"]}}

      type = {:array, {:one_of, [:integer, :boolean]}}

      assert validate(:key, [1, true, "invalid"], type, []) ==
               {:error, [{"invalid", ["must be one of: integer, boolean"]}]}
    end

    test "validates embeds" do
      type = {:array, {:embed, FzHttp.Configurations.Configuration.SAMLIdentityProvider}}

      attrs = FzHttp.SAMLIdentityProviderFixtures.saml_attrs()

      assert validate(:key, [attrs], type, []) ==
               {:ok,
                [
                  %FzHttp.Configurations.Configuration.SAMLIdentityProvider{
                    auto_create_users: attrs["auto_create_users"],
                    base_url: "http://localhost:13000/auth/saml",
                    id: attrs["id"],
                    label: attrs["label"],
                    metadata: attrs["metadata"]
                  }
                ]}

      assert validate(:key, [%{"id" => "saml"}], type, []) ==
               {:error,
                [
                  {%{"id" => "saml"},
                   [
                     "auto_create_users can't be blank",
                     "id is reserved",
                     "label can't be blank",
                     "metadata can't be blank"
                   ]}
                ]}
    end
  end
end

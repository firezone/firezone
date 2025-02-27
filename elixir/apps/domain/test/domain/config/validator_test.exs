defmodule Domain.Config.ValidatorTest do
  use ExUnit.Case, async: true
  import Domain.Config.Validator
  alias Domain.Types

  describe "validate/4" do
    test "validates an array of integers" do
      assert validate(:key, "1,2,3", {:array, "x", :integer}, []) ==
               {:error, {"1,2,3", ["must be an array"]}}

      assert validate(:key, "1,2,3", {:json_array, :integer}, []) ==
               {:error, {"1,2,3", ["must be an array"]}}

      assert validate(:key, ~w"1 2 3", {:array, ",", :integer}, []) == {:ok, [1, 2, 3]}

      assert validate(:key, ~w"1 2 3", {:array, :integer}, []) == {:ok, [1, 2, 3]}
    end

    test "validates arrays" do
      type = {:array, "x", :integer, validate_unique: true, validate_length: [min: 1, max: 3]}

      assert validate(:key, [], type, []) ==
               {:error, {[], ["should be at least 1 item(s)"]}}

      assert validate(:key, [1, 2, 3, 4], type, []) ==
               {:error, {[1, 2, 3, 4], ["should be at most 3 item(s)"]}}

      assert validate(:key, [1, 2, 1], type, []) ==
               {:error, [{1, ["should not contain duplicates"]}]}
    end

    test "validates one of types" do
      type = {:one_of, [:integer, :boolean]}
      assert validate(:key, 1, type, []) == {:ok, 1}
      assert validate(:key, true, type, []) == {:ok, true}

      assert validate(:key, "invalid", type, []) ==
               {:error, {"invalid", ["must be one of: integer, boolean"]}}

      type = {:one_of, [Types.IP, Types.CIDR]}

      assert validate(:key, "::1", type, []) ==
               {:ok, %Postgrex.INET{address: {0, 0, 0, 0, 0, 0, 0, 1}, netmask: nil}}

      assert validate(:key, "::1/foo", type, []) ==
               {:error,
                {"::1/foo",
                 [
                   "must be one of: Elixir.Domain.Types.IP, Elixir.Domain.Types.CIDR",
                   "CIDR netmask is invalid or missing"
                 ]}}

      assert validate(:key, "1.1.1.1", type, []) ==
               {:ok, %Postgrex.INET{address: {1, 1, 1, 1}, netmask: nil}}

      assert validate(:key, "1.1.1.1/foo", type, []) ==
               {:error,
                {"1.1.1.1/foo",
                 [
                   "must be one of: Elixir.Domain.Types.IP, Elixir.Domain.Types.CIDR",
                   "CIDR netmask is invalid or missing"
                 ]}}

      assert validate(:key, "127.0.0.1/24", type, []) ==
               {:ok, %Postgrex.INET{address: {127, 0, 0, 1}, netmask: 24}}

      assert validate(:key, "invalid", type, []) ==
               {:error,
                {"invalid",
                 [
                   "must be one of: Elixir.Domain.Types.IP, Elixir.Domain.Types.CIDR",
                   "CIDR netmask is invalid or missing"
                 ]}}

      type = {:json_array, {:one_of, [:integer, :boolean]}}

      assert validate(:key, [1, true, "invalid"], type, []) ==
               {:error, [{"invalid", ["must be one of: integer, boolean"]}]}
    end

    # TODO: uncomment once we have at least one config embed
    # test "validates embeds" do
    #   type = {:json_array, {:embed, Domain.Config.Configuration.SAMLIdentityProvider}}

    #   opts = [
    #     changeset: {Domain.Config.Configuration.SAMLIdentityProvider, :create_changeset, []}
    #   ]

    #   attrs = Domain.Fixtures.Config.saml_identity_providers_attrs()

    #   assert validate(:key, [attrs], type, opts) ==
    #            {:ok,
    #             [
    #               %Domain.Config.Configuration.SAMLIdentityProvider{
    #                 auto_create_users: attrs["auto_create_users"],
    #                 base_url: "http://localhost:14000/auth/saml",
    #                 id: attrs["id"],
    #                 label: attrs["label"],
    #                 metadata: attrs["metadata"]
    #               }
    #             ]}

    #   assert validate(:key, [%{"id" => "saml"}], type, opts) ==
    #            {:error,
    #             [
    #               {%{"id" => "saml"},
    #                [
    #                  "auto_create_users can't be blank",
    #                  "id is reserved",
    #                  "label can't be blank",
    #                  "metadata can't be blank"
    #                ]}
    #             ]}
    # end
  end
end

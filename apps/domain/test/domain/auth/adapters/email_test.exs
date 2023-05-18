defmodule Domain.Auth.Adapters.EmailTest do
  use Domain.DataCase, async: true
  import Domain.Auth.Adapters.Email
  alias Domain.AuthFixtures

  describe "request_sign_in_token/1" do
    test "returns identity with updated sign-in token" do
      identity = AuthFixtures.create_identity()

      assert {:ok, identity} = request_sign_in_token(identity)

      assert %{
               sign_in_token_created_at: sign_in_token_created_at,
               sign_in_token_hash: sign_in_token_hash
             } = identity.provider_state

      assert %{
               sign_in_token: sign_in_token
             } = identity.provider_virtual_state

      assert Domain.Crypto.equal?(sign_in_token, sign_in_token_hash)
      assert %DateTime{} = sign_in_token_created_at
    end
  end
end

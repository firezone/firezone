# defmodule Domain.Auth.Adapters.UserPassTest do
#   use Domain.DataCase, async: true
#   import Domain.Auth.Adapters.UserPass

#   test "does not allow to clear the password", %{subject: subject} do
#     password = "password1234"
#     actor = ActorsFixtures.create_actor(role: :admin, %{password: password})

#     attrs = %{
#       "password" => nil,
#       "password_hash" => nil
#     }

#     assert {:ok, updated_actor} = update_actor(actor, attrs, subject)
#     assert updated_actor.password_hash == actor.password_hash

#     attrs = %{
#       "password" => "",
#       "password_hash" => ""
#     }

#     assert {:ok, updated_actor} = update_actor(actor, attrs, subject)
#     assert updated_actor.password_hash == actor.password_hash
#   end

#     test "returns error on invalid attrs", %{subject: subject, account: account} do
#       assert {:error, changeset} =
#                create_actor(
#                  account,
#                  :unprivileged,
#                  %{email: "invalid_email", password: "short"},
#                  subject
#                )

#       refute changeset.valid?

#       assert errors_on(changeset) == %{
#                email: ["is invalid email address"],
#                password: ["should be at least 12 character(s)"],
#                password_confirmation: ["can't be blank"]
#              }

#       assert {:error, changeset} =
#                create_actor(
#                  account,
#                  :unprivileged,
#                  %{email: "invalid_email", password: String.duplicate("A", 65)},
#                  subject
#                )

#       refute changeset.valid?
#       assert "should be at most 64 character(s)" in errors_on(changeset).password

#       assert {:error, changeset} =
#                create_actor(account, :unprivileged, %{email: String.duplicate(" ", 18)}, subject)

#       refute changeset.valid?

#       assert "can't be blank" in errors_on(changeset).email
#     end

#     test "requires password confirmation to match the password", %{
#       subject: subject,
#       account: account
#     } do
#       assert {:error, changeset} =
#                create_actor(
#                  account,
#                  :unprivileged,
#                  %{password: "foo", password_confirmation: "bar"},
#                  subject
#                )

#       assert "does not match confirmation" in errors_on(changeset).password_confirmation

#       assert {:error, changeset} =
#                create_actor(
#                  account,
#                  :unprivileged,
#                  %{
#                    password: "password1234",
#                    password_confirmation: "password1234"
#                  },
#                  subject
#                )

#       refute Map.has_key?(errors_on(changeset), :password_confirmation)
#     end

#     test "returns error when email is already taken", %{subject: subject, account: account} do
#       attrs = ActorsFixtures.actor_attrs()
#       assert {:ok, _actor} = create_actor(account, :unprivileged, attrs, subject)
#       assert {:error, changeset} = create_actor(account, :unprivileged, attrs, subject)
#       refute changeset.valid?
#       assert "has already been taken" in errors_on(changeset).email
#     end

# test "trims email", %{subject: subject, account: account} do
#   attrs = ActorsFixtures.actor_attrs()
#   updated_attrs = Map.put(attrs, :email, " #{attrs.email} ")

#   assert {:ok, actor} = create_actor(account, :unprivileged, updated_attrs, subject)

#   assert actor.email == attrs.email
# end

# end

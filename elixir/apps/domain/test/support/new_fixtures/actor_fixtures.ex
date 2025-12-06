defmodule Domain.ActorFixtures do
  @moduledoc """
  Test helpers for creating actors and related data.
  """

  import Domain.AccountFixtures

  @doc """
  Generate valid actor attributes with sensible defaults.
  """
  def valid_actor_attrs(attrs \\ %{}) do
    unique_num = System.unique_integer([:positive, :monotonic])
    first_name = Enum.random(~w[Wade Dave Seth Riley Gilbert Jorge Dan Brian Roberto Ramon Juan])
    last_name = Enum.random(~w[Robyn Traci Desiree Jon Bob Karl Joe Alberta Lynda Cara Brandi])

    # For account_user and account_admin_user, we need an email (database constraint)
    # For service_account and api_client, we must NOT have an email
    type = Map.get(attrs, :type, :account_user)

    base_attrs = %{
      name: "#{first_name} #{last_name} #{unique_num}",
      type: type
    }

    # Add email for user types that require it
    base_attrs =
      if type in [:account_user, :account_admin_user] do
        Map.put(
          base_attrs,
          :email,
          "#{String.downcase(first_name)}.#{String.downcase(last_name)}.#{unique_num}@example.com"
        )
      else
        base_attrs
      end

    Enum.into(attrs, base_attrs)
  end

  @doc """
  Generate an actor with valid default attributes.

  The actor will be created with an associated account unless one is provided.

  ## Examples

      actor = actor_fixture()
      actor = actor_fixture(name: "John Doe")
      actor = actor_fixture(account: account, type: :account_admin_user)

  """
  def actor_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    # Get or create account
    account = Map.get(attrs, :account) || account_fixture()

    # Build actor attrs without the account key
    actor_attrs =
      attrs
      |> Map.delete(:account)
      |> valid_actor_attrs()

    {:ok, actor} =
      %Domain.Actor{}
      |> Ecto.Changeset.cast(actor_attrs, [:name, :type, :email, :allow_email_otp_sign_in])
      |> Ecto.Changeset.put_assoc(:account, account)
      |> Domain.Actor.changeset()
      |> Domain.Repo.insert()

    actor
  end

  @doc """
  Generate an admin actor.
  """
  def admin_actor_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    actor_fixture(Map.put(attrs, :type, :account_admin_user))
  end

  @doc """
  Generate a service account actor.
  """
  def service_account_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    actor_fixture(Map.put(attrs, :type, :service_account))
  end

  @doc """
  Generate an API client actor.
  """
  def api_client_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    actor_fixture(Map.put(attrs, :type, :api_client))
  end

  @doc """
  Generate an actor with an email.
  """
  def actor_with_email_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    unique_num = System.unique_integer([:positive, :monotonic])
    email = "user#{unique_num}@example.com"

    actor_fixture(Map.put(attrs, :email, email))
  end

  @doc """
  Generate a disabled actor.
  """
  def disabled_actor_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    actor = actor_fixture(attrs)

    actor
    |> Ecto.Changeset.change(disabled_at: DateTime.utc_now())
    |> Domain.Repo.update!()
  end
end

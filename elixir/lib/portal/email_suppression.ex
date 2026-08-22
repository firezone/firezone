defmodule Portal.EmailSuppression do
  use Ecto.Schema
  import Ecto.Changeset, only: [validate_required: 2, unique_constraint: 2]
  alias Portal.Email

  @primary_key false
  @timestamps_opts [type: :utc_datetime_usec]

  schema "email_suppressions" do
    field(:email, :string, primary_key: true)

    timestamps(updated_at: false)
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> validate_required([:email])
    |> unique_constraint(:email)
  end

  def normalize_email(email) when is_binary(email) do
    case Email.normalize_for_match(email) do
      {:ok, email} -> email
      :error -> email |> String.trim() |> String.downcase()
    end
  end
end

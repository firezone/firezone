defmodule Portal.EmailSuppression do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @timestamps_opts [type: :utc_datetime_usec]

  schema "email_suppressions" do
    field(:email, :string, primary_key: true)

    timestamps(updated_at: false)
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
  end

  def changeset(%__MODULE__{} = suppression, attrs) do
    suppression
    |> cast(attrs, [:email])
    |> validate_required([:email])
    |> update_change(:email, &normalize_email/1)
    |> unique_constraint(:email)
  end

  def normalize_email(email) when is_binary(email) do
    email
    |> String.trim()
    |> String.downcase()
  end
end

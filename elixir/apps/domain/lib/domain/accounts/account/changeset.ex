defmodule Domain.Accounts.Account.Changeset do
  use Domain, :changeset
  alias Domain.Accounts.{Account, Config, Features, Limits}

  @blacklisted_slugs ~w[
    sign_up signup register
    sign_in signin log_in login
    sign_out signout
    auth authorize authenticate
    create update delete claim
    account me you
    admin user system internal
  ]

  def create(attrs) do
    %Account{}
    |> cast(attrs, [:name, :slug])
    |> changeset()
  end

  def update_profile_and_config(%Account{} = account, attrs) do
    account
    |> cast(attrs, [:name])
    |> validate_name()
    |> cast_embed(:config, with: &Config.Changeset.changeset/2)
  end

  def update(%Account{} = account, attrs) do
    account
    |> cast(attrs, [:name])
    |> changeset()
  end

  def disable(%Account{} = account, attrs) do
    account
    |> cast(attrs, [:disabled_reason, :disabled_at])
    |> validate_required([:disabled_reason, :disabled_at])
  end

  defp changeset(changeset) do
    changeset
    |> validate_name()
    |> validate_slug()
    |> prepare_changes(&put_default_slug/1)
    |> cast_embed(:config, with: &Config.Changeset.changeset/2)
    |> cast_embed(:features, with: &Features.Changeset.changeset/2)
    |> cast_embed(:limits, with: &Limits.Changeset.changeset/2)
    |> cast_embed(:external_ids, with: &external_ids_changeset/2)
  end

  defp validate_name(changeset) do
    changeset
    |> validate_required([:name])
    |> trim_change(:name)
    |> validate_length(:name, min: 3, max: 64)
  end

  defp validate_slug(changeset) do
    changeset
    |> validate_length(:slug, min: 3, max: 100)
    |> update_change(:slug, &String.downcase/1)
    |> validate_format(:slug, ~r/^[a-zA-Z0-9_]+$/,
      message: "can only contain letters, numbers, and underscores"
    )
    |> validate_exclusion(:slug, @blacklisted_slugs)
    |> validate_change(:slug, fn field, slug ->
      if valid_uuid?(slug) do
        [{field, "cannot be a valid UUID"}]
      else
        []
      end
    end)
    |> unique_constraint(:slug, name: :accounts_slug_index)
  end

  defp put_default_slug(changeset) do
    put_default_value(changeset, :slug, &Domain.Accounts.generate_unique_slug/0)
  end

  def external_ids_changeset(external_ids \\ %Account.ExternalIDs{}, attrs) do
    external_ids
    |> cast(attrs, [])
    |> cast_embed(:stripe, with: &stripe_external_ids_changeset/2)
  end

  def stripe_external_ids_changeset(stripe \\ %Account.ExternalIDs.Stripe{}, attrs) do
    stripe
    |> cast(attrs, [:customer_id, :subscription_id])
  end
end

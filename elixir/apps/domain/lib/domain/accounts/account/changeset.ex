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

  @slug_regex ~r/^[a-zA-Z0-9_]+$/

  def create(attrs) do
    %Account{}
    |> cast(attrs, [:name, :legal_name, :slug])
    |> changeset()
    |> put_default_config()
  end

  def update_profile_and_config(%Account{} = account, attrs) do
    account
    |> cast(attrs, [:name, :legal_name])
    |> validate_name()
    |> validate_legal_name()
    |> cast_embed(:config, with: &Config.Changeset.changeset/2)
  end

  def update(%Account{} = account, attrs) do
    account
    |> cast(attrs, [
      :slug,
      :name,
      :legal_name,
      :disabled_reason,
      :disabled_at,
      :warning,
      :warning_delivery_attempts,
      :warning_last_sent_at
    ])
    |> changeset()
  end

  defp changeset(changeset) do
    changeset
    |> validate_name()
    |> validate_legal_name()
    |> validate_slug()
    |> prepare_changes(&put_default_slug/1)
    |> cast_embed(:config, with: &Config.Changeset.changeset/2)
    |> cast_embed(:features, with: &Features.Changeset.changeset/2)
    |> cast_embed(:limits, with: &Limits.Changeset.changeset/2)
    |> cast_embed(:metadata, with: &metadata_changeset/2)
  end

  defp validate_name(changeset) do
    changeset
    |> validate_required([:name])
    |> trim_change(:name)
    |> validate_length(:name, min: 3, max: 64)
  end

  defp validate_legal_name(changeset) do
    changeset
    |> put_default_value(:legal_name, from: :name)
    |> trim_change(:legal_name)
    |> validate_length(:legal_name, min: 1, max: 255)
  end

  defp validate_slug(changeset) do
    changeset
    |> validate_length(:slug, min: 3, max: 100)
    |> update_change(:slug, &String.downcase/1)
    |> validate_format(:slug, @slug_regex,
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

  def metadata_changeset(metadata \\ %Account.Metadata{}, attrs) do
    metadata
    |> cast(attrs, [])
    |> cast_embed(:stripe, with: &stripe_metadata_changeset/2)
  end

  def stripe_metadata_changeset(stripe \\ %Account.Metadata.Stripe{}, attrs) do
    stripe
    |> cast(attrs, [
      :customer_id,
      :subscription_id,
      :product_name,
      :billing_email,
      :trial_ends_at,
      :support_type
    ])
  end

  def validate_account_id_or_slug(account_id_or_slug) do
    cond do
      valid_uuid?(account_id_or_slug) ->
        {:ok, String.downcase(account_id_or_slug)}

      String.match?(account_id_or_slug, @slug_regex) ->
        {:ok, String.downcase(account_id_or_slug)}

      true ->
        {:error, "Account ID or Slug contains invalid characters"}
    end
  end

  defp put_default_config(changeset) do
    case get_change(changeset, :config) do
      nil ->
        put_change(changeset, :config, Config.default_config())

      %Ecto.Changeset{} = config_changeset ->
        config = Ecto.Changeset.apply_changes(config_changeset)
        updated_config = Config.ensure_defaults(config)
        put_change(changeset, :config, updated_config)

      %Config{} = config ->
        updated_config = Config.ensure_defaults(config)
        put_change(changeset, :config, updated_config)

      _ ->
        changeset
    end
  end
end

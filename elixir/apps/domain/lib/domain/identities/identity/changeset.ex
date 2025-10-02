defmodule Domain.Identities.Identity.Changeset do
  use Domain, :changeset

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, [
      :account_id,
      :actor_id,
      :directory_id,
      :email,
      :provider_identifier,
      :last_seen_user_agent,
      :last_seen_remote_ip,
      :last_seen_remote_ip_location_region,
      :last_seen_remote_ip_location_city,
      :last_seen_remote_ip_location_lat,
      :last_seen_remote_ip_location_lon,
      :last_seen_at
    ])
    |> validate_required([:account_id, :directory_id, :provider_identifier, :actor_id])
    |> unique_constraint(:provider_identifier,
      name: :auth_identities_account_id_directory_id_provider_identifier_ind
    )
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:directory_id)
    |> foreign_key_constraint(:actor_id)
    |> put_subject_trail(:created_by, :system)
  end
end

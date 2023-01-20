defmodule FzHttp.Repo.Migrations.AddNotNullToMfaMethods do
  use Ecto.Migration

  def change do
    execute("""
    UPDATE mfa_methods
    SET last_used_at = '1970-01-01 00:00:00+00'::timestamptz
    WHERE last_used_at IS NULL
    """)

    # Installations that have empty payload fields (which means MFA doesn't work for them)
    # will be unable to decrypt it and will get an error:
    #
    #   ** (ArgumentError) cannot load `"..."`as type FzHttp.Encrypted.Map
    #   for field :payload in %FzHttp.MFA.Method{...}
    execute("""
    UPDATE mfa_methods
    SET payload = '#{Base.encode64(:crypto.strong_rand_bytes(32))}'
    WHERE payload IS NULL
    """)

    alter table("mfa_methods") do
      remove(:credential_id, :string)
      modify(:payload, :bytea, null: false)
      modify(:last_used_at, :utc_datetime_usec, null: false)
    end

    create(index(:mfa_methods, [:name], unique: true))
  end
end

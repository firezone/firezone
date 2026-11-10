defmodule Portal.Repo.Migrations.CreateMxDomains do
  use Ecto.Migration

  # Mail server domains rated by operators. A sign-up whose mail servers fall
  # under a bad domain gets no verification email.
  def change do
    create table(:mx_domains, primary_key: false) do
      add(:domain, :text, primary_key: true, null: false)
      add(:rating, :text, null: false)
      add(:note, :text)

      timestamps()
    end

    create(constraint(:mx_domains, :mx_domains_rating, check: "rating IN ('good', 'bad')"))
    create(constraint(:mx_domains, :mx_domains_domain_lowercase, check: "domain = lower(domain)"))

    create(
      constraint(:mx_domains, :mx_domains_bad_note,
        check: "rating <> 'bad' OR (note IS NOT NULL AND btrim(note) <> '')"
      )
    )
  end
end

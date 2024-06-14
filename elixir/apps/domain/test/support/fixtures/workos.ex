defmodule Domain.Fixtures.WorkOS do
  use Domain.Fixture

  def random_workos_id(id_type) do
    chars = Range.to_list(?A..?Z) ++ Range.to_list(?0..?9)
    random_str = for _ <- 1..26, into: "", do: <<Enum.random(chars)>>

    case id_type do
      :org -> "org_#{random_str}"
      :directory -> "directory_#{random_str}"
    end
  end

  def random_external_key() do
    chars = Range.to_list(?A..?Z) ++ Range.to_list(?a..?z) ++ Range.to_list(?0..?9)
    for _ <- 1..16, into: "", do: <<Enum.random(chars)>>
  end

  def org_attrs(attrs \\ %{}) do
    default_org = %{
      id: random_workos_id(:org),
      name: Ecto.UUID.generate(),
      object: "organization",
      domains: [],
      created_at: DateTime.utc_now() |> DateTime.add(-1, :day),
      updated_at: DateTime.utc_now() |> DateTime.add(-1, :day),
      allow_profiles_outside_organization: false
    }

    Map.merge(default_org, attrs)
  end

  def directory_attrs(attrs \\ %{}) do
    default_directory = %{
      id: random_workos_id(:directory),
      object: "directory",
      external_key: random_external_key(),
      state: "linked",
      created_at: DateTime.utc_now() |> DateTime.add(-1, :day),
      updated_at: DateTime.utc_now() |> DateTime.add(-1, :day),
      name: Ecto.UUID.generate(),
      domain: nil,
      organization_id: random_workos_id(:org),
      type: "jump cloud scim v2.0"
    }

    Map.merge(default_directory, attrs)
  end

  def create_org(attrs \\ %{}) do
    struct(WorkOS.Organizations.Organization, attrs)
  end

  def create_directory(attrs \\ %{}) do
    struct(WorkOS.DirectorySync.Directory, attrs)
  end
end

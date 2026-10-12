defmodule Portal.SignUpSurvey do
  use Ecto.Schema
  import Ecto.Changeset
  import Portal.Changeset

  @referral_sources ~w[search github reddit hacker_news word_of_mouth blog social_media event other]
  @motivations ~w[performance access_controls simplicity security open_source cost other]
  @use_cases ~w[personal servers internal_apps employees contractors other]
  @roles ~w[it security devops software_engineer network_engineer founder consultant other]
  @previous_solutions ~w[tailscale twingate cloudflare openvpn wireguard zerotier cisco zscaler other]
  @other_max_length 255

  @primary_key false
  embedded_schema do
    field :referral_source, :string
    field :referral_source_other, :string
    field :motivation, :string
    field :motivation_other, :string
    field :use_case, :string
    field :use_case_other, :string
    field :role, :string
    field :role_other, :string
    field :switching, :boolean
    field :previous_solution, :string
    field :previous_solution_other, :string
  end

  def other_max_length, do: @other_max_length

  def changeset(survey \\ %__MODULE__{}, attrs) do
    survey
    |> cast(attrs, [
      :referral_source,
      :referral_source_other,
      :motivation,
      :motivation_other,
      :use_case,
      :use_case_other,
      :role,
      :role_other,
      :switching,
      :previous_solution,
      :previous_solution_other
    ])
    |> validate_required([:referral_source, :motivation, :use_case, :role, :switching])
    |> validate_inclusion(:referral_source, @referral_sources)
    |> validate_inclusion(:motivation, @motivations)
    |> validate_inclusion(:use_case, @use_cases)
    |> validate_inclusion(:role, @roles)
    |> validate_previous_solution()
    |> validate_other(:referral_source, :referral_source_other)
    |> validate_other(:motivation, :motivation_other)
    |> validate_other(:use_case, :use_case_other)
    |> validate_other(:role, :role_other)
    |> validate_other(:previous_solution, :previous_solution_other)
  end

  defp validate_previous_solution(changeset) do
    if get_field(changeset, :switching) do
      changeset
      |> validate_required([:previous_solution])
      |> validate_inclusion(:previous_solution, @previous_solutions)
    else
      changeset
      |> put_change(:previous_solution, nil)
      |> put_change(:previous_solution_other, nil)
    end
  end

  defp validate_other(changeset, field, other_field) do
    if get_field(changeset, field) == "other" do
      changeset
      |> trim_change(other_field)
      |> validate_required([other_field])
      |> validate_length(other_field, max: @other_max_length, message: "too long")
    else
      put_change(changeset, other_field, nil)
    end
  end
end

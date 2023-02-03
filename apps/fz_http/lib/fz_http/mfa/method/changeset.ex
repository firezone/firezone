defmodule FzHttp.MFA.Method.Changeset do
  use FzHttp, :changeset
  alias FzHttp.MFA.Method

  @create_fields [:name, :type, :payload, :code]

  def create_changeset(user_id, attrs) do
    %Method{user_id: user_id}
    |> cast(attrs, @create_fields)
    |> validate_required(@create_fields)
    |> validate_length(:name, min: 1, max: 255)
    |> trim_change(:name)
    |> unique_constraint(:name, name: :mfa_methods_user_id_name_index)
    |> unsafe_validate_unique([:name, :user_id], FzHttp.Repo)
    |> assoc_constraint(:user)
    |> changeset()
  end

  def use_code_changeset(%Method{} = method, attrs) do
    method
    |> cast(attrs, [:code])
    |> validate_required([:code])
    |> changeset()
  end

  defp changeset(changeset) do
    changeset
    |> use_code()
    |> redact_field(:code)
  end

  defp use_code(changeset) do
    if changed?(changeset, :code) and not has_errors?(changeset, :code) do
      validate_code(changeset)
    else
      changeset
    end
  end

  def validate_code(changeset) do
    with {_data_or_changes, %{"secret" => encoded_secret}} <- fetch_field(changeset, :payload),
         {:ok, secret} <- Base.decode64(encoded_secret),
         # Notice: last_used_at will be nil when creating a new method,
         # but NimbleTOTP.valid?/3 accepts that
         {_data_or_changes, last_used_at} <- fetch_field(changeset, :last_used_at),
         {:ok, code} <- fetch_change(changeset, :code),
         true <- NimbleTOTP.valid?(secret, code, since: last_used_at) do
      put_change(changeset, :last_used_at, DateTime.utc_now())
    else
      {:data, nil} ->
        changeset

      {:data, %{}} ->
        add_error(changeset, :payload, "is invalid")

      {:changes, %{}} ->
        changeset
        |> add_error(:payload, "is invalid")
        |> add_error(:code, "can not be verified")

      :error ->
        add_error(changeset, :code, "can not be verified")

      false ->
        add_error(changeset, :code, "is invalid")
    end
  end
end

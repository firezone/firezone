defmodule Domain.ChangeLogs.ChangeLog.Changeset do
  use Domain, :changeset

  @fields ~w[account_id lsn table op old_data data vsn]a

  def changeset(attrs) do
    %Domain.ChangeLogs.ChangeLog{}
    |> cast(attrs, @fields)
    |> validate_inclusion(:op, [:insert, :update, :delete])
    |> validate_correct_data_present()
    |> validate_same_account()
    |> put_account_id()
    |> validate_required([:account_id, :lsn, :table, :op, :vsn])
    |> unique_constraint(:lsn)
    |> foreign_key_constraint(:account_id, name: :change_logs_account_id_fkey)
  end

  # :insert requires old_data = nil and data != nil
  # :update requires old_data != nil and data != nil
  # :delete requires old_data != nil and data = nil
  def validate_correct_data_present(changeset) do
    op = get_field(changeset, :op)
    old_data = get_field(changeset, :old_data)
    data = get_field(changeset, :data)

    case {op, old_data, data} do
      {:insert, nil, %{} = _data} ->
        changeset

      {:update, %{} = _old_data, %{} = _data} ->
        changeset

      {:delete, %{} = _old_data, nil} ->
        changeset

      _ ->
        add_error(changeset, :base, "Invalid combination of operation and data")
    end
  end

  # Add an error if data["account_id"] != old_data["account_id"]
  defp validate_same_account(changeset) do
    old_data = get_field(changeset, :old_data)
    data = get_field(changeset, :data)

    account_id_key = account_id_field(changeset)

    if old_data && data && old_data[account_id_key] != data[account_id_key] do
      add_error(changeset, :base, "Account ID cannot be changed")
    else
      changeset
    end
  end

  # Populate account_id from one of data, old_data
  defp put_account_id(changeset) do
    old_data = get_field(changeset, :old_data)
    data = get_field(changeset, :data)

    account_id_key = account_id_field(changeset)

    account_id =
      case {old_data, data} do
        {nil, nil} -> nil
        {_, %{^account_id_key => id}} -> id
        {%{^account_id_key => id}, _} -> id
        _ -> nil
      end

    put_change(changeset, :account_id, account_id)
  end

  # For accounts table updates, the account_id is in the "id" field
  # For other tables, it is in the "account_id" field
  defp account_id_field(changeset) do
    case get_field(changeset, :table) do
      "accounts" -> "id"
      _ -> "account_id"
    end
  end
end

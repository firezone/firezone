defmodule PortalWeb.StoredSecret do
  @moduledoc """
  Changeset helpers for edit forms that hold a stored secret.

  A redacted field is never rendered back to the browser, so its input starts
  empty on an edit and an empty submission keeps the stored value. The stored
  value is only ever sent to the destination it was saved for, so changing
  the destination resets it and the usual required check asks for it again.
  """

  import Ecto.Changeset

  @doc "An empty input keeps the stored value."
  @spec keep_when_blank(Ecto.Changeset.t(), [atom()]) :: Ecto.Changeset.t()
  def keep_when_blank(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, changeset ->
      case fetch_change(changeset, field) do
        {:ok, nil} -> delete_change(changeset, field)
        _other -> changeset
      end
    end)
  end

  @doc """
  Forgets the stored secret when any of `destinations` changed and the secret
  was not typed in this submission.

  Call it after the schema changeset: `validate_required/3` drops a nil change,
  which would put the stored value back, so the required error is added here.
  """
  @spec reset_on_change(Ecto.Changeset.t(), atom(), [atom()]) :: Ecto.Changeset.t()
  def reset_on_change(changeset, secret, destinations) do
    if Enum.any?(destinations, &changed?(changeset, &1)) and not submitted?(changeset, secret) do
      changeset = put_change(changeset, secret, nil)

      if secret in changeset.required do
        add_error(changeset, secret, "can't be blank", validation: :required)
      else
        changeset
      end
    else
      changeset
    end
  end

  @doc "Whether the form still holds a value for `field`, stored or typed."
  @spec present?(Phoenix.HTML.Form.t(), atom()) :: boolean()
  def present?(%Phoenix.HTML.Form{source: %Ecto.Changeset{} = changeset}, field),
    do: not is_nil(get_field(changeset, field))

  # Typing the stored value again leaves no change, so the submission is
  # what shows it was entered.
  defp submitted?(%Ecto.Changeset{params: %{} = params}, field) do
    case Map.get(params, Atom.to_string(field)) do
      value when is_binary(value) -> String.trim(value) != ""
      _other -> false
    end
  end

  defp submitted?(_changeset, _field), do: false
end

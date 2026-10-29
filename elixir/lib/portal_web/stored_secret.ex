defmodule PortalWeb.StoredSecret do
  @moduledoc """
  Changeset helpers for edit forms that hold a third-party secret.

  A stored secret is never rendered back to the browser, so its input starts
  empty on an edit and leaving it empty keeps the stored value. That alone
  would let anyone holding an admin session point the stored secret at a
  server they control by changing only the destination, so a changed
  destination requires the secret to be typed again.
  """

  use Phoenix.Component

  import Ecto.Changeset

  alias PortalWeb.Components.Core

  @doc """
  Drops the change an empty input makes to a stored secret, so the stored
  value stays. A record without a stored value gets no change either way and
  still fails its required check.
  """
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
  Adds `message` as an error on `secret` when any of `destinations` differs
  from `stored` while the secret is still the stored one and was not typed
  into this submission.

  `stored` is the record as it is in the database, not the changeset's data,
  which some forms replace with applied changes mid-edit.
  """
  @spec require_on_destination_change(Ecto.Changeset.t(), struct() | nil, atom(), [atom()], String.t()) ::
          Ecto.Changeset.t()
  def require_on_destination_change(changeset, nil, _secret, _destinations, _message), do: changeset

  def require_on_destination_change(changeset, stored, secret, destinations, message) do
    stored_secret = Map.get(stored, secret)

    if present?(stored_secret) and
         get_field(changeset, secret) == stored_secret and
         not typed?(changeset, secret) and
         Enum.any?(destinations, &(get_field(changeset, &1) != Map.get(stored, &1))) do
      add_error(changeset, secret, message, validation: :reentry_required)
    else
      changeset
    end
  end

  @doc """
  Whether `form` holds a stored secret that must be typed again because its
  destination changed.
  """
  @spec reentry_required?(Phoenix.HTML.Form.t(), atom()) :: boolean()
  def reentry_required?(%Phoenix.HTML.Form{source: %Ecto.Changeset{errors: errors}}, secret) do
    Enum.any?(errors, fn {field, {_message, opts}} ->
      field == secret and opts[:validation] == :reentry_required
    end)
  end

  def reentry_required?(_form, _secret), do: false

  @doc """
  Shows the re-entry error while the secret's input is untouched.

  Changing the destination is what makes the secret required, but the input
  hides its errors until it is used, so it would show nothing. Once the input
  is used it shows the error itself, so this renders nothing then.
  """
  attr :field, Phoenix.HTML.FormField, required: true

  def reentry_error(assigns) do
    ~H"""
    <Core.error
      :for={{message, _opts} <- untouched_reentry_errors(@field)}
      data-validation-error-for={@field.name}
    >
      {message}
    </Core.error>
    """
  end

  defp untouched_reentry_errors(%Phoenix.HTML.FormField{form: form, field: secret} = field) do
    if reentry_required?(form, secret) and not used_input?(field),
      do: Keyword.get_values(form.source.errors, secret),
      else: []
  end

  @doc """
  Whether `record` has a value stored for `secret`.
  """
  @spec stored?(struct() | nil, atom()) :: boolean()
  def stored?(nil, _secret), do: false
  def stored?(record, secret), do: present?(Map.get(record, secret))

  # Typing the stored value again leaves no change, since it matches the
  # data, so the submitted params are what show it was entered.
  defp typed?(%Ecto.Changeset{params: %{} = params}, field),
    do: present?(Map.get(params, Atom.to_string(field)))

  defp typed?(_changeset, _field), do: false

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
end

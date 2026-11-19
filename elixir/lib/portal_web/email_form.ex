defmodule PortalWeb.EmailForm do
  @moduledoc """
  The email address entered on the public sign-in and sign-up pages, before anything
  else is known.

  When `:sign_up_whitelisted_domains` is set, only those email domains are accepted.
  """
  use Ecto.Schema
  @primary_key false

  import Ecto.Changeset
  import Portal.Changeset

  @domain_error "this email domain is not allowed at this time"

  embedded_schema do
    field(:email, :string)
  end

  @spec changeset(map()) :: Ecto.Changeset.t()
  def changeset(attrs \\ %{}) do
    %__MODULE__{}
    |> cast(attrs, [:email])
    |> validate_required([:email])
    |> trim_change(:email)
    |> validate_email(:email)
    |> validate_email_allowed(:email)
  end

  @doc "Rejects an email whose domain isn't in `:sign_up_whitelisted_domains`, when that is set."
  @spec validate_email_allowed(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate_email_allowed(changeset, field) do
    case Portal.Config.get_env(:portal, :sign_up_whitelisted_domains) do
      domains when domains in [nil, []] ->
        changeset

      whitelisted_domains ->
        validate_change(changeset, field, &domain_errors(&1, &2, whitelisted_domains))
    end
  end

  defp domain_errors(field, email, whitelisted_domains) do
    if email_allowed?(email, whitelisted_domains), do: [], else: [{field, @domain_error}]
  end

  defp email_allowed?(email, whitelisted_domains) do
    case String.split(email, "@", parts: 2) do
      [_, domain] -> Enum.member?(whitelisted_domains, domain)
      _ -> false
    end
  end
end

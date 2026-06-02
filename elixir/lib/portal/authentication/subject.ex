defmodule Portal.Authentication.Subject do
  alias Portal.Authentication.Context
  alias Portal.Authentication.Credential

  @type actor :: %Portal.Actor{}

  @type t :: %__MODULE__{
          actor: actor(),
          account: %Portal.Account{},
          credential: Credential.t(),
          expires_at: DateTime.t(),
          context: Context.t()
        }

  @enforce_keys [:actor, :account, :credential, :expires_at, :context]
  defstruct actor: nil,
            account: nil,
            credential: nil,
            expires_at: nil,
            context: nil

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = subject) do
    %{
      actor_id: subject.actor.id,
      actor_name: subject.actor.name,
      actor_email: subject.actor.email,
      actor_type: to_string(subject.actor.type),
      auth_provider_id: subject.credential.auth_provider_id,
      ip: format_ip(subject.context.remote_ip),
      ip_region: subject.context.remote_ip_location_region,
      ip_city: subject.context.remote_ip_location_city,
      ip_lat: subject.context.remote_ip_location_lat,
      ip_lon: subject.context.remote_ip_location_lon,
      user_agent: subject.context.user_agent
    }
  end

  defp format_ip(nil), do: nil
  defp format_ip(ip), do: to_string(:inet.ntoa(ip))
end

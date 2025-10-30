defmodule Web.OIDC.Verification do
  @type t :: %__MODULE__{
          url: String.t(),
          verifier: String.t(),
          token: String.t(),
          config: map()
        }

  defstruct [:url, :verifier, :token, :config]
end

defimpl String.Chars, for: Web.OIDC.Verification do
  def to_string(%Web.OIDC.Verification{token: token}) do
    token
  end
end

defimpl Phoenix.Param, for: Web.OIDC.Verification do
  def to_param(%Web.OIDC.Verification{token: token}) do
    token
  end
end

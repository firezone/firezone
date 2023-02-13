defmodule FzHttp.SAMLIdentityProviderFixtures do
  # TODO: This module should be removed in favor of ConfigFixtures

  @metadata """
  <?xml version="1.0"?>
  <md:EntityDescriptor xmlns="urn:oasis:names:tc:SAML:2.0:metadata" xmlns:md="urn:oasis:names:tc:SAML:2.0:metadata" xmlns:saml="urn:oasis:names:tc:SAML:2.0:assertion" xmlns:ds="http://www.w3.org/2000/09/xmldsig#" entityID="http://localhost:8080/realms/firezone">
    <md:IDPSSODescriptor WantAuthnRequestsSigned="true" protocolSupportEnumeration="urn:oasis:names:tc:SAML:2.0:protocol">
      <md:KeyDescriptor use="signing">
        <ds:KeyInfo>
          <ds:KeyName>pdSMtx2s3RVVhxg_qJOjHhlZhwZk6JiBMiSm5PEgjkA</ds:KeyName>
          <ds:X509Data>
            <ds:X509Certificate>MIICnzCCAYcCBgGD18ZU8TANBgkqhkiG9w0BAQsFADATMREwDwYDVQQDDAhmaXJlem9uZTAeFw0yMjEwMTQxODMyMjJaFw0zMjEwMTQxODM0MDJaMBMxETAPBgNVBAMMCGZpcmV6b25lMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAur5Cb0jrDJbMwr96WWE+z9CjDg0A/uRkaB4loRqkmu3A2fQGsS6CP7F7lQWMJmpzvBgkNtB69toO2sgx1u1fhpIJBZ0uSHF5gnzQAivgVxInvkMKRTRSkpMbhObiDHZnEGI2+Ly+8iV8IvprdrbDgm52u4conam0H1PewUKkHulrVQ+ImFuEWAjKCRSqpUG2F1eRkA0YpqB09x0CZAOOoucwTsBYj/ZAz3dUXhYIENAF7v0ykvzGOCAyOZIn1uYQc7jvWpwoI8qQdL45phj2FLoFlght3tlZV8IG5hsXrE6rg7Ufqvv8xyGltrOMKj/jEFEunagZOUjkypDp36b8cwIDAQABMA0GCSqGSIb3DQEBCwUAA4IBAQBEZKLLr66GB3NxqXGTMl0PvTDNB9GdyShQHaJYjeeUQnEXixjlAVrOq/txEBKjhGUcqyFELoNuwcxxV1iHA5oXhCoqYmnp9T/ftmXPDT3c49PBABHgLJaFOKYTpVx1YjP7mA44X1ijLZmgboIeeFNerVNHIzR9BsxcloQlB0r9QfC14rsuXo6QD3QnaVI8wDgWXQHqpcwLFqvehXdNvMFniRvX2qBNU8E0FPoMaZ1C3n2nssLcVZ+C4ghq6YoAG+wLGY7XE8+v5rnYGDpGpfgr2wdefn6tryFq3PyGqA8ThjARESRRQG9kI/RlNX7qCnP/8/7JQ4wLdfz5C25uhakP</ds:X509Certificate>
          </ds:X509Data>
        </ds:KeyInfo>
      </md:KeyDescriptor>
      <md:ArtifactResolutionService Binding="urn:oasis:names:tc:SAML:2.0:bindings:SOAP" Location="http://localhost:8080/realms/firezone/protocol/saml/resolve" index="0"/>
      <md:SingleLogoutService Binding="urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST" Location="http://localhost:8080/realms/firezone/protocol/saml"/>
      <md:SingleLogoutService Binding="urn:oasis:names:tc:SAML:2.0:bindings:HTTP-Redirect" Location="http://localhost:8080/realms/firezone/protocol/saml"/>
      <md:SingleLogoutService Binding="urn:oasis:names:tc:SAML:2.0:bindings:HTTP-Artifact" Location="http://localhost:8080/realms/firezone/protocol/saml"/>
      <md:NameIDFormat>urn:oasis:names:tc:SAML:2.0:nameid-format:persistent</md:NameIDFormat>
      <md:NameIDFormat>urn:oasis:names:tc:SAML:2.0:nameid-format:transient</md:NameIDFormat>
      <md:NameIDFormat>urn:oasis:names:tc:SAML:1.1:nameid-format:unspecified</md:NameIDFormat>
      <md:NameIDFormat>urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress</md:NameIDFormat>
      <md:SingleSignOnService Binding="urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST" Location="http://localhost:8080/realms/firezone/protocol/saml"/>
      <md:SingleSignOnService Binding="urn:oasis:names:tc:SAML:2.0:bindings:HTTP-Redirect" Location="http://localhost:8080/realms/firezone/protocol/saml"/>
      <md:SingleSignOnService Binding="urn:oasis:names:tc:SAML:2.0:bindings:SOAP" Location="http://localhost:8080/realms/firezone/protocol/saml"/>
      <md:SingleSignOnService Binding="urn:oasis:names:tc:SAML:2.0:bindings:HTTP-Artifact" Location="http://localhost:8080/realms/firezone/protocol/saml"/>
    </md:IDPSSODescriptor>
  </md:EntityDescriptor>
  """
  def metadata, do: @metadata

  def saml_attrs do
    %{
      "metadata" => @metadata,
      "label" => "test",
      "id" => "test",
      "auto_create_users" => true
    }
  end
end

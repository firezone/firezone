"use client";
import {
  Sidebar,
  SidebarItem,
  SidebarItems,
  SidebarItemGroup,
  SidebarCollapse,
} from "@/components/Sidebar";
import KbSearch from "@/components/KbSearch";

export default function DocsSidebar() {
  return (
    <Sidebar>
      <SidebarItems>
        <SidebarItemGroup>
          <SidebarItem>
            <KbSearch excludePathRegex={new RegExp(/^\/kb/)} />
          </SidebarItem>
          <SidebarItem href="/docs">Overview</SidebarItem>
          <SidebarCollapse prefix="/docs/deploy" label="Deploy">
            <SidebarItem href="/docs/deploy">Overview</SidebarItem>
            <SidebarItem href="/docs/deploy/docker">Docker</SidebarItem>
            <SidebarItem href="/docs/deploy/docker/supported-platforms">
              Supported Platforms
            </SidebarItem>
            <SidebarItem href="/docs/deploy/omnibus">Omnibus</SidebarItem>
            <SidebarItem href="/docs/deploy/omnibus/supported-platforms">
              Supported Platforms
            </SidebarItem>
            <SidebarItem href="/docs/deploy/configure">Configure</SidebarItem>
            <SidebarItem href="/docs/deploy/security-considerations">
              Security Considerations
            </SidebarItem>
            <SidebarItem href="/docs/deploy/advanced/build-from-source">
              Advanced: Build from Source
            </SidebarItem>
            <SidebarItem href="/docs/deploy/advanced/external-database">
              Advanced: External Database
            </SidebarItem>
            <SidebarItem href="/docs/deploy/advanced/reverse-proxy">
              Advanced: Custom Reverse Proxy
            </SidebarItem>
          </SidebarCollapse>
          <SidebarCollapse prefix="/docs/authenticate" label="Authenticate">
            <SidebarItem href="/docs/authenticate">Overview</SidebarItem>
            <SidebarItem href="/docs/authenticate/local-auth">
              Local Auth
            </SidebarItem>
            <SidebarItem href="/docs/authenticate/multi-factor">
              Multi-Factor Auth
            </SidebarItem>
            <SidebarItem href="/docs/authenticate/oidc">
              OIDC Overview
            </SidebarItem>
            <SidebarItem href="/docs/authenticate/oidc/auth0">
              OIDC: Auth0
            </SidebarItem>
            <SidebarItem href="/docs/authenticate/oidc/azuread">
              OIDC: Azure AD
            </SidebarItem>
            <SidebarItem href="/docs/authenticate/oidc/google">
              OIDC: Google Workspace
            </SidebarItem>
            <SidebarItem href="/docs/authenticate/oidc/keycloak">
              OIDC: Keycloak
            </SidebarItem>
            <SidebarItem href="/docs/authenticate/oidc/okta">
              OIDC: Okta
            </SidebarItem>
            <SidebarItem href="/docs/authenticate/oidc/onelogin">
              OIDC: Onelogin
            </SidebarItem>
            <SidebarItem href="/docs/authenticate/oidc/zitadel">
              OIDC: Zitadel
            </SidebarItem>
            <SidebarItem href="/docs/authenticate/saml">SAML</SidebarItem>
            <SidebarItem href="/docs/authenticate/saml/google">
              SAML: Google
            </SidebarItem>
            <SidebarItem href="/docs/authenticate/saml/okta">
              SAML: Okta
            </SidebarItem>
            <SidebarItem href="/docs/authenticate/saml/onelogin">
              SAML: Onelogin
            </SidebarItem>
            <SidebarItem href="/docs/authenticate/saml/jumpcloud">
              SAML: Jumpcloud
            </SidebarItem>
          </SidebarCollapse>
          <SidebarCollapse prefix="/docs/administer" label="Administer">
            <SidebarItem href="/docs/administer">Overview</SidebarItem>
            <SidebarItem href="/docs/administer/migrate">
              Migrate to Docker
            </SidebarItem>
            <SidebarItem href="/docs/administer/upgrade">Upgrade</SidebarItem>
            <SidebarItem href="/docs/administer/backup">Backup</SidebarItem>
            <SidebarItem href="/docs/administer/uninstall">
              Uninstall
            </SidebarItem>
            <SidebarItem href="/docs/administer/troubleshoot">
              Troubleshoot
            </SidebarItem>
            <SidebarItem href="/docs/administer/regen-keys">
              Regenerate Secret Keys
            </SidebarItem>
            <SidebarItem href="/docs/administer/debug-logs">
              Debug Logs
            </SidebarItem>
          </SidebarCollapse>
          <SidebarCollapse prefix="/docs/user-guides" label="User Guides">
            <SidebarItem href="/docs/user-guides">Overview</SidebarItem>
            <SidebarItem href="/docs/user-guides/add-users">
              Add Users
            </SidebarItem>
            <SidebarItem href="/docs/user-guides/add-devices">
              Add Devices
            </SidebarItem>
            <SidebarItem href="/docs/user-guides/egress-rules">
              Egress Rules
            </SidebarItem>
            <SidebarItem href="/docs/user-guides/client-instructions">
              Client Instructions
            </SidebarItem>
            <SidebarItem href="/docs/user-guides/use-cases">
              Use Cases
            </SidebarItem>
            <SidebarItem href="/docs/user-guides/use-cases/split-tunnel">
              Use Cases: Split Tunnel
            </SidebarItem>
            <SidebarItem href="/docs/user-guides/use-cases/reverse-tunnel">
              Use Cases: Reverse Tunnel
            </SidebarItem>
            <SidebarItem href="/docs/user-guides/use-cases/nat-gateway">
              Use Cases: NAT Gateway
            </SidebarItem>
          </SidebarCollapse>
          <SidebarCollapse prefix="/docs/reference" label="Reference">
            <SidebarItem href="/docs/reference/env-vars">
              Environment Variables
            </SidebarItem>
            <SidebarItem href="/docs/reference/configuration-file">
              Configuration File
            </SidebarItem>
            <SidebarItem href="/docs/reference/file-and-directory-locations">
              File and Directory Locations
            </SidebarItem>
            <SidebarItem href="/docs/reference/telemetry">
              Telemetry
            </SidebarItem>
            <SidebarItem href="/docs/reference/reverse-proxy-templates/apache">
              Reverse Proxy Templates: Apache
            </SidebarItem>
            <SidebarItem href="/docs/reference/reverse-proxy-templates/traefik">
              Reverse Proxy Templates: Traefik
            </SidebarItem>
            <SidebarItem href="/docs/reference/reverse-proxy-templates/haproxy">
              Reverse Proxy Templates: HAProxy
            </SidebarItem>
            <SidebarItem href="/docs/reference/firewall-templates/nftables">
              Firewall Templates: nftables
            </SidebarItem>
            <SidebarItem href="/docs/reference/rest-api">REST API</SidebarItem>
            <SidebarItem href="/docs/reference/rest-api/users">
              REST API: Users
            </SidebarItem>
            <SidebarItem href="/docs/reference/rest-api/configurations">
              REST API: Configurations
            </SidebarItem>
            <SidebarItem href="/docs/reference/rest-api/devices">
              REST API: Devices
            </SidebarItem>
            <SidebarItem href="/docs/reference/rest-api/rules">
              REST API: Rules
            </SidebarItem>
            <SidebarItem href="/docs/reference/security-controls">
              Security Controls
            </SidebarItem>
          </SidebarCollapse>
        </SidebarItemGroup>
      </SidebarItems>
    </Sidebar>
  );
}

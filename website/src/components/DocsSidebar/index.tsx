"use client";
import type { CustomFlowbiteTheme } from "flowbite-react";
import { Flowbite } from "flowbite-react";
import { Sidebar } from "flowbite-react";
import { usePathname } from "next/navigation";

// Overrides the default spacing to condense things a bit.
// See https://github.com/themesberg/flowbite-react/blob/main/src/theme.ts
const theme: CustomFlowbiteTheme = {
  sidebar: {
    root: {
      base: "fixed top-0 left-0 z-40 w-64 h-screen pt-14 transition-transform -translate-x-full bg-white border-r border-gray-200 md:translate-x-0 dark:bg-gray-800 dark:border-gray-700",
    },
    item: {
      base: "flex items-center justify-center rounded-lg p-0 text-base font-normal text-gray-900 hover:bg-gray-100 dark:text-white dark:hover:bg-gray-700",
      collapsed: {
        insideCollapse: "group w-full pl-3 transition duration-75",
      },
    },
    collapse: {
      button:
        "group flex w-full items-center rounded-lg p-0 text-base font-normal text-gray-900 transition duration-75 hover:bg-gray-100 dark:text-white dark:hover:bg-gray-700",
      label: {
        base: "ml-3 flex-1 whitespace-nowrap text-left",
      },
      list: "space-y-1 py-1",
    },
  },
};

export default function DocsSidebar() {
  const p = usePathname();

  return (
    <Flowbite theme={{ theme: theme }}>
      <Sidebar aria-label="Docs Sidebar">
        <Sidebar.Items>
          <Sidebar.ItemGroup>
            <Sidebar.Item href="/docs" active={p == "/docs"}>
              Overview
            </Sidebar.Item>
            <Sidebar.Collapse
              label="Deploy"
              open={p.startsWith("/docs/deploy")}
            >
              <Sidebar.Item href="/docs/deploy" active={p == "/docs/deploy"}>
                Overview
              </Sidebar.Item>
              <Sidebar.Collapse
                label="Docker"
                open={p.startsWith("/docs/deploy/docker")}
              >
                <Sidebar.Item
                  href="/docs/deploy/docker"
                  active={p == "/docs/deploy/docker"}
                >
                  Overview
                </Sidebar.Item>
                <Sidebar.Item
                  href="/docs/deploy/docker/supported-platforms"
                  active={p == "/docs/deploy/docker/supported-platforms"}
                >
                  Supported Platforms
                </Sidebar.Item>
              </Sidebar.Collapse>
              <Sidebar.Collapse
                label="Omnibus"
                open={p.startsWith("/docs/deploy/omnibus")}
              >
                <Sidebar.Item
                  href="/docs/deploy/omnibus"
                  active={p == "/docs/deploy/omnibus"}
                >
                  Overview
                </Sidebar.Item>
                <Sidebar.Item
                  href="/docs/deploy/omnibus/supported-platforms"
                  active={p == "/docs/deploy/omnibus/supported-platforms"}
                >
                  Supported Platforms
                </Sidebar.Item>
              </Sidebar.Collapse>
              <Sidebar.Item
                href="/docs/deploy/configure"
                active={p == "/docs/deploy/configure"}
              >
                Configure
              </Sidebar.Item>
              <Sidebar.Item
                href="/docs/deploy/security-considerations"
                active={p == "/docs/deploy/security-considerations"}
              >
                Security Considerations
              </Sidebar.Item>
              <Sidebar.Collapse
                label="Advanced"
                open={p.startsWith("/docs/deploy/advanced")}
              >
                <Sidebar.Item
                  href="/docs/deploy/advanced/build-from-source"
                  active={p == "/docs/deploy/advanced/build-from-source"}
                >
                  Build from Source
                </Sidebar.Item>
                <Sidebar.Item
                  href="/docs/deploy/advanced/external-database"
                  active={p == "/docs/deploy/advanced/external-database"}
                >
                  Custom External Database
                </Sidebar.Item>
                <Sidebar.Item
                  href="/docs/deploy/advanced/reverse-proxy"
                  active={p == "/docs/deploy/advanced/reverse-proxy"}
                >
                  Custom Reverse Proxy
                </Sidebar.Item>
              </Sidebar.Collapse>
            </Sidebar.Collapse>
            <Sidebar.Collapse
              label="Authenticate"
              open={p.startsWith("/docs/authenticate")}
            >
              <Sidebar.Item
                href="/docs/authenticate"
                active={p == "/docs/authenticate"}
              >
                Overview
              </Sidebar.Item>
              <Sidebar.Item
                href="/docs/authenticate/local-auth"
                active={p == "/docs/authenticate/local-auth"}
              >
                Local Authentication
              </Sidebar.Item>
              <Sidebar.Item
                href="/docs/authenticate/multi-factor"
                active={p == "/docs/authenticate/multi-factor"}
              >
                Multi-Factor Authentication
              </Sidebar.Item>
              <Sidebar.Collapse
                label="OpenID Connect"
                open={p.startsWith("/docs/authenticate/oidc")}
              >
                <Sidebar.Item
                  href="/docs/authenticate/oidc"
                  active={p == "/docs/authenticate/oidc"}
                >
                  Overview
                </Sidebar.Item>
                <Sidebar.Item
                  href="/docs/authenticate/oidc/auth0"
                  active={p == "/docs/authenticate/oidc/auth0"}
                >
                  Auth0
                </Sidebar.Item>
                <Sidebar.Item
                  href="/docs/authenticate/oidc/azuread"
                  active={p == "/docs/authenticate/oidc/azuread"}
                >
                  Azure AD
                </Sidebar.Item>
                <Sidebar.Item
                  href="/docs/authenticate/oidc/google"
                  active={p == "/docs/authenticate/oidc/google"}
                >
                  Google Workspace
                </Sidebar.Item>
                <Sidebar.Item
                  href="/docs/authenticate/oidc/keycloak"
                  active={p == "/docs/authenticate/oidc/keycloak"}
                >
                  Keycloak
                </Sidebar.Item>
                <Sidebar.Item
                  href="/docs/authenticate/oidc/okta"
                  active={p == "/docs/authenticate/oidc/okta"}
                >
                  Okta
                </Sidebar.Item>
                <Sidebar.Item
                  href="/docs/authenticate/oidc/onelogin"
                  active={p == "/docs/authenticate/oidc/onelogin"}
                >
                  OneLogin
                </Sidebar.Item>
                <Sidebar.Item
                  href="/docs/authenticate/oidc/zitadel"
                  active={p == "/docs/authenticate/oidc/zitadel"}
                >
                  Zitadel
                </Sidebar.Item>
              </Sidebar.Collapse>
              <Sidebar.Collapse
                label="SAML 2.0"
                open={p.startsWith("/docs/authenticate/saml")}
              >
                <Sidebar.Item
                  href="/docs/authenticate/saml"
                  active={p == "/docs/authenticate/saml"}
                >
                  Overview
                </Sidebar.Item>
                <Sidebar.Item
                  href="/docs/authenticate/saml/okta"
                  active={p == "/docs/authenticate/saml/okta"}
                >
                  Okta
                </Sidebar.Item>
                <Sidebar.Item
                  href="/docs/authenticate/saml/onelogin"
                  active={p == "/docs/authenticate/saml/onelogin"}
                >
                  OneLogin
                </Sidebar.Item>
                <Sidebar.Item
                  href="/docs/authenticate/saml/jumpcloud"
                  active={p == "/docs/authenticate/saml/jumpcloud"}
                >
                  JumpCloud
                </Sidebar.Item>
              </Sidebar.Collapse>
            </Sidebar.Collapse>
            <Sidebar.Collapse
              label="Administer"
              open={p.startsWith("/docs/administer")}
            >
              <Sidebar.Item
                href="/docs/administer/migrate"
                active={p == "/docs/administer/migrate"}
              >
                Migrate to Docker
              </Sidebar.Item>
              <Sidebar.Item
                href="/docs/administer/upgrade"
                active={p == "/docs/administer/upgrade"}
              >
                Upgrade
              </Sidebar.Item>
              <Sidebar.Item
                href="/docs/administer/backup"
                active={p == "/docs/administer/backup"}
              >
                Backup and Restore
              </Sidebar.Item>
              <Sidebar.Item
                href="/docs/administer/uninstall"
                active={p == "/docs/administer/uninstall"}
              >
                Uninstall
              </Sidebar.Item>
              <Sidebar.Item
                href="/docs/administer/troubleshoot"
                active={p == "/docs/administer/troubleshoot"}
              >
                Troubleshoot
              </Sidebar.Item>
              <Sidebar.Item
                href="/docs/administer/regen-keys"
                active={p == "/docs/administer/regen-keys"}
              >
                Regenerate Secret Keys
              </Sidebar.Item>
              <Sidebar.Item
                href="/docs/administer/debug-logs"
                active={p == "/docs/administer/debug-logs"}
              >
                Debug Logs
              </Sidebar.Item>
            </Sidebar.Collapse>
            <Sidebar.Collapse
              label="User Guides"
              open={p.startsWith("/docs/user-guides")}
            >
              <Sidebar.Item
                href="/docs/user-guides/add-users"
                active={p == "/docs/user-guides/add-users"}
              >
                Add Users
              </Sidebar.Item>
              <Sidebar.Item
                href="/docs/user-guides/add-devices"
                active={p == "/docs/user-guides/add-devices"}
              >
                Add Devices
              </Sidebar.Item>
              <Sidebar.Item
                href="/docs/user-guides/egress-rules"
                active={p == "/docs/user-guides/egress-rules"}
              >
                Egress Rules
              </Sidebar.Item>
              <Sidebar.Item
                href="/docs/user-guides/client-instructions"
                active={p == "/docs/user-guides/client-instructions"}
              >
                Client Instructions
              </Sidebar.Item>
              <Sidebar.Collapse
                label="Common Use Cases"
                open={p.startsWith("/docs/user-guides/common-use-cases")}
              >
                <Sidebar.Item
                  href="/docs/user-guides/common-use-cases/split-tunnel"
                  active={
                    p == "/docs/user-guides/common-use-cases/split-tunnel"
                  }
                >
                  Split Tunnel
                </Sidebar.Item>
                <Sidebar.Item
                  href="/docs/user-guides/common-use-cases/reverse-tunnel"
                  active={
                    p == "/docs/user-guides/common-use-cases/reverse-tunnel"
                  }
                >
                  Reverse Tunnel
                </Sidebar.Item>
                <Sidebar.Item
                  href="/docs/user-guides/common-use-cases/nat-gateway"
                  active={p == "/docs/user-guides/common-use-cases/nat-gateway"}
                >
                  NAT Gateway
                </Sidebar.Item>
              </Sidebar.Collapse>
            </Sidebar.Collapse>
            <Sidebar.Collapse
              label="Reference"
              open={p.startsWith("/docs/reference")}
            >
              <Sidebar.Item
                href="/docs/reference/env-vars"
                active={p == "/docs/reference/env-vars"}
              >
                Environment Variables
              </Sidebar.Item>
              <Sidebar.Item
                href="/docs/reference/configuration-file"
                active={p == "/docs/reference/configuration-file"}
              >
                Configuration File
              </Sidebar.Item>
              <Sidebar.Item
                href="/docs/reference/file-and-directory-locations"
                active={p == "/docs/reference/file-and-directory-locations"}
              >
                File and Directory Locations
              </Sidebar.Item>
              <Sidebar.Item
                href="/docs/reference/telemetry"
                active={p == "/docs/reference/telemetry"}
              >
                Telemetry
              </Sidebar.Item>
              <Sidebar.Collapse
                label="Reverse Proxy Templates"
                open={p.startsWith("/docs/reference/reverse-proxy-templates")}
              >
                <Sidebar.Item
                  href="/docs/reference/reverse-proxy-templates/apache"
                  active={p == "/docs/reference/reverse-proxy-templates/apache"}
                >
                  Apache
                </Sidebar.Item>
                <Sidebar.Item
                  href="/docs/reference/reverse-proxy-templates/traefik"
                  active={
                    p == "/docs/reference/reverse-proxy-templates/traefik"
                  }
                >
                  Traefik
                </Sidebar.Item>
                <Sidebar.Item
                  href="/docs/reference/reverse-proxy-templates/haproxy"
                  active={
                    p == "/docs/reference/reverse-proxy-templates/haproxy"
                  }
                >
                  HAProxy
                </Sidebar.Item>
              </Sidebar.Collapse>
              <Sidebar.Collapse
                label="Firewall Templates"
                open={p.startsWith("/docs/reference/firewall-templates")}
              >
                <Sidebar.Item
                  href="/docs/reference/firewall-templates/nftables"
                  active={p == "/docs/reference/firewall-templates/nftables"}
                >
                  nftables
                </Sidebar.Item>
              </Sidebar.Collapse>
              <Sidebar.Collapse
                label="REST API"
                open={p.startsWith("/docs/reference/rest-api")}
              >
                <Sidebar.Item
                  href="/docs/reference/rest-api"
                  active={p == "/docs/reference/rest-api"}
                >
                  Overview
                </Sidebar.Item>
                <Sidebar.Item
                  href="/docs/reference/rest-api/users"
                  active={p == "/docs/reference/rest-api/users"}
                >
                  Users
                </Sidebar.Item>
                <Sidebar.Item
                  href="/docs/reference/rest-api/configurations"
                  active={p == "/docs/reference/rest-api/configurations"}
                >
                  Configurations
                </Sidebar.Item>
                <Sidebar.Item
                  href="/docs/reference/rest-api/devices"
                  active={p == "/docs/reference/rest-api/devices"}
                >
                  Devices
                </Sidebar.Item>
                <Sidebar.Item
                  href="/docs/reference/rest-api/rules"
                  active={p == "/docs/reference/rest-api/rules"}
                >
                  Rules
                </Sidebar.Item>
              </Sidebar.Collapse>
              <Sidebar.Item
                href="/docs/reference/security-controls"
                active={p == "/docs/reference/security-controls"}
              >
                Security Controls
              </Sidebar.Item>
            </Sidebar.Collapse>
          </Sidebar.ItemGroup>
        </Sidebar.Items>
      </Sidebar>
    </Flowbite>
  );
}

"use client";
import { useEffect } from "react";
import { initFlowbite } from "flowbite";
import Collapse from "./Collapse";
import Item from "./Item";
import { usePathname } from "next/navigation";

export default function DocsSidebar() {
  useEffect(() => {
    // Manually init flowbite's data-toggle listeners since we're using custom components
    initFlowbite();
  }, []);

  const p = usePathname();

  return (
    <aside
      id="docs-sidebar"
      aria-label="Sidebar"
      aria-hidden="true"
      className="z-40 fixed top-0 left-0 w-64 h-screen pt-24 transition-transform -translate-x-full bg-white border-r border-gray-200 md:translate-x-0 dark:bg-gray-800 dark:border-gray-700"
    >
      <div className="h-full overflow-y-auto bg-white dark:bg-gray-800">
        <ul className="space-y-2 font-medium">
          <li>
            <Item href="/docs" label="Overview" />
          </li>
          <li>
            <Collapse expanded={p.startsWith("/docs/deploy")} label="Deploy">
              <li>
                <Item level={2} href="/docs/deploy" label="Overview" />
              </li>
              <li>
                <Collapse
                  level={2}
                  expanded={p.startsWith("/docs/deploy/docker")}
                  label="Docker"
                >
                  <li>
                    <Item
                      level={3}
                      href="/docs/deploy/docker"
                      label="Overview"
                    />
                  </li>
                  <li>
                    <Item
                      level={3}
                      href="/docs/deploy/docker/supported-platforms"
                      label="Supported Platforms"
                    />
                  </li>
                </Collapse>
              </li>
              <li>
                <Collapse
                  level={2}
                  expanded={p.startsWith("/docs/deploy/omnibus")}
                  label="Omnibus"
                >
                  <li>
                    <Item
                      level={3}
                      href="/docs/deploy/omnibus"
                      label="Overview"
                    />
                  </li>
                  <li>
                    <Item
                      level={3}
                      href="/docs/deploy/omnibus/supported-platforms"
                      label="Supported Platforms"
                    />
                  </li>
                </Collapse>
              </li>
              <li>
                <Item
                  level={2}
                  href="/docs/deploy/configure"
                  label="Configure"
                />
              </li>
              <li>
                <Item
                  level={2}
                  href="/docs/deploy/security-considerations"
                  label="Security Considerations"
                />
              </li>
              <li>
                <Collapse
                  level={2}
                  expanded={p.startsWith("/docs/deploy/advanced")}
                  label="Advanced"
                >
                  <li>
                    <Item
                      level={3}
                      href="/docs/deploy/advanced/build-from-source"
                      label="Build from Source"
                    />
                  </li>
                  <li>
                    <Item
                      level={3}
                      href="/docs/deploy/advanced/external-database"
                      label="External Database"
                    />
                  </li>
                  <li>
                    <Item
                      level={3}
                      href="/docs/deploy/advanced/reverse-proxy"
                      label="Custom Reverse Proxy"
                    />
                  </li>
                </Collapse>
              </li>
            </Collapse>
          </li>
          <li>
            <Collapse
              expanded={p.startsWith("/docs/authenticate")}
              label="Authenticate"
            >
              <li>
                <Item level={2} href="/docs/authenticate" label="Overview" />
              </li>
              <li>
                <Item
                  level={2}
                  href="/docs/authenticate/local-auth"
                  label="Local Authentication"
                />
              </li>
              <li>
                <Item
                  level={2}
                  href="/docs/authenticate/multi-factor"
                  label="Multi-Factor Authentication"
                />
              </li>
              <li>
                <Collapse
                  level={2}
                  expanded={p.startsWith("/docs/authenticate/oidc")}
                  label="OpenID Connect"
                >
                  <li>
                    <Item
                      level={3}
                      href="/docs/authenticate/oidc"
                      label="Overview"
                    />
                  </li>
                  <li>
                    <Item
                      level={3}
                      href="/docs/authenticate/oidc/auth0"
                      label="Auth0"
                    />
                  </li>
                  <li>
                    <Item
                      level={3}
                      href="/docs/authenticate/oidc/azuread"
                      label="Azure AD"
                    />
                  </li>
                  <li>
                    <Item
                      level={3}
                      href="/docs/authenticate/oidc/google"
                      label="Google Workspace"
                    />
                  </li>
                  <li>
                    <Item
                      level={3}
                      href="/docs/authenticate/oidc/keycloak"
                      label="Keycloak"
                    />
                  </li>
                  <li>
                    <Item
                      level={3}
                      href="/docs/authenticate/oidc/okta"
                      label="Okta"
                    />
                  </li>
                  <li>
                    <Item
                      level={3}
                      href="/docs/authenticate/oidc/onelogin"
                      label="Onelogin"
                    />
                  </li>
                  <li>
                    <Item
                      level={3}
                      href="/docs/authenticate/oidc/zitadel"
                      label="Zitadel"
                    />
                  </li>
                </Collapse>
              </li>
              <li>
                <Collapse
                  level={2}
                  expanded={p.startsWith("/docs/authenticate/saml")}
                  label="SAML 2.0"
                >
                  <li>
                    <Item
                      level={3}
                      href="/docs/authenticate/saml"
                      label="Overview"
                    />
                  </li>
                  <li>
                    <Item
                      level={3}
                      href="/docs/authenticate/saml/okta"
                      label="Okta"
                    />
                  </li>
                  <li>
                    <Item
                      level={3}
                      href="/docs/authenticate/saml/onelogin"
                      label="Onelogin"
                    />
                  </li>
                  <li>
                    <Item
                      level={3}
                      href="/docs/authenticate/saml/jumpcloud"
                      label="Jumpcloud"
                    />
                  </li>
                </Collapse>
              </li>
            </Collapse>
          </li>
          <li>
            <Collapse
              expanded={p.startsWith("/docs/administer/migrate")}
              label="Administer"
            >
              <li>
                <Item
                  level={2}
                  href="/docs/administer/migrate"
                  label="Migrate to Docker"
                />
              </li>
              <li>
                <Item
                  level={2}
                  href="/docs/administer/upgrade"
                  label="Upgrade"
                />
              </li>
              <li>
                <Item level={2} href="/docs/administer/backup" label="Backup" />
              </li>
              <li>
                <Item
                  level={2}
                  href="/docs/administer/uninstall"
                  label="Uninstall"
                />
              </li>
              <li>
                <Item
                  level={2}
                  href="/docs/administer/troubleshoot"
                  label="Troubleshoot"
                />
              </li>
              <li>
                <Item
                  level={2}
                  href="/docs/administer/regen-keys"
                  label="Regenerate Secret Keys"
                />
              </li>
              <li>
                <Item
                  level={2}
                  href="/docs/administer/debug-logs"
                  label="Debug Logs"
                />
              </li>
            </Collapse>
          </li>
          <li>
            <Collapse
              expanded={p.startsWith("/docs/user-guides")}
              label="User Guides"
            >
              <li>
                <Item
                  level={2}
                  href="/docs/user-guides/add-users"
                  label="Add Users"
                />
              </li>
              <li>
                <Item
                  level={2}
                  href="/docs/user-guides/add-devices"
                  label="Add Devices"
                />
              </li>
              <li>
                <Item
                  level={2}
                  href="/docs/user-guides/egress-rules"
                  label="Egress Rules"
                />
              </li>
              <li>
                <Item
                  level={2}
                  href="/docs/user-guides/client-instructions"
                  label="Client Instructions"
                />
              </li>
              <li>
                <Collapse
                  level={2}
                  expanded={p.startsWith("/docs/user-guides/use-cases")}
                  label="Common Use Cases"
                >
                  <li>
                    <Item
                      level={3}
                      href="/docs/user-guides/use-cases/split-tunnel"
                      label="Split Tunnel"
                    />
                  </li>
                  <li>
                    <Item
                      level={3}
                      href="/docs/user-guides/use-cases/reverse-tunnel"
                      label="Reverse Tunnel"
                    />
                  </li>
                  <li>
                    <Item
                      level={3}
                      href="/docs/user-guides/use-cases/nat-gateway"
                      label="NAT Gateway"
                    />
                  </li>
                </Collapse>
              </li>
            </Collapse>
          </li>
          <li>
            <Collapse
              expanded={p.startsWith("/docs/reference")}
              label="Reference"
            >
              <li>
                <Item
                  level={2}
                  href="/docs/reference/env-vars"
                  label="Environment Variables"
                />
              </li>
              <li>
                <Item
                  level={2}
                  href="/docs/reference/configuration-file"
                  label="Configuration File"
                />
              </li>
              <li>
                <Item
                  level={2}
                  href="/docs/reference/file-and-directory-locations"
                  label="File and Directory Locations"
                />
              </li>
              <li>
                <Item
                  level={2}
                  href="/docs/reference/telemetry"
                  label="Telemetry"
                />
              </li>
              <li>
                <Collapse
                  expanded={p.startsWith(
                    "/docs/reference/reverse-proxy-templates"
                  )}
                  level={2}
                  label="Reverse Proxy Templates"
                >
                  <li>
                    <Item
                      level={3}
                      href="/docs/reference/reverse-proxy-templates/apache"
                      label="Apache"
                    />
                  </li>
                  <li>
                    <Item
                      level={3}
                      href="/docs/reference/reverse-proxy-templates/traefik"
                      label="Traefik"
                    />
                  </li>
                  <li>
                    <Item
                      level={3}
                      href="/docs/reference/reverse-proxy-templates/haproxy"
                      label="HAProxy"
                    />
                  </li>
                </Collapse>
              </li>
              <li>
                <Collapse
                  expanded={p.startsWith("/docs/reference/firewall-templates")}
                  level={2}
                  label="Firewall Templates"
                >
                  <li>
                    <Item
                      level={3}
                      href="/docs/reference/firewall-templates/nftables"
                      label="nftables"
                    />
                  </li>
                </Collapse>
              </li>
              <li>
                <Collapse
                  expanded={p.startsWith("/docs/reference/rest-api")}
                  level={2}
                  label="REST API"
                >
                  <li>
                    <Item
                      level={3}
                      href="/docs/reference/rest-api"
                      label="Overview"
                    />
                  </li>
                  <li>
                    <Item
                      level={3}
                      href="/docs/reference/rest-api/users"
                      label="Users"
                    />
                  </li>
                  <li>
                    <Item
                      level={3}
                      href="/docs/reference/rest-api/configurations"
                      label="Configurations"
                    />
                  </li>
                  <li>
                    <Item
                      level={3}
                      href="/docs/reference/rest-api/devices"
                      label="Devices"
                    />
                  </li>
                  <li>
                    <Item
                      level={3}
                      href="/docs/reference/rest-api/rules"
                      label="Rules"
                    />
                  </li>
                </Collapse>
              </li>
              <li>
                <Item
                  level={2}
                  href="/docs/reference/security-controls"
                  label="Security Controls"
                />
              </li>
            </Collapse>
          </li>
        </ul>
      </div>
    </aside>
  );
}

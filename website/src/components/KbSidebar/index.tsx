import KbSearch from "@/components/KbSearch";
import {
  Sidebar,
  SidebarItem,
  SidebarItems,
  SidebarItemGroup,
  SidebarCollapse,
} from "@/components/Sidebar";

export default function KbSidebar() {
  return (
    <Sidebar>
      <SidebarItems>
        <SidebarItemGroup>
          <SidebarItem>
            <KbSearch />
          </SidebarItem>
        </SidebarItemGroup>
        <SidebarItemGroup>
          <SidebarItem href="/kb">Overview</SidebarItem>
          <SidebarItem href="/kb/quickstart">Quickstart guide</SidebarItem>
        </SidebarItemGroup>
        <SidebarItemGroup label="Get started">
          <SidebarCollapse prefix="/kb/deploy" label="Deploy">
            <SidebarItem href="/kb/deploy">Overview</SidebarItem>
            <SidebarItem href="/kb/deploy/sites">Sites</SidebarItem>
            <SidebarItem href="/kb/deploy/gateways">Gateways</SidebarItem>
            <SidebarItem href="/kb/deploy/resources">Resources</SidebarItem>
            <SidebarItem href="/kb/deploy/groups">Groups</SidebarItem>
            <SidebarItem href="/kb/deploy/users">Users</SidebarItem>
            <SidebarItem href="/kb/deploy/policies">Policies</SidebarItem>
            <SidebarItem href="/kb/deploy/clients">Clients</SidebarItem>
            <SidebarItem href="/kb/deploy/dns">Configure DNS</SidebarItem>
          </SidebarCollapse>
          <SidebarCollapse prefix="/kb/authenticate" label="Authenticate">
            <SidebarItem href="/kb/authenticate">Overview</SidebarItem>
            <SidebarItem href="/kb/authenticate/email">Email (OTP)</SidebarItem>
            <SidebarItem href="/kb/authenticate/google">
              SSO with Google
            </SidebarItem>
            <SidebarItem href="/kb/authenticate/entra">
              SSO with Entra ID
            </SidebarItem>
            <SidebarItem href="/kb/authenticate/okta">
              SSO with Okta
            </SidebarItem>
            <SidebarItem href="/kb/authenticate/oidc">
              SSO with Universal OIDC
            </SidebarItem>
            <SidebarItem href="/kb/authenticate/oidc/fusion">
              SSO with FusionAuth
            </SidebarItem>
            <SidebarItem href="/kb/authenticate/service-accounts">
              Service accounts
            </SidebarItem>
          </SidebarCollapse>
          <SidebarCollapse prefix="/kb/directory-sync" label="Directory Sync">
            <SidebarItem href="/kb/directory-sync">Overview</SidebarItem>
            <SidebarItem href="/kb/directory-sync/okta">
              Directory sync - Okta
            </SidebarItem>
          </SidebarCollapse>
          <SidebarCollapse prefix={"/kb/automate"} label="Automate">
            <SidebarItem href="/kb/automate">Overview</SidebarItem>
            <SidebarItem href="/kb/automate/terraform/aws">
              Terraform + AWS
            </SidebarItem>
            <SidebarItem href="/kb/automate/terraform/gcp">
              Terraform + GCP
            </SidebarItem>
            <SidebarItem href="/kb/automate/terraform/azure">
              Terraform + Azure
            </SidebarItem>
            <SidebarItem href="/kb/automate/docker-compose">
              Docker Compose
            </SidebarItem>
          </SidebarCollapse>
        </SidebarItemGroup>
        <SidebarItemGroup label="Use Firezone">
          <SidebarCollapse prefix="/kb/administer" label="Administer">
            <SidebarItem href="/kb/administer">Overview</SidebarItem>
            <SidebarItem href="/kb/administer/upgrading">
              Upgrade Gateways
            </SidebarItem>
            <SidebarItem href="/kb/administer/backup-restore">
              Backup & restore
            </SidebarItem>
            <SidebarItem href="/kb/administer/logs">Viewing logs</SidebarItem>
            <SidebarItem href="/kb/administer/troubleshooting">
              Troubleshooting
            </SidebarItem>
            <SidebarItem href="/kb/administer/uninstall">
              Uninstall Firezone
            </SidebarItem>
          </SidebarCollapse>
          <SidebarCollapse prefix="/kb/client-apps" label="Client apps">
            <SidebarItem href="/kb/client-apps">Overview</SidebarItem>
            <SidebarItem href="/kb/client-apps/macos-client">macOS</SidebarItem>
            <SidebarItem href="/kb/client-apps/windows-gui-client">
              Windows
            </SidebarItem>
            <SidebarItem href="/kb/client-apps/linux-gui-client">
              Linux
            </SidebarItem>
            <SidebarItem href="/kb/client-apps/ios-client">iOS</SidebarItem>
            <SidebarItem href="/kb/client-apps/android-client">
              Android & ChromeOS
            </SidebarItem>
            <SidebarItem href="/kb/client-apps/linux-headless-client">
              Linux Headless
            </SidebarItem>
            <SidebarItem href="/kb/client-apps/windows-headless-client">
              Windows Headless
            </SidebarItem>
          </SidebarCollapse>
          <SidebarCollapse prefix="/kb/use-cases" label="Use cases">
            <SidebarItem href="/kb/use-cases">Overview</SidebarItem>
            <SidebarItem href="/kb/use-cases/secure-dns">
              Block malicious DNS
            </SidebarItem>
            <SidebarItem href="/kb/use-cases/scale-vpc-access">
              Scale access to a VPC
            </SidebarItem>
            <SidebarItem href="/kb/use-cases/nat-gateway">
              Route through a public IP
            </SidebarItem>
            <SidebarItem href="/kb/use-cases/postgres-access">
              Access a Postgres DB
            </SidebarItem>
            <SidebarItem href="/kb/use-cases/saas-app-access">
              Manage access to a SaaS app
            </SidebarItem>
            <SidebarItem href="/kb/use-cases/host-access">
              Access a remote host
            </SidebarItem>
            <SidebarItem href="/kb/use-cases/private-network-access">
              Access a private network
            </SidebarItem>
            <SidebarItem href="/kb/use-cases/web-app-access">
              Access a private web app
            </SidebarItem>
          </SidebarCollapse>
        </SidebarItemGroup>
        <SidebarItemGroup label="Learn more">
          <SidebarCollapse prefix="/kb/architecture" label="Architecture">
            <SidebarItem href="/kb/architecture">Overview</SidebarItem>
            <SidebarItem href="/kb/architecture/core-components">
              Core components
            </SidebarItem>
            <SidebarItem href="/kb/architecture/tech-stack">
              Tech stack
            </SidebarItem>
            <SidebarItem href="/kb/architecture/critical-sequences">
              Critical sequences
            </SidebarItem>
            <SidebarItem href="/kb/architecture/security-controls">
              Security controls
            </SidebarItem>
          </SidebarCollapse>
          <SidebarCollapse prefix="/kb/reference" label="Reference">
            <SidebarItem href="/kb/reference/rest-api">REST API</SidebarItem>
            <SidebarItem href="/kb/reference/faq">FAQ</SidebarItem>
            <SidebarItem href="/kb/reference/glossary">Glossary</SidebarItem>
            <SidebarItem href="/kb/reference/restricted-regions">
              Restricted regions
            </SidebarItem>
          </SidebarCollapse>
        </SidebarItemGroup>
      </SidebarItems>
    </Sidebar>
  );
}

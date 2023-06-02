"use client";
import { Code, Link, P, OL, UL, H1, H4 } from "@/components/Base";
import SupportOptions from "@/components/SupportOptions";
import { Alert, Tabs } from "flowbite-react";

export default function Page() {
  return (
    <div>
      <H1>Backup and Restore</H1>

      <P>
        Firezone can be safely backed up and restored in a couple of minutes
        under most circumstances.
      </P>

      <Alert color="info">
        This guide is written for Firezone deployments using{" "}
        <strong>Docker Engine</strong> on <strong>Linux</strong> only.
      </Alert>

      <P>
        Unless your hosting provider supports taking live VM snapshots, you'll
        need to stop Firezone before backing it up. This ensures the Postgres
        data directory is in a consistent state when the backup is performed.
        Backing up a running Firezone instance will **most likely** result in
        data loss when restored; you have been warned.
      </P>

      <P>
        After stopping Firezone, backing up Firezone is mostly a matter of
        copying the relevant{" "}
        <Link href="/docs/reference/file-and-directory-locations">
          files and
        </Link>{" "}
        to a location of your choosing.
      </P>

      <P>See the steps below for specific examples for Docker and Omnibus.</P>

      <Tabs.Group>
        <Tabs.Item title="Docker" active>
          <H4>Backup</H4>
          <P>
            For Docker-based deployments, this will consist of backing up the
            <Code>$HOME/.firezone</Code>
            directory along with the Postgres data directory, typically located
            at
            <Code>/var/lib/docker/volumes/firezone_postgres-data</Code> on Linux
            if you're using the default Docker compose template.
          </P>
          <OL>
            <li>
              Stop Firezone (warning: this <strong>will</strong> disconnect any
              users connected to the VPN):
              <pre>
                <Code>
                  docker compose -f $HOME/.firezone/docker-compose.yml down
                </Code>
              </pre>
            </li>
            <li>
              Copy relevant files and folders. If your made any customizations
              to
              <Code>/etc/docker/daemon.json</Code>
              (for example, for IPv6 support), be sure to include that in the
              backup as well.
              <pre>
                <Code>
                  tar -zcvfp $HOME/firezone-back-$(date +'%F-%H-%M').tgz
                  $HOME/.firezone /var/lib/docker/volumes/firezone_postgres-data
                </Code>
              </pre>
              <P>
                A backup file named <Code>firezone-back-TIMESTAMP.tgz</Code>{" "}
                will then be stored in <Code>$HOME/</Code>.
              </P>
            </li>
          </OL>
          <H4>Restore</H4>
          <OL>
            <li>
              Copy the files back to their original location:
              <pre>
                <Code>
                  tar -zxvfp /path/to/firezone-back.tgz -C / --numeric-owner
                </Code>
              </pre>
            </li>
            <li>
              Optionally, enable Docker to boot on startup:
              <pre>
                <Code>systemctl enable docker</Code>
              </pre>
            </li>
          </OL>
        </Tabs.Item>
        <Tabs.Item title="Omnibus">
          <H4>Backup</H4>

          <OL>
            <li>
              Stop Firezone (warning: this <strong>will</strong> disconnect any
              users connected to the VPN):
              <pre>
                <Code>firezone-ctl stop</Code>
              </pre>
            </li>
            <li>
              Copy relevant files and folders:
              <pre>
                <Code>
                  tar -zcvfp $HOME/firezone-back-$(date +'%F-%H-%M').tgz
                  /var/opt/firezone /opt/firezone /usr/bin/firezone-ctl
                  /etc/systemd/system/firezone-runsvdir-start.service
                  /etc/firezone
                </Code>
              </pre>
              <P>
                A backup file named <Code>firezone-back-TIMESTAMP.tgz</Code>
                will then be stored in <Code>$HOME/</Code>.
              </P>
            </li>
          </OL>

          <H4>Restore</H4>
          <OL>
            <li>
              Copy the files back to their original location:
              <pre>
                <Code>
                  tar -zxvfp /path/to/firezone-back.tgz -C / --numeric-owner
                </Code>
              </pre>
            </li>
          </OL>
          <OL>
            <li>
              Reconfigure Firezone to ensure configuration is applied to the
              host system:
              <pre>
                <Code>firezone-ctl reconfigure</Code>
              </pre>
            </li>
          </OL>
        </Tabs.Item>
      </Tabs.Group>

      <SupportOptions />
    </div>
  );
}

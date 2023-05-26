"use client";

import Link from "next/link";
import SupportOptions from "@/components/SupportOptions";
import { Alert, Tabs } from "flowbite-react";

export default function Page() {
  return (
    <div>
      <h1>Backup and Restore</h1>

      <p>
        Firezone can be safely backed up and restored in a couple of minutes
        under most circumstances.
      </p>

      <Alert color="info">
        <p>
          This guide is written for Firezone deployments using **Docker Engine**
          on **Linux** only.
        </p>
      </Alert>

      <p>
        Unless your hosting provider supports taking live VM snapshots, you'll
        need to stop Firezone before backing it up. This ensures the Postgres
        data directory is in a consistent state when the backup is performed.
        Backing up a running Firezone instance will **most likely** result in
        data loss when restored; you have been warned.
      </p>

      <p>
        After stopping Firezone, backing up Firezone is mostly a matter of
        copying the relevant
        <Link href="/docs/reference/file-and-directory-locations">
          files and
        </Link>
        to a location of your choosing.
      </p>

      <p>See the steps below for specific examples for Docker and Omnibus.</p>

      <Tabs.Group>
        <Tabs.Item title="Docker" active>
          <h3>Backup</h3>
          <p>
            For Docker-based deployments, this will consist of backing up the
            <code>$HOME/.firezone</code>
            directory along with the Postgres data directory, typically located
            at
            <code>/var/lib/docker/volumes/firezone_postgres-data</code> on Linux
            if you're using the default Docker compose template.
          </p>
          <li>
            Stop Firezone (warning: this <strong>will</strong> disconnect any
            users connected to the VPN):
            <pre>
              <code>
                docker compose -f $HOME/.firezone/docker-compose.yml down
              </code>
            </pre>
          </li>
          <li>
            Copy relevant files and folders. If your made any customizations to
            <code>/etc/docker/daemon.json</code>
            (for example, for IPv6 support), be sure to include that in the
            backup as well.
            <pre>
              <code>
                tar -zcvfp $HOME/firezone-back-$(date +'%F-%H-%M').tgz
                $HOME/.firezone /var/lib/docker/volumes/firezone_postgres-data
              </code>
            </pre>
            <p>
              A backup file named <code>firezone-back-TIMESTAMP.tgz</code> will
              then be stored in <code>$HOME/</code>.
            </p>
          </li>
          <h3>Restore</h3>
          <ol>
            <li>
              Copy the files back to their original location:
              <pre>
                <code>
                  tar -zxvfp /path/to/firezone-back.tgz -C / --numeric-owner
                </code>
              </pre>
            </li>
            <li>
              Optionally, enable Docker to boot on startup:
              <pre>
                <code>systemctl enable docker</code>
              </pre>
            </li>
          </ol>
        </Tabs.Item>
        <Tabs.Item title="Omnibus">
          <h3>Backup</h3>

          <ol>
            <li>
              Stop Firezone (warning: this <strong>will</strong> disconnect any
              users connected to the VPN):
              <pre>
                <code>firezone-ctl stop</code>
              </pre>
            </li>
            <li>
              Copy relevant files and folders:
              <pre>
                <code>
                  tar -zcvfp $HOME/firezone-back-$(date +'%F-%H-%M').tgz
                  /var/opt/firezone /opt/firezone /usr/bin/firezone-ctl
                  /etc/systemd/system/firezone-runsvdir-start.service
                  /etc/firezone
                </code>
              </pre>
              <p>
                A backup file named <code>firezone-back-TIMESTAMP.tgz</code>
                will then be stored in <code>$HOME/</code>.
              </p>
            </li>
          </ol>

          <h3>Restore</h3>
          <ol>
            <li>
              Copy the files back to their original location:
              <pre>
                <code>
                  tar -zxvfp /path/to/firezone-back.tgz -C / --numeric-owner
                </code>
              </pre>
            </li>
          </ol>
          <ol>
            <li>
              Reconfigure Firezone to ensure configuration is applied to the
              host system:
              <pre>
                <code>firezone-ctl reconfigure</code>
              </pre>
            </li>
          </ol>
        </Tabs.Item>
      </Tabs.Group>

      <SupportOptions />
    </div>
  );
}

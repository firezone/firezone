package dev.firezone.android.cli;

import dev.firezone.android.cli.Status;

interface IFirezoneCli {
    int protocolVersion();

    Status status();
}

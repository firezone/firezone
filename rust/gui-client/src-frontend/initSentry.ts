import * as Sentry from "@sentry/react";
import type { Client } from '@sentry/core';

type Environment = "production" | "staging" | "on-prem" | "unknown";

let client: Client | undefined;

export default function initSentry(apiUrl: string) {
  let env = environment(URL.parse(apiUrl));

  if (env == "on-prem" || env == "unknown") {
    if (client) {
      client.close();
    }

    return;
  }

  let options = {
    dsn: "https://2e17bf5ed24a78c0ac9e84a5de2bd6fc@o4507971108339712.ingest.us.sentry.io/4508008945549312",
    environment: env,
    release: `gui-client@${__APP_VERSION__}`,
  };

  console.log("Initialising Sentry", { options })

  client = Sentry.init(options);
}

function environment(url: URL | null): Environment {
  if (!url) {
    return "unknown"
  }

  switch (url.host) {
    case "api.firezone.dev": {
      return "production";
    }
    case "api.firez.one": {
      return "staging";
    }
    default:
      return "on-prem";
  }
}

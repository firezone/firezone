import * as Sentry from "@sentry/react";
import { listen } from "@tauri-apps/api/event";
import { Url } from "url";

interface TelemetryContext {
  dsn: string;
  release: string;
  api_url: Url;
}

type Environment = "production" | "staging" | "on-prem";

listen<TelemetryContext>("start_telemetry", (e) => {
  let ctx = e.payload;
  let env = environment(ctx.api_url);

  if (env == "on-prem") {
    return;
  }

  Sentry.init({
    dsn: ctx.dsn,
    environment: env,
    release: ctx.release,
  });
});

function environment(url: Url): Environment {
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

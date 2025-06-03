import React, { StrictMode } from "react";
import ReactDOM from "react-dom/client";
import App from "./components/App";
import { BrowserRouter } from "react-router";
import { createTheme, ThemeProvider } from "flowbite-react";
import * as Sentry from "@sentry/react";

const customTheme = createTheme({
  sidebar: {
    root: { inner: "rounded-none bg-white" },
  },
  button: {
    color: {
      default: "bg-accent-450 hover:bg-accent-700 text-white",
      alternative:
        "text-neutral-900 border border-neutral-200 hover:bg-neutral-300 hover:text-neutral-900",
    },
  },
  textInput: {
    field: {
      input: {
        colors: {
          gray: "focus:ring-accent-500 focus:border-accent-500",
        },
      },
    },
  },
  toggleSwitch: {
    toggle: {
      checked: {
        color: {
          default: "bg-accent-500"
        }
      }
    }
  },
});

ReactDOM.createRoot(document.getElementById("root") as HTMLElement, {
  // Callback called when an error is thrown and not caught by an ErrorBoundary.
  onUncaughtError: Sentry.reactErrorHandler((error, errorInfo) => {
    console.warn("Uncaught error", error, errorInfo.componentStack);
  }),
  // Callback called when React catches an error in an ErrorBoundary.
  onCaughtError: Sentry.reactErrorHandler(),
  // Callback called when React automatically recovers from errors.
  onRecoverableError: Sentry.reactErrorHandler(),
}).render(
  <StrictMode>
    <BrowserRouter>
      <ThemeProvider theme={customTheme}>
        <App />
      </ThemeProvider>
    </BrowserRouter>
  </StrictMode>
);

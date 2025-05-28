import React, { StrictMode } from "react";
import ReactDOM from "react-dom/client";
import { initThemeMode } from "flowbite-react";
import App from "./components/App";
import { BrowserRouter } from "react-router";

ReactDOM.createRoot(document.getElementById("root") as HTMLElement).render(
  <StrictMode>
    <BrowserRouter>
      <App />
    </BrowserRouter>
  </StrictMode>
);

initThemeMode({mode: "dark"});

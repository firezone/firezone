Source code for Mermaid diagrams, so `Prettier` won't trash them

```
flowchart TD
  A(Firezone Client) --> B(Tauri)
  B --> C(WRY)
  C --> D("WebView2 (Windows)")
  C --> E("webkit2gtk (Linux)")
  C --> F(TAO)
  B --> G(Tokio)
  A --> G
  A --> J(connlib)
  F --> H(GTK+)
  F --> I(Windows)

flowchart TD
  A(MSI) --> B(GUI exe)
  A --> C(IPC service exe)
  A --> D(WebView2 downloader)

flowchart TD
  A(deb) --> B(GUI exe)
  A --> C(IPC service exe)
  A --> D("webkit2gtk dependencies")
```

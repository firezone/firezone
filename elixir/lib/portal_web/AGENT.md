# Portal UI rules

These rules apply to everything under `lib/portal_web`. Read them before you add or change a page.

## The look

- Black and white. Draw every usual state in the foreground colour or a grey.
- One accent colour, `attn`, and only for something that needs an action: an offline device, a denied flow, a policy nobody uses, a destructive button, a validation error. Never use it for decoration.
- Square corners. Hairlines (`border-hair`) between rows, a rule (`border-rule`) under table headings and around overlays.
- Weight, size and space make hierarchy, not colour.
- Light and dark themes come from the same tokens. Never write a colour that does not switch (`#hex`, `bg-white`, `text-red-600`, `bg-violet-50`, ...).

## Tokens

Use these names in new code. They are defined in `assets/css/main.css`.

| Token            | Use                                                        |
| ---------------- | ---------------------------------------------------------- |
| `text-fg`        | Body text, names, values                                   |
| `text-muted`     | Secondary text, descriptions, labels                       |
| `text-faint`     | Placeholders, disabled, decoration                         |
| `bg-bg`          | Page and overlay background                                |
| `bg-hover`       | Row hover, selected row, quiet fills                       |
| `border-hair`    | Between rows and list items                                |
| `border-rule`    | Under table headings, around menus and modals, buttons     |
| `text-attn`      | Needs action. Pair with `border-attn` or `bg-attn-wash`    |
| `bg-veil`        | The veil behind a modal                                    |

The old names (`text-heading`, `text-body`, `text-subtle`, `bg-surface`, `bg-raised`, `brand`, `accent`, `success`, ...) still resolve to these greys so old markup stays monochrome. Do not add new uses of them. `primary-*`, `accent-*` and `neutral-*` palettes are greys too.

## Type

- Page title: `Page.page_header`, 26px bold.
- Eyebrow label above a block: `text-[11px] font-semibold tracking-[.12em] uppercase text-muted`. `Core.header` renders one with a rule under it.
- Body and table cells: 14px (`text-sm`). Secondary line under a name: `text-xs text-muted`.
- Addresses, IDs, keys, times in logs: `font-mono`.

## Icons

Use Remix icons through `<Core.icon name="ri-...-line" />`. Use them on nav items, tabs, buttons, empty states and section labels so people can scan. Prefer the `-line` variants, sized `w-3.5 h-3.5` or `w-4 h-4`, in `text-muted` unless they carry meaning.

## Navigation

- The sidebar has four places: Activity, Team, Access, Routing. Settings sits below them; the account menu (profile, theme, docs, sign out) is at the bottom.
- Each place has tabs across the top. The layout draws them from `Navigation.sections/1`; a page never draws its own section tabs. Add a tab there when you add a page to a place.

## Pages

- Start with `Page.page_header` (title, one-line description, actions on the right). Do not pass the `:icon` slot.
- Lists use `LiveTable.live_table`.
  - Keep the columns few. Each list has the columns from the mockups (see below); everything else belongs in the item's modal.
  - The search box (`{:string, :websearch}` filters) stays in the bar. Every other filter goes into the Filters menu automatically.
  - A column that only matters while a filter is applied takes `filter={:that_filter}` on its `:col`. It shows only while the filter is applied.
- One item opens in `Page.detail_modal` over the list. Pass the event the page already uses for Escape as `on_close`; it also runs on a veil click. Keep the old element id (for example `id="resource-panel"`) so tests and links keep working.
- Inside a modal: `Form.panel_header`, a scrolling body, `Form.panel_footer` for actions.
- Confirmations use `Form.modal`.
- Detail content: eyebrow label, then a plain list with hairlines, or `Table.vertical_table` for key and value pairs. Show every field the old page showed. Put rare fields behind an expand control rather than dropping them.
- Status: `Core.status_badge`. Online is a filled dot; offline or failed is a hollow `attn` ring.
- Chips for routes and types: `Core.badge` (outlined). A dashed border means a direct route with no site.

### List columns

| List              | Columns                               |
| ----------------- | ------------------------------------- |
| Policies          | Group, Resource, Status               |
| Resources         | Resource, Address, Route              |
| Sites             | Site, Resources, Devices online       |
| Devices           | Device, Owner or site, Last seen      |
| People            | Name, Groups, Last active             |
| Service accounts  | Name, Groups, Last active             |
| Groups            | Group, Members, Policies              |
| Activity          | Time, Who, What, Result               |

## Behaviour to keep

- Keep routes, element ids and event names unless a change needs them to move. Tests and bookmarks depend on them.
- Every panel event must stay in the page's `stale_event?/2` lists (see `PortalWeb.Live.Helpers.drop_stale_events/1`).
- No new JavaScript libraries. Hooks live in `assets/js/hooks`.
- Write data through `Portal.Safe`, in a `Database` module next to the LiveView.

## Direct access

`PortalWeb.DirectAccess` gives people access to one resource without an admin-made group. It keeps them in a group with `resource_id` set. Never list those groups as groups; show their members as people on the resource.

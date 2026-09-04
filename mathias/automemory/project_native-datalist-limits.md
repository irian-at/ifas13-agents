---
name: native-datalist-limits
description: "The <datalist> popup is browser UI: colour and placement are not page-controllable, and Chrome's own arrow needs !important to hide"
metadata: 
  node_type: memory
  type: project
  originSessionId: 8baadddf-4df1-43da-9172-adbd2802b876
  modified: 2026-09-04T12:43:38.219Z
---

The Lieferant fields in `ifas-web-ui` use a native HTML5 `<datalist>` (see
[[project_web-ui-frontend-constraints]] for why a JS library was ruled out). Its hard limits, all
hit and confirmed in practice on 2026-09-04:

- **The popup is browser UI, not page content.** Mozilla's own bug 1756203 groups it with
  `alert()` and the datetime-picker: *"overlays/menus that come from web content but are styled as
  browser UI (e.g. datetime-picker, text-input datalist, ...)"*. So under a dark **Firefox theme**
  the popup is black on the white page, and **no page CSS reaches it** — `color-scheme: light` on
  `:root` does nothing for it (I shipped that as a fix and had to back it out). MDN: *"If you
  really need full control over the option styling, you'll have to either use a library to generate
  a custom control or build your own."*
- **Position and width are the browser's.** The popup sizes to the longest option label, so with
  long labels on a narrow field Chrome shifts it left/right instead of aligning it under the input.
  Not settable. Shortening the labels is the only lever.
- **A `<select>` behaves differently on purpose**: its dropdown *is* painted from the element's own
  CSS, which is why the neighbouring Status/Jahresdatenmeldung filters look right and the Lieferant
  one does not. Don't reason from one to the other.

**Hiding Chrome's own arrow needs `!important`:**

```css
input[list]::-webkit-calendar-picker-indicator { display: none !important; }
```

Without it the field grows a second solid ▼ next to ours. Two traps around this:

- Chrome shows that indicator **only on hover**, so a screenshot of an un-hovered field looks
  correct — always hover before judging.
- `getComputedStyle(el, '::-webkit-calendar-picker-indicator')` is worthless here: for an unmatched
  or shadow pseudo it returns *the element's own* style, so it reported `display: block` while the
  rule was in fact applied, and reported plausible values for a pseudo that does not exist
  (`::-webkit-list-button`). Verify by screenshotting pixels, not by reading computed style.

**How to apply:** if a request needs a styled, predictably placed or theme-independent suggestion
popup, the native control cannot deliver it — build a page-DOM dropdown (the `table-tools.js` style
fits) rather than attempting another CSS workaround. The trade-off was put to Mathias on
2026-09-04 and he chose to keep the native datalist and live with the dark/offset popup.

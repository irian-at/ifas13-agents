---
name: web-ui-frontend-constraints
description: "ifas-web-ui has no npm/webjars/CDN and its layout pulls only ~{::section} — new markup or scripts outside <section> are silently dropped"
metadata: 
  node_type: memory
  type: project
  originSessionId: 8baadddf-4df1-43da-9172-adbd2802b876
  modified: 2026-09-04T10:45:39.395Z
---

`ifas-web-ui` is Spring MVC + Thymeleaf + **hand-vendored** Bootstrap 5.1.3 + vanilla JS. There is
no `package.json`, no webpack/vite, no webjar dependency, and no CDN reference anywhere
(`docs/firewall-requests.md` approves only internal OeKB hosts). Adding a library means committing
a minified blob to `static/js/` named `<version>_<upstream-dist-path>.js`.

Three traps that cost time:

- **The layout has one content slot.** `layout.html` is `th:fragment="layout (title, content)"` and
  every page attaches with `th:replace="~{layout :: layout( ~{::title/text()}, ~{::section} )}"`.
  Only the `<section>` element is pulled in — a `<script>`, `<datalist>` or anything else placed
  outside it is silently discarded, with no error. `table-tools.js` is loaded inside `<section>`
  for exactly this reason.
- **Named beans are callable from templates**: `${@global.maxFileSize}`, `${@vienna.format(x)}`,
  `${@filesize.format(x)}`, `${@healthLabels.label(x)}` — all `@Component("name")`. Handy, but every
  existing one is a pure formatter; none hits the database. Restricted expressions (`@{...}`,
  `~{...}`, event attributes) ban bean access, which is what `GlobalModelAttributes` exists for.
- **`@ControllerAdvice` without `assignableTypes` fires on everything** under `/ui/**` — every
  download, every `@ResponseBody` JSON endpoint, every page. Scope a data-loading `@ModelAttribute`
  to the controllers that need it; `GlobalModelAttributes` is the wrong home for anything that
  queries.

Web UI requests get their DB context from `WebAppMultiDbWebMvcConfig`'s interceptor: `preHandle`
binds `DatabaseContextHolder` from the session, `afterCompletion` clears it **after** view
rendering — so a repository call from an advice or during render still routes correctly.

The codebase is deliberately browser-native-first (`<input type="date">` over a JS datepicker,
`table-tools.js` over DataTables); native `<datalist>` and friends fit it better than a library.

See [[project_headless-launch-devtools-npe]] for verifying UI changes against a running app.

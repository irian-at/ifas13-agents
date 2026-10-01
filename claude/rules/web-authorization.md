---
paths:
  - "ifas-web/**/*.java"
  - "ifas-web/**/templates/**/*.html"
---

# Web Authorization (IfasRight)

**HARD RULE: every new or changed URL surface must be authorized in `IfasRight`** —
`ifas-web/ifas-web-core/src/main/java/at/oekb/ifas/web/core/auth/IfasRight.java`, the single
source of truth for `IfasSecurityConfig`. This applies to REST endpoints (`/api/...`) and UI
pages (`/ui/...`) alike. A path no right covers falls through to the `IFAS_INTRA_LOGIN` floor:
S2S callers are denied, and UI users get more access than intended.

## When adding an endpoint or page

1. Add the path to a fitting existing right, or a new constant (with an `IfasAuthority` if a new
   role is needed - also add it to `IfasAuthority.ALL`).
2. Paths start with `/` and list the bare path **and** `/**`
   (`"/api/foo", "/api/foo/**"`) - `PathPatternRequestMatcher` does not match the bare path with `/**`.
3. State-changing `/api/**` calls are restricted to S2S roles - `/api/**` is CSRF-exempt, so an
   interactive role must never be granted a non-GET method there.
4. Keep the class Javadoc's list of non-menu rights current.
5. Add authorization tests in `IfasSecurityConfigAuthorizationTest` (granted role, denied roles).
6. Mention the right (and any new role) in the summary to the user - roles need provisioning.
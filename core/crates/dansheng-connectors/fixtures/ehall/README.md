# eHall synthetic fixtures

All identities, task numbers, text and URL signature values here are handmade.
They are not personal server captures. Public field/path discovery is documented
in `docs/fudan-service-research/portal-life-services.md` (2026-11-09).

`catalog.json` reproduces the publicly observed non-empty list with total=0 and
ignored limit. Foreign, credential-bearing and signed entries test link filtering.
`todo-page1.json` / `todo-page2.json` test fixed-size pagination and discarded form,
mobile, flowchart, contact and applicant fields. `applications.json` preserves an
unknown status. Private task ID aliases are provisional until an authorized,
sanitized live schema check; no missing ID is fabricated from titles or URLs.

The connector returns summaries only. An internal ref does not imply a verified
detail/approval/attachment API; incomplete scans cannot drive cache deletions.
# Current public-description observation

On 2026-11-09 the first ten real anonymous entries had string titles/categories,
one null description, a description of 9757 UTF-8 bytes, and two descriptions
containing URLs. No actual text was copied here. Synthetic tests cover optional
description omission with explicit state, and exclude active script text.
An AJAX anonymous identity read returned e=10013 plus d.loginUrl; a synthetic
authentication envelope verifies that the signed redirect/message are discarded.

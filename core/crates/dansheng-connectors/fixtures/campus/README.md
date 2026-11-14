Newly authored synthetic fixtures only. Envelope names, selectors, query shapes
and field mappings derive from public DanXi commit 3c1f5f0, as attributed in the
source modules and crate README. No live campus/forum/ecard traffic, user records,
credentials or downloaded course/review content were used. All names and IDs are
invented. SYNTHETIC-* strings test that CSRF/QR/unknown token fields cannot enter
exported domain records or error messages; they are not credentials.

Mixed empty-classroom text intentionally contains a non-JSON script tail and a
bracket in a room name. PE retains the source's 6th/26th-row selector layout.
PG grades deliberately report more rows than provided, to test explicit incomplete
coverage instead of invented pagination. Forum unzoned time is intentionally kept
as text; no timezone is inferred for it.

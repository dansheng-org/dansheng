# Fudan OPAC synthetic fixtures

All records/identities/signatures here are handmade, not copied public books or
private service captures. Protocol observations on 2026-11-09:

- The official `app.ea0f02cf08d19b244213.js` calls singleVolume with GET
  `searchKey=resource_djtmh|resource_djssh&value=…` (not keyword searchConditions).
- Anonymous GET singleVolume for an ordinary call number returned 200 JSON with
  `success,code,msg,data.list`; one item had only resource_smjlh/resource_djtmh.
  A synthetic nonexistent call-number query returned a real empty list.
- The discovered public catalogue ID was used for a bounded GET of the exact
  v2/holdings path (catalogueId/pageNo/pageSize/display=true). It returned code=200,
  data.list/data.total, with id/display/itemStatus/location/callNo fields.
- GET `/urdh/open-api/opac/search/smjlh/{id}` returned code=200, data array with
  one bibliography. Numeric catalogue IDs use the public JS base62 detail route.

No original book response/body, reader row, barcode or token was saved. Private
getReaderInfo/current-loan/history-v2 shapes are from public frontend code only,
and remain not live-validated. The v2 history GET has catalogueInstance,
catalogueId, loanDate, returnDate and renewalCount; it must not be conflated with
the older history POST and itemInfo/loanLog schema.

Reader verification needs a trusted host baseline established during visible
authentication. An observed getReaderInfo barcode is hashed for the host; it
does not by itself verify that the token belongs to the intended local account.
No user-ID parameter is sent. HostHeaders injects access_token outside the
connector; request headers never contain its value.

Current/history are separate source capabilities and external-ID namespaces.
Date text retains provenance and precision, with no inferred timezone or numeric
timestamp unit. Current `checkinDateTime` means the UI's due-date display, not an
actual return; history `returnDate` is a separate field. Neither endpoint triggers
renewal, reservation or automatic reminders.

# Source and license notice

This crate and the official JavaScript examples are GPL-3.0-or-later. The full
license is provided in LICENSE. Adaptations retain the upstream copyrights and
are supplied without warranty. No upstream credentials, databases, user data,
build products, Electron, Flutter, or browser runtime are included.

Fudan timetable endpoints, JSON field mappings, the undergraduate Sunday-to-Monday
week/date conversion, and postgraduate bitmap indexing are adapted from:

- Copyright (C) 2021 DanXi-Dev, GPL version 3 or any later version.
- DanXi commit `3c1f5f026fbc7ca50e151865f813cdb381807abe`:
  - https://github.com/DanXi-Dev/DanXi/blob/3c1f5f026fbc7ca50e151865f813cdb381807abe/lib/model/time_table.dart
  - https://github.com/DanXi-Dev/DanXi/blob/3c1f5f026fbc7ca50e151865f813cdb381807abe/lib/repository/fdu/time_table_repository.dart
  - https://github.com/DanXi-Dev/DanXi/blob/3c1f5f026fbc7ca50e151865f813cdb381807abe/lib/repository/fdu/postgraduate_timetable_repository.dart
  - https://github.com/DanXi-Dev/DanXi/blob/3c1f5f026fbc7ca50e151865f813cdb381807abe/lib/repository/fdu/edu_service_repository.dart

Canvas pagination origin validation, repeated-page protection and file/assignment
source mapping are informed by and adapted from:

- Copyright (C) Dela authors and contributors, GPL-3.0-or-later.
- Dela commit `e82da12f0ddc3e9dec647e5acabe907ac5ee07c3`:
  - https://github.com/Chang-Yo/Dela/blob/e82da12f0ddc3e9dec647e5acabe907ac5ee07c3/src/main/canvas/api.ts
  - https://github.com/Chang-Yo/Dela/blob/e82da12f0ddc3e9dec647e5acabe907ac5ee07c3/src/shared/canvas.ts
  - https://github.com/Chang-Yo/Dela/blob/e82da12f0ddc3e9dec647e5acabe907ac5ee07c3/LICENSE

The Rust implementation removes Dela's school-specific Canvas origin, credential
store and runtime. It adds explicit host token HTTP, Cookie-session HTTP and
browser-context modes, with bounded pagination.
Canvas field and pagination behavior was also checked against Instructure's docs:

- https://developerdocs.instructure.com/services/canvas/basics/file.pagination
- https://developerdocs.instructure.com/services/canvas/resources/courses
- https://developerdocs.instructure.com/services/canvas/resources/assignments
- https://developerdocs.instructure.com/services/canvas/resources/files

Synthetic fixtures are newly authored and are not captures from either project or
an authenticated service. Rust adaptation and new examples: copyright (C) 2026
dansheng-core contributors, GPL-3.0-or-later.

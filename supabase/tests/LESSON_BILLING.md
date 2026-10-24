# Scheduling and package billing

Concrete `lessons.billing_status` is authoritative:

- `covered`: linked to a student's package; `consumes_lesson` still controls the existing actual-consumption decision.
- `pending`: paid lesson awaiting coverage; no package and no consumption until coverage is assigned.
- `free`: intentionally free; never automatically allocated a package.

`lesson_series.package_id` is a preference, not a requirement for every occurrence. The existing `takes_package_lesson` RPC argument expresses paid versus free intent; paid lessons may be pending. An explicit package preference is ownership-checked. The allocator can fall back to other active eligible packages.

Allocation orders pending concrete lessons by `scheduled_at, id`, then selects an active package with capacity and valid Kyiv lesson dates. Package preference comes first, followed by nearest expiry, creation time and ID. Capacity includes existing covered reservations and actual usage. Reservations never reduce `package_balances.lessons_remaining`: the latter still counts only actual completed/charged-cancellation usage.

For **4 remaining paid slots and 8 new weekly lessons**, with those slots available and valid on the first four dates, all 8 rows are created: first 4 covered, remaining 4 pending. Balance remains 4 until a covered lesson is consumed. A later valid package of 4 covers the next four eligible pending rows. Free rows are excluded. Deferred database triggers handle supported direct package insertion/activation too; scheduling and package-creation RPCs allocate before returning.

## Migration and security

- Existing package links, consumption flags and timestamps are preserved exactly. Existing package-less rows become `free`, never guessed debt; package-linked waived/cancelled/rescheduled history remains linked and retains its old financial behavior.
- Reschedules retain original rows and create new concrete replacements. Allocation waits until all old/replacement writes finish. Existing no-op, idempotency, conflict, DST, assignment and authorization checks remain.
- Completed pending lessons can receive coverage later. Cancelled, literal `no_show`, and rescheduled historical pending rows are not retroactively billed; existing cancellation decisions and literal `no_show` non-consumption remain unchanged.
- RLS policies and existing policy-helper grants are unchanged. The new status column receives only SELECT under existing RLS. Allocation/trigger helpers are private and not executable by clients.
- A transaction-level advisory ordering gate precedes lesson/package writes and RPC row locks. Allocation additionally locks packages by ID and pending rows by scheduled time/ID. This deliberately serializes billing mutations across the small school to avoid deadlocks between renewal, completion and rescheduling. Reads remain concurrent. Higher write throughput may later justify per-student coordination; that redesign is outside this fix.
- Already assigned coverage is not automatically evicted/rebalanced. No new payments gateway, refunds or retroactive debt policy is introduced.

## Run checks

Use an isolated Supabase/local PostgreSQL database with all repository migrations, never production. Standard Supabase `auth.uid()` and Auth tables are needed. Plain PostgreSQL test shims can be used for Auth; the upgrade test creates its own shims. The `pg_cron` registration migration can be omitted on plain PostgreSQL; call `private.finalize_due_lessons()` directly in the SQL tests.

```sh
psql "$NONA_TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -f supabase/tests/lesson_billing.sql
psql "$NONA_TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -f supabase/tests/lesson_series.sql
psql "$NONA_TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -f supabase/tests/admin_lesson_statement.sql
node supabase/tests/billing_concurrency.cjs
node supabase/tests/billing_migration.cjs
node supabase/tests/lesson_billing_ui.cjs
```

For the Node concurrency/upgrade tests, `NONA_TEST_DATABASE_URL` must point to localhost and end in `_test`. Set `PSQL_BINARY` if `psql` is not on PATH. Concurrency fixtures use random IDs, are temporarily committed for multiple sessions, then cleaned up. The upgrade test requires local superuser/CREATE DATABASE privileges plus standard Supabase roles (`anon`, `authenticated`, `service_role`); it creates and removes a uniquely named throwaway database.

Browser tests use deterministic Supabase fixtures, stub unrelated chat transport, and contact no production services. Set `PLAYWRIGHT_MODULE` to an externally installed Playwright module and optionally `BROWSER_CHANNEL` (default `msedge`). No build system/dependencies are added to this static site.

## Manual review / deployment

1. In a test environment, give an assigned student 4 available package slots. As their teacher, schedule 8 weekly lessons with the paid checkbox selected. Saving succeeds and the confirmation reports 4 covered / 4 pending.
2. Open weekly details and journal Records: covered, pending and free lessons have distinct Ukrainian labels. As the student, verify pending scheduled lessons remain visible.
3. Add a valid package of 4 through the admin form; refresh and verify the oldest eligible pending lessons are covered. A deliberately free lesson stays free.
4. Reschedule one covered and one pending occurrence, then edit the future subset of a mixed series. Verify history, dates and coverage after refresh.
5. Review and apply the new migration in one transaction to a **test** Supabase project before deploying these frontend assets there. Production migration and merge require the owner's separate instruction. Deploy schema before the new frontend selects `billing_status`; refresh already-open teacher/admin tabs so older forms do not reinterpret a new pending lesson as free.

Automated checks executed for this change: PostgreSQL 17.11 isolated database replay of repository migrations (Auth shims; cron registration omitted), all three SQL suites, real multi-session concurrency, upgrade preservation, and browser fixtures at 1440/390 px. Live Supabase Auth/Realtime, cron service scheduling and production migration were not exercised. Production advisors were read-only checks of the current production schema, not a scan of this unmerged schema.

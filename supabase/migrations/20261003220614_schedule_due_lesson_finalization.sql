-- Database-side scheduler: works even when no browser is open.
create extension if not exists pg_cron with schema pg_catalog;

select cron.schedule(
  'nona-finalize-due-lessons',
  '*/5 * * * *',
  'select private.finalize_due_lessons();'
);

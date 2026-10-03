-- Supabase Postgres Changes publication; no duplicate entries on rerun.
do $$
declare table_name text;
begin
  if not exists (select 1 from pg_catalog.pg_publication where pubname = 'supabase_realtime') then
    execute 'create publication supabase_realtime';
  end if;
  for table_name in select unnest(array['messages', 'notifications', 'lessons']) loop
    if not exists (select 1 from pg_catalog.pg_publication where pubname = 'supabase_realtime' and puballtables)
      and not exists (select 1 from pg_catalog.pg_publication_tables
        where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = table_name) then
      execute format('alter publication supabase_realtime add table public.%I', table_name);
    end if;
  end loop;
end;
$$;

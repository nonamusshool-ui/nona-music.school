-- Admin inbox and FK maintenance look up conversations by explicit admin.
create index conversations_admin_idx on public.conversations (admin_id)
where admin_id is not null;

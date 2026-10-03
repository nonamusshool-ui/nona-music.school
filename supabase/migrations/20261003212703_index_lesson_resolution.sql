create index lessons_resolved_by_idx
  on public.lessons(resolved_by) where resolved_by is not null;

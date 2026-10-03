revoke all on function public.rls_auto_enable()
from public, anon, authenticated;

create index lesson_packages_created_by_idx
on public.lesson_packages(created_by)
where created_by is not null;

create index lessons_created_by_idx
on public.lessons(created_by)
where created_by is not null;

create index lessons_package_student_idx
on public.lessons(package_id, student_id)
where package_id is not null;

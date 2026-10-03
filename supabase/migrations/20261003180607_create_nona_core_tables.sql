create schema if not exists private;
revoke all on schema private from public, anon, authenticated;
grant usage on schema private to authenticated;

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text,
  phone text,
  avatar_url text,
  role text check (role in ('student', 'teacher', 'admin')),
  status text not null default 'pending' check (status in ('pending', 'active', 'suspended')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.teacher_students (
  teacher_id uuid not null references public.profiles(id),
  student_id uuid not null references public.profiles(id),
  active boolean not null default true,
  assigned_at timestamptz not null default now(),
  primary key (teacher_id, student_id),
  constraint teacher_students_distinct_people check (teacher_id <> student_id)
);

create table public.lesson_packages (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.profiles(id),
  lessons_purchased integer not null check (lessons_purchased > 0),
  status text not null default 'active' check (status in ('active', 'used', 'expired', 'cancelled')),
  valid_from date,
  valid_until date,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint lesson_packages_dates check (valid_until is null or valid_from is null or valid_until >= valid_from),
  constraint lesson_packages_id_student_unique unique (id, student_id)
);

create table public.lessons (
  id uuid primary key default gen_random_uuid(),
  package_id uuid,
  student_id uuid not null references public.profiles(id),
  teacher_id uuid not null references public.profiles(id),
  scheduled_at timestamptz not null,
  duration_minutes integer not null default 60 check (duration_minutes between 1 and 480),
  status text not null default 'scheduled' check (status in ('scheduled', 'completed', 'cancelled', 'no_show')),
  consumes_lesson boolean not null default true,
  meet_url text,
  homework text,
  completed_at timestamptz,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint lessons_distinct_people check (student_id <> teacher_id),
  constraint lessons_package_student_fk foreign key (package_id, student_id)
    references public.lesson_packages(id, student_id)
);

create table public.conversations (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.profiles(id),
  teacher_id uuid not null references public.profiles(id),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint conversations_distinct_people check (student_id <> teacher_id),
  constraint conversations_pair_unique unique (student_id, teacher_id)
);

create table public.messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations(id),
  sender_id uuid not null references public.profiles(id),
  body text not null check (char_length(btrim(body)) between 1 and 4000),
  read_at timestamptz,
  created_at timestamptz not null default now(),
  edited_at timestamptz
);

create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id),
  type text not null check (char_length(btrim(type)) between 1 and 100),
  title text,
  body text,
  data jsonb not null default '{}'::jsonb check (jsonb_typeof(data) = 'object'),
  read_at timestamptz,
  created_at timestamptz not null default now()
);

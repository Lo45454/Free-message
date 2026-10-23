create extension if not exists "uuid-ossp";

create table public.profiles (
  id uuid primary key references auth.users on delete cascade,
  username text unique not null,
  display_name text not null,
  created_at timestamptz default now()
);

create table public.conversations (
  id uuid primary key default uuid_generate_v4(),
  created_at timestamptz default now()
);

create table public.conversation_members (
  conversation_id uuid references public.conversations on delete cascade,
  user_id uuid references auth.users on delete cascade,
  primary key (conversation_id, user_id)
);

create table public.messages (
  id uuid primary key default uuid_generate_v4(),
  conversation_id uuid references public.conversations on delete cascade,
  sender_id uuid references auth.users on delete cascade,
  kind text not null default 'text' check (kind in ('text','audio')),
  content text,
  audio_url text,
  created_at timestamptz default now()
);

alter table public.profiles enable row level security;
alter table public.conversations enable row level security;
alter table public.conversation_members enable row level security;
alter table public.messages enable row level security;

create policy "profiles are readable" on public.profiles for select using (true);
create policy "users insert own profile" on public.profiles for insert with check (auth.uid() = id);
create policy "users update own profile" on public.profiles for update using (auth.uid() = id);

create policy "members read conversations" on public.conversations for select using (
  exists (
    select 1 from public.conversation_members m
    where m.conversation_id = id and m.user_id = auth.uid()
  )
);

create policy "members read memberships" on public.conversation_members for select using (
  exists (
    select 1 from public.conversation_members m
    where m.conversation_id = conversation_id and m.user_id = auth.uid()
  )
);

create policy "users create memberships" on public.conversation_members for insert with check (auth.uid() = user_id);

create policy "members read messages" on public.messages for select using (
  exists (
    select 1 from public.conversation_members m
    where m.conversation_id = conversation_id and m.user_id = auth.uid()
  )
);

create policy "members send messages" on public.messages for insert with check (
  auth.uid() = sender_id and exists (
    select 1 from public.conversation_members m
    where m.conversation_id = conversation_id and m.user_id = auth.uid()
  )
);

-- Fonction pour créer ou retrouver une conversation privée
create or replace function public.get_or_create_conversation(other_user uuid)
returns uuid
language plpgsql
security definer
as $$
declare
  me uuid := auth.uid();
  conv uuid;
begin
  if me is null then
    raise exception 'Not authenticated';
  end if;

  select c.id into conv
  from public.conversations c
  join public.conversation_members a on a.conversation_id = c.id and a.user_id = me
  join public.conversation_members b on b.conversation_id = c.id and b.user_id = other_user
  limit 1;

  if conv is not null then
    return conv;
  end if;

  insert into public.conversations default values returning id into conv;

  insert into public.conversation_members(conversation_id, user_id)
  values (conv, me), (conv, other_user);

  return conv;
end;
$$;

grant execute on function public.get_or_create_conversation(uuid) to authenticated;

-- TrueChat : groupes, médias de groupe et signalisation d’appels maillés.
-- Exécuter après le schéma initial et ui-upgrade.sql.

create table if not exists public.conversation_groups (
  conversation_id uuid primary key references public.conversations(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 48),
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now()
);
alter table public.conversation_groups enable row level security;
grant select on public.conversation_groups to authenticated;
drop policy if exists "group members read group metadata" on public.conversation_groups;
create policy "group members read group metadata" on public.conversation_groups
  for select to authenticated using (public.is_conversation_member(conversation_id));

create or replace function public.create_group_conversation(p_group_name text, p_member_ids uuid[])
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_me uuid := auth.uid();
  v_conversation uuid;
  v_count integer;
begin
  if v_me is null then raise exception 'Not authenticated'; end if;
  if p_group_name is null or char_length(btrim(p_group_name)) not between 1 and 48 then
    raise exception 'Le nom du groupe doit contenir de 1 à 48 caractères.';
  end if;
  if p_member_ids is null then raise exception 'Choisis au moins deux contacts.'; end if;
  select count(distinct member_id) into v_count from unnest(p_member_ids) as member_list(member_id) where member_id is not null and member_id <> v_me;
  if v_count < 2 or v_count > 14 then raise exception 'Un groupe doit inclure de 2 à 14 contacts.'; end if;
  if exists (
    select 1 from (select distinct member_id as user_id from unnest(p_member_ids) as member_list(member_id) where member_id is not null and member_id <> v_me) wanted
    where not exists (
      select 1 from public.friendships_v2 f
      where f.status = 'accepted' and ((f.a = v_me and f.b = wanted.user_id) or (f.b = v_me and f.a = wanted.user_id))
    )
  ) then raise exception 'Tous les membres doivent être des contacts acceptés.'; end if;
  insert into public.conversations default values returning id into v_conversation;
  insert into public.conversation_groups(conversation_id, name, created_by)
    values (v_conversation, btrim(p_group_name), v_me);
  insert into public.conversation_members(conversation_id, user_id)
    select v_conversation, v_me
    union select v_conversation, member_id from unnest(p_member_ids) as member_list(member_id) where member_id is not null and member_id <> v_me;
  return v_conversation;
end;
$$;
revoke all on function public.create_group_conversation(text, uuid[]) from public, anon;
grant execute on function public.create_group_conversation(text, uuid[]) to authenticated;

create table if not exists public.group_call_rooms (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  created_by uuid not null references auth.users(id),
  is_video boolean not null default false,
  created_at timestamptz not null default now(),
  closed_at timestamptz
);
create index if not exists group_call_rooms_conversation_created_idx on public.group_call_rooms(conversation_id, created_at desc);
alter table public.group_call_rooms enable row level security;
grant select, insert, update on public.group_call_rooms to authenticated;
drop policy if exists "members read group call rooms" on public.group_call_rooms;
create policy "members read group call rooms" on public.group_call_rooms for select to authenticated
  using (public.is_conversation_member(conversation_id));
drop policy if exists "members start group call rooms" on public.group_call_rooms;
create policy "members start group call rooms" on public.group_call_rooms for insert to authenticated
  with check (created_by = auth.uid() and public.is_conversation_member(conversation_id));
drop policy if exists "creator closes group call rooms" on public.group_call_rooms;
create policy "creator closes group call rooms" on public.group_call_rooms for update to authenticated
  using (created_by = auth.uid() and public.is_conversation_member(conversation_id))
  with check (created_by = auth.uid() and public.is_conversation_member(conversation_id));

create table if not exists public.group_call_participants (
  room_id uuid not null references public.group_call_rooms(id) on delete cascade,
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  last_seen timestamptz not null default now(),
  primary key (room_id, user_id)
);
create index if not exists group_call_participants_room_seen_idx on public.group_call_participants(room_id, last_seen desc);
create or replace function public.enforce_group_call_capacity()
returns trigger language plpgsql security definer set search_path = '' as $capacity$
declare
  v_count integer;
begin
  perform 1 from public.group_call_rooms r where r.id = new.room_id for update;
  if exists (select 1 from public.group_call_participants p where p.room_id = new.room_id and p.user_id = new.user_id) then
    return new;
  end if;
  select count(*) into v_count from public.group_call_participants p
    where p.room_id = new.room_id and p.last_seen >= now() - interval '30 seconds';
  if v_count >= 5 then raise exception 'Les appels de groupe sont limités à cinq participants.'; end if;
  return new;
end;
$capacity$;
revoke all on function public.enforce_group_call_capacity() from public, anon, authenticated;
drop trigger if exists group_call_capacity_guard on public.group_call_participants;
create trigger group_call_capacity_guard before insert on public.group_call_participants
  for each row execute function public.enforce_group_call_capacity();

alter table public.group_call_participants enable row level security;
grant select, insert, update, delete on public.group_call_participants to authenticated;
drop policy if exists "members see group call participants" on public.group_call_participants;
create policy "members see group call participants" on public.group_call_participants for select to authenticated
  using (public.is_conversation_member(conversation_id));
drop policy if exists "members join group calls as self" on public.group_call_participants;
create policy "members join group calls as self" on public.group_call_participants for insert to authenticated
  with check (user_id = auth.uid() and public.is_conversation_member(conversation_id) and exists (
    select 1 from public.group_call_rooms r where r.id = room_id and r.conversation_id = group_call_participants.conversation_id and r.closed_at is null
  ));
drop policy if exists "members update own group call heartbeat" on public.group_call_participants;
create policy "members update own group call heartbeat" on public.group_call_participants for update to authenticated
  using (user_id = auth.uid() and public.is_conversation_member(conversation_id))
  with check (user_id = auth.uid() and public.is_conversation_member(conversation_id));
drop policy if exists "members leave group calls" on public.group_call_participants;
create policy "members leave group calls" on public.group_call_participants for delete to authenticated
  using (user_id = auth.uid() and public.is_conversation_member(conversation_id));

create table if not exists public.group_call_signals (
  id bigint generated always as identity primary key,
  room_id uuid not null references public.group_call_rooms(id) on delete cascade,
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  sender_id uuid not null references auth.users(id) on delete cascade,
  recipient_id uuid not null references auth.users(id) on delete cascade,
  kind text not null check (kind in ('join','offer','answer','ice','leave')),
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists group_call_signals_recipient_id_idx on public.group_call_signals(recipient_id, id);
alter table public.group_call_signals enable row level security;
grant select, insert on public.group_call_signals to authenticated;
drop policy if exists "participants read group call signals" on public.group_call_signals;
create policy "participants read group call signals" on public.group_call_signals for select to authenticated
  using ((recipient_id = auth.uid() or sender_id = auth.uid()) and public.is_conversation_member(conversation_id));
drop policy if exists "members send group call signals" on public.group_call_signals;
create policy "members send group call signals" on public.group_call_signals for insert to authenticated
  with check (sender_id = auth.uid() and sender_id <> recipient_id and public.is_conversation_member(conversation_id)
    and exists (select 1 from public.conversation_members cm where cm.conversation_id = group_call_signals.conversation_id and cm.user_id = recipient_id)
    and exists (select 1 from public.group_call_rooms r where r.id = room_id and r.conversation_id = group_call_signals.conversation_id and r.closed_at is null));

grant usage, select on sequence public.group_call_signals_id_seq to authenticated;

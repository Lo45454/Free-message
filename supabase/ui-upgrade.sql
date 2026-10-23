-- Additive upgrade for the existing Free Message database.
alter table public.profiles add column if not exists avatar_url text;
alter table public.messages drop constraint if exists messages_kind_check;
alter table public.messages add constraint messages_kind_check check (kind in ('text','audio','image','file'));
alter table public.messages add column if not exists file_name text;

-- PostgreSQL table grants are separate from RLS policies. Both are required:
-- the grants let signed-in users call the Data API, while RLS limits which rows
-- they can read or change.
grant usage on schema public to authenticated;
grant select, insert, update on table public.profiles to authenticated;
grant select, insert on table public.messages to authenticated;
grant usage on schema storage to authenticated;
grant select, insert on table storage.objects to authenticated;

-- Check membership without recursively invoking the RLS policy on
-- conversation_members itself. The original schema's membership policies
-- query that same table and can recurse when sending or loading messages.
create or replace function public.is_conversation_member(target_conversation uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.conversation_members cm
    where cm.conversation_id = target_conversation
      and cm.user_id = auth.uid()
  );
$$;
grant execute on function public.is_conversation_member(uuid) to authenticated;

-- Insert attachments through a narrowly scoped RPC. This validates both the
-- signed-in sender and conversation membership before writing the message,
-- avoiding mismatches with pre-existing INSERT policies on older projects.
create or replace function public.send_chat_attachment(
  target_conversation uuid,
  attachment_kind text,
  attachment_path text,
  attachment_name text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  new_message_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;
  if attachment_kind not in ('image','file') then
    raise exception 'Invalid attachment type';
  end if;
  if not public.is_conversation_member(target_conversation) then
    raise exception 'Not a member of this conversation';
  end if;
  insert into public.messages (conversation_id, sender_id, kind, content, file_name)
  values (target_conversation, auth.uid(), attachment_kind, attachment_path, attachment_name)
  returning id into new_message_id;
  return new_message_id;
end;
$$;
grant execute on function public.send_chat_attachment(uuid,text,text,text) to authenticated;

drop policy if exists "members read memberships" on public.conversation_members;
create policy "members read memberships" on public.conversation_members for select to authenticated
using (public.is_conversation_member(conversation_id));
drop policy if exists "members read conversations" on public.conversations;
create policy "members read conversations" on public.conversations for select to authenticated
using (public.is_conversation_member(id));
drop policy if exists "members read messages" on public.messages;
create policy "members read messages" on public.messages for select to authenticated
using (public.is_conversation_member(conversation_id));
drop policy if exists "members send messages" on public.messages;
create policy "members send messages" on public.messages for insert to authenticated
with check (auth.uid() = sender_id and public.is_conversation_member(conversation_id));

-- Keep each profile writable only by its owner.
drop policy if exists "users insert own profile" on public.profiles;
create policy "users insert own profile" on public.profiles for insert to authenticated
with check (auth.uid() = id);
drop policy if exists "users update own profile" on public.profiles;
create policy "users update own profile" on public.profiles for update to authenticated
using (auth.uid() = id) with check (auth.uid() = id);

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('chat-files-v2','chat-files-v2',false,26214400,
  array['image/jpeg','image/png','image/gif','image/webp','image/avif','image/heic','image/heif','image/bmp','application/pdf','text/plain','application/zip','application/vnd.openxmlformats-officedocument.wordprocessingml.document','application/vnd.openxmlformats-officedocument.spreadsheetml.sheet','application/vnd.ms-excel','text/csv'])
on conflict (id) do update set public=false, file_size_limit=excluded.file_size_limit, allowed_mime_types=excluded.allowed_mime_types;
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('profile-avatars-v2','profile-avatars-v2',true,5242880,array['image/jpeg','image/png','image/webp','image/gif','image/avif'])
on conflict (id) do update set public=true, file_size_limit=excluded.file_size_limit, allowed_mime_types=excluded.allowed_mime_types;

drop policy if exists "users upload own avatar" on storage.objects;
create policy "users upload own avatar" on storage.objects for insert to authenticated
with check (bucket_id='profile-avatars-v2' and (storage.foldername(name))[1]=auth.uid()::text);
-- Storage upload returns the inserted object row; allow the uploader to read
-- that row as well, otherwise Storage can reject the upload after INSERT.
drop policy if exists "users read own avatar objects" on storage.objects;
create policy "users read own avatar objects" on storage.objects for select to authenticated
using (bucket_id='profile-avatars-v2' and (storage.foldername(name))[1]=auth.uid()::text);
drop policy if exists "users update own avatar" on storage.objects;
create policy "users update own avatar" on storage.objects for update to authenticated
using (bucket_id='profile-avatars-v2' and (storage.foldername(name))[1]=auth.uid()::text)
with check (bucket_id='profile-avatars-v2' and (storage.foldername(name))[1]=auth.uid()::text);
drop policy if exists "users upload chat files" on storage.objects;
create policy "users upload chat files" on storage.objects for insert to authenticated
with check (bucket_id='chat-files-v2' and (storage.foldername(name))[1]=auth.uid()::text);
drop policy if exists "conversation members read chat files" on storage.objects;
create policy "conversation members read chat files" on storage.objects for select to authenticated using (
 bucket_id='chat-files-v2' and (
  (storage.foldername(name))[1]=auth.uid()::text or
  public.is_conversation_member(((storage.foldername(name))[2])::uuid)
 )
);

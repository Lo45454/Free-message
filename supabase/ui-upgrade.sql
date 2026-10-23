-- Additive upgrade for the existing Free Message database.
alter table public.profiles add column if not exists avatar_url text;
alter table public.messages drop constraint if exists messages_kind_check;
alter table public.messages add constraint messages_kind_check check (kind in ('text','audio','image','file'));

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('chat-files-v2','chat-files-v2',false,26214400,
  array['image/jpeg','image/png','image/gif','image/webp','image/avif','application/pdf','text/plain','application/zip','application/vnd.openxmlformats-officedocument.wordprocessingml.document','application/vnd.openxmlformats-officedocument.spreadsheetml.sheet','application/vnd.ms-excel','text/csv'])
on conflict (id) do update set file_size_limit=excluded.file_size_limit, allowed_mime_types=excluded.allowed_mime_types;
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('profile-avatars-v2','profile-avatars-v2',true,5242880,array['image/jpeg','image/png','image/webp','image/gif'])
on conflict (id) do update set public=true, file_size_limit=excluded.file_size_limit, allowed_mime_types=excluded.allowed_mime_types;

drop policy if exists "users upload own avatar" on storage.objects;
create policy "users upload own avatar" on storage.objects for insert to authenticated with check (bucket_id='profile-avatars-v2' and (storage.foldername(name))[1]=auth.uid()::text);
drop policy if exists "users update own avatar" on storage.objects;
create policy "users update own avatar" on storage.objects for update to authenticated using (bucket_id='profile-avatars-v2' and (storage.foldername(name))[1]=auth.uid()::text);
drop policy if exists "users upload chat files" on storage.objects;
create policy "users upload chat files" on storage.objects for insert to authenticated with check (bucket_id='chat-files-v2' and (storage.foldername(name))[1]=auth.uid()::text);
drop policy if exists "conversation members read chat files" on storage.objects;
create policy "conversation members read chat files" on storage.objects for select to authenticated using (
 bucket_id='chat-files-v2' and exists (
  select 1 from public.conversation_members cm
  where cm.user_id=auth.uid() and cm.conversation_id::text=(storage.foldername(name))[2]
 )
);

alter table public.messages add column if not exists file_name text;

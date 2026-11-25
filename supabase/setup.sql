-- Bizim Hikâyemiz: tam Supabase veritabanı ve özel fotoğraf kurulumu
-- Supabase Dashboard > SQL Editor içinde bu dosyanın tamamını bir kez çalıştırın.
-- Güvenli tekrar çalıştırma için CREATE ... IF NOT EXISTS ve policy yenileme kullanılır.

create extension if not exists pgcrypto;

-- 1) İki kişilik ortak alan
create table if not exists public.app_couples (
  id uuid primary key default gen_random_uuid(),
  invite_code text not null unique,
  created_at timestamptz not null default now()
);

-- Her kullanıcı yalnızca bir ortak alana bağlanır; her ortak alan en fazla iki üyeli olur.
create table if not exists public.app_members (
  couple_id uuid not null references public.app_couples(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (couple_id, user_id),
  unique (user_id)
);

-- Kullanıcı başına, ortak alan ve kayıt türü için tek senkronizasyon satırı.
create table if not exists public.app_items (
  id uuid primary key default gen_random_uuid(),
  couple_id uuid not null references public.app_couples(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  item_type text not null,
  content jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint app_items_couple_user_item_type_key unique (couple_id, user_id, item_type)
);

create index if not exists app_members_couple_id_idx on public.app_members(couple_id);
create index if not exists app_items_couple_id_idx on public.app_items(couple_id);

-- RLS politikalarında güvenli üyelik kontrolü; tablo RLS'sine takılmaması için SECURITY DEFINER.
create or replace function public.app_is_member(p_couple_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.app_members m
    where m.couple_id = p_couple_id and m.user_id = auth.uid()
  );
$$;

-- Ortak alan oluştur: çağıran kullanıcı zaten üyeyse ikinci alan açma.
create or replace function public.create_couple()
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_couple_id uuid;
  v_code text;
begin
  if auth.uid() is null then
    raise exception 'Giriş yapmalısınız.';
  end if;
  if exists (select 1 from public.app_members where user_id = auth.uid()) then
    raise exception 'Bu hesap zaten bir ortak alana bağlı.';
  end if;

  loop
    v_code := upper(encode(gen_random_bytes(6), 'hex'));
    exit when not exists (select 1 from public.app_couples where invite_code = v_code);
  end loop;

  insert into public.app_couples(invite_code) values (v_code)
  returning id into v_couple_id;
  insert into public.app_members(couple_id, user_id) values (v_couple_id, auth.uid());
  return v_couple_id;
end;
$$;

-- Davet koduyla katıl: ortak alanı kilitleyerek üçüncü kişinin eklenmesini önle.
create or replace function public.join_couple(p_invite_code text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_couple_id uuid;
  v_member_count integer;
begin
  if auth.uid() is null then
    raise exception 'Giriş yapmalısınız.';
  end if;
  if exists (select 1 from public.app_members where user_id = auth.uid()) then
    raise exception 'Bu hesap zaten bir ortak alana bağlı.';
  end if;

  select id into v_couple_id
  from public.app_couples
  where invite_code = upper(trim(p_invite_code))
  for update;

  if v_couple_id is null then
    raise exception 'Davet kodu geçersiz.';
  end if;

  select count(*) into v_member_count
  from public.app_members where couple_id = v_couple_id;

  if v_member_count >= 2 then
    raise exception 'Bu ortak alan zaten iki kişiyle dolu.';
  end if;

  insert into public.app_members(couple_id, user_id)
  values (v_couple_id, auth.uid());

  return v_couple_id;
end;
$$;

alter table public.app_couples enable row level security;
alter table public.app_members enable row level security;
alter table public.app_items enable row level security;

drop policy if exists app_couples_member_read on public.app_couples;
create policy app_couples_member_read on public.app_couples
for select to authenticated
using (public.app_is_member(id));

drop policy if exists app_members_self_read on public.app_members;
create policy app_members_self_read on public.app_members
for select to authenticated
using (user_id = auth.uid());

drop policy if exists app_items_member_read on public.app_items;
create policy app_items_member_read on public.app_items
for select to authenticated
using (public.app_is_member(couple_id));

drop policy if exists app_items_owner_insert on public.app_items;
create policy app_items_owner_insert on public.app_items
for insert to authenticated
with check (user_id = auth.uid() and public.app_is_member(couple_id));

drop policy if exists app_items_owner_update on public.app_items;
create policy app_items_owner_update on public.app_items
for update to authenticated
using (user_id = auth.uid() and public.app_is_member(couple_id))
with check (user_id = auth.uid() and public.app_is_member(couple_id));

drop policy if exists app_items_owner_delete on public.app_items;
create policy app_items_owner_delete on public.app_items
for delete to authenticated
using (user_id = auth.uid() and public.app_is_member(couple_id));

grant usage on schema public to authenticated;
grant select on public.app_couples, public.app_members, public.app_items to authenticated;
grant insert, update, delete on public.app_items to authenticated;
grant execute on function public.app_is_member(uuid) to authenticated;
grant execute on function public.create_couple() to authenticated;
grant execute on function public.join_couple(text) to authenticated;

-- 2) Özel fotoğraf deposu (uygulama dosya yolu: couple_id/user_id/file_name)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'couple-photos', 'couple-photos', false, 1572864,
  array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do update
set public = false, file_size_limit = 1572864,
    allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp'];

drop policy if exists couple_photos_member_read on storage.objects;
create policy couple_photos_member_read on storage.objects
for select to authenticated
using (
  bucket_id = 'couple-photos'
  and array_length(storage.foldername(name), 1) = 2
  and case
    when (storage.foldername(name))[1] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    then public.app_is_member(((storage.foldername(name))[1])::uuid)
    else false
  end
);

drop policy if exists couple_photos_owner_upload on storage.objects;
create policy couple_photos_owner_upload on storage.objects
for insert to authenticated
with check (
  bucket_id = 'couple-photos'
  and array_length(storage.foldername(name), 1) = 2
  and case
    when (storage.foldername(name))[1] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
     and (storage.foldername(name))[2] = auth.uid()::text
    then public.app_is_member(((storage.foldername(name))[1])::uuid)
    else false
  end
);

drop policy if exists couple_photos_owner_delete on storage.objects;
create policy couple_photos_owner_delete on storage.objects
for delete to authenticated
using (
  bucket_id = 'couple-photos'
  and array_length(storage.foldername(name), 1) = 2
  and case
    when (storage.foldername(name))[1] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
     and (storage.foldername(name))[2] = auth.uid()::text
    then public.app_is_member(((storage.foldername(name))[1])::uuid)
    else false
  end
);

-- 3) Gerçek zamanlı güncellemeler için tabloyu Realtime yayınına ekle (varsa sessizce geç).
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'app_items'
  ) then
    alter publication supabase_realtime add table public.app_items;
  end if;
exception when undefined_object then
  raise notice 'supabase_realtime yayını bulunamadı; Supabase Realtime ayarlarından app_items tablosunu etkinleştirin.';
end;
$$;

-- Bizim Hikâyemiz: ortak kayıt ve özel fotoğraf depolama kurulumu
-- Supabase SQL Editor içinde bir kez çalıştırın.

-- Aynı kullanıcı/çift/kategori için tek snapshot satırı.
-- Mevcut tabloda tekrar eden satır varsa bu indeks hata verir; şu an app_items boş olduğu bilgisine dayanır.
create unique index if not exists app_items_couple_user_item_type_uidx
on public.app_items (couple_id, user_id, item_type);

-- Fotoğraflar herkese açık olmayan özel bucket içinde tutulur.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'couple-photos',
  'couple-photos',
  false,
  1572864,
  array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do update
set
  public = false,
  file_size_limit = 1572864,
  allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp'];

-- UUID olmayan veya beklenen klasör yapısında olmayan yolları reddet.
-- Dosya yolu: <couple_id>/<user_id>/<file_name>
drop policy if exists "couple_photos_member_read" on storage.objects;
create policy "couple_photos_member_read"
on storage.objects
for select
to authenticated
using (
  bucket_id = 'couple-photos'
  and case
    when (storage.foldername(name))[1] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    then public.app_is_member(((storage.foldername(name))[1])::uuid)
    else false
  end
);

drop policy if exists "couple_photos_owner_upload" on storage.objects;
create policy "couple_photos_owner_upload"
on storage.objects
for insert
to authenticated
with check (
  bucket_id = 'couple-photos'
  and case
    when (storage.foldername(name))[1] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
     and (storage.foldername(name))[2] = auth.uid()::text
    then public.app_is_member(((storage.foldername(name))[1])::uuid)
    else false
  end
);

drop policy if exists "couple_photos_owner_delete" on storage.objects;
create policy "couple_photos_owner_delete"
on storage.objects
for delete
to authenticated
using (
  bucket_id = 'couple-photos'
  and case
    when (storage.foldername(name))[1] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
     and (storage.foldername(name))[2] = auth.uid()::text
    then public.app_is_member(((storage.foldername(name))[1])::uuid)
    else false
  end
);

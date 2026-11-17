-- Imita o mínimo do Supabase Storage (tabelas buckets/objects + RLS) para testar as POLÍTICAS de acesso.
-- NÃO imita a API HTTP do Storage (limite de tamanho, tipo MIME e upload de verdade só valem no Supabase).
create schema storage;
create table storage.buckets (id text primary key, name text, public boolean default false, file_size_limit bigint, allowed_mime_types text[]);
create table storage.objects (id uuid primary key default gen_random_uuid(), bucket_id text references storage.buckets(id), name text, owner uuid default auth.uid(), metadata jsonb, unique (bucket_id, name));
alter table storage.objects enable row level security;
grant usage on schema storage to anon, authenticated, service_role;
grant all on storage.objects, storage.buckets to authenticated, anon, service_role;

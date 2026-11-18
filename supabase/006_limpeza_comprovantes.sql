-- ============================================================
-- 006_limpeza_comprovantes.sql — Limpeza SEGURA de arquivos órfãos do bucket "comprovantes".
-- Ordem: schema.sql -> 002 -> 003 -> 004 -> 005 -> 006. Nada disto foi aplicado no projeto remoto.
--
-- "Órfão" = arquivo no bucket que NÃO está vinculado a nenhum pagamento (upload feito, registro nunca concluído).
-- Regras de segurança:
--  * Só o SERVIDOR executa (papel service_role, ou o dono do banco no SQL Editor). Nenhum usuário do painel chama estas funções.
--  * Período de tolerância (padrão 24 h, mínimo 1 h): uploads recentes/em andamento NUNCA são tocados.
--  * Arquivos vinculados a pagamentos (inclusive de pagamentos estornados) NUNCA são tocados: a lista é sempre "o que não está em comprovantes_pagamento".
--  * Dois passos: (1) reservar (grava em storage_limpeza, e a partir daí o arquivo não pode mais ser vinculado) e (2) apagar pela API do Storage
--    (apagar só a linha de storage.objects por SQL NÃO remove o arquivo físico). O script supabase/ops/limpar_comprovantes_orfaos.js faz os dois passos.
--  * Tudo fica registrado em storage_limpeza (insert/update só pelas funções; sem acesso pelo painel).
-- ============================================================

create table if not exists storage_limpeza (
  caminho text primary key,
  criado_em_arquivo timestamptz,
  reservado_em timestamptz not null default now(),
  removido_em timestamptz,
  status text not null check (status in ('reservado','removido','erro')),
  detalhe text
);
alter table storage_limpeza enable row level security;
revoke all on storage_limpeza from public, anon, authenticated;

create or replace function limpeza_exige_servidor() returns void
language plpgsql stable security definer set search_path = public as $tag_exige_servidor$
begin
  if not (coalesce(auth.role(), '') = 'service_role' or session_user in ('postgres', 'supabase_admin')) then
    raise exception 'Operação restrita ao servidor';
  end if;
end;
$tag_exige_servidor$;

create or replace function comprovantes_orfaos(p_tolerancia interval default interval '24 hours')
returns table (caminho_arquivo text, criado_em_arquivo timestamptz)
language plpgsql stable security definer set search_path = public as $tag_orfaos$
begin
  perform limpeza_exige_servidor();
  if p_tolerancia is null or p_tolerancia < interval '1 hour' then raise exception 'A tolerância mínima é de 1 hora'; end if;
  if to_regclass('storage.objects') is null then return; end if;
  return query execute
    'select o.name::text, o.created_at from storage.objects o
      where o.bucket_id = ''comprovantes'' and o.created_at < now() - $1
        and not exists (select 1 from public.comprovantes_pagamento c where c.storage_path = o.name)
      order by o.created_at' using p_tolerancia;
end;
$tag_orfaos$;

create or replace function reservar_orfaos_comprovantes(p_tolerancia interval default interval '24 hours', p_limite integer default 100)
returns table (caminho_arquivo text, criado_em_arquivo timestamptz)
language plpgsql security definer set search_path = public as $tag_reservar$
begin
  perform limpeza_exige_servidor();
  if p_limite is null or p_limite < 1 or p_limite > 1000 then raise exception 'Limite inválido (1 a 1000)'; end if;
  perform pg_advisory_xact_lock(hashtext('limpeza_comprovantes'));      -- serializa com registrar_comprovante
  return query
    with cand as (
      select o.caminho_arquivo as cam, o.criado_em_arquivo as cri from comprovantes_orfaos(p_tolerancia) o
       where not exists (select 1 from storage_limpeza l where l.caminho = o.caminho_arquivo
                           and (l.status = 'removido' or (l.status = 'reservado' and l.reservado_em > now() - interval '1 hour')))
       order by o.criado_em_arquivo limit p_limite),
    ins as (
      insert into storage_limpeza (caminho, criado_em_arquivo, status)
      select cam, cri, 'reservado' from cand
      on conflict (caminho) do update set status = 'reservado', reservado_em = now(), criado_em_arquivo = excluded.criado_em_arquivo, detalhe = null, removido_em = null
      returning caminho, storage_limpeza.criado_em_arquivo)
    select ins.caminho, ins.criado_em_arquivo from ins;
end;
$tag_reservar$;

create or replace function confirmar_remocao_orfao(p_caminho text, p_ok boolean, p_detalhe text default null) returns void
language plpgsql security definer set search_path = public as $tag_confirmar_remocao$
begin
  perform limpeza_exige_servidor();
  update storage_limpeza set status = case when p_ok then 'removido' else 'erro' end,
         removido_em = case when p_ok then now() else null end, detalhe = left(p_detalhe, 500)
   where caminho = p_caminho and status = 'reservado';
end;
$tag_confirmar_remocao$;

-- registrar_comprovante (005) passa a respeitar a reserva de limpeza
create or replace function registrar_comprovante(p_pagamento_id uuid, p_path text, p_nome text, p_mime text, p_tamanho integer) returns uuid
language plpgsql security definer set search_path = public as $tag_registrar_comprovante$
declare p pagamentos_lancamento%rowtype; v_id uuid; v_prefix text; v_meta jsonb; v_ext text; v_cnt int;
begin
  select * into p from pagamentos_lancamento where id = p_pagamento_id;
  if p.id is null or p.tipo <> 'pagamento' then raise exception 'Pagamento não encontrado'; end if;
  if not tenho_acesso_a_loja(p.loja_id) then raise exception 'Você não tem permissão para esta loja'; end if;
  if exists (select 1 from pagamentos_lancamento where estorno_de = p.id) then raise exception 'Pagamento estornado não recebe comprovante'; end if;
  v_prefix := p.loja_id::text || '/' || p.id::text || '/';
  if p_path is null or left(p_path, length(v_prefix)) <> v_prefix or not pode_enviar_comprovante(p_path) then raise exception 'Caminho do arquivo inválido para este pagamento'; end if;
  v_ext := lower(substring(p_path from '\.([a-z]+)$'));
  if p_mime not in ('application/pdf','image/jpeg','image/png','image/webp') then raise exception 'Tipo de arquivo não permitido (use PDF, JPG, PNG ou WEBP)'; end if;
  if not ((p_mime = 'application/pdf' and v_ext = 'pdf') or (p_mime = 'image/jpeg' and v_ext in ('jpg','jpeg')) or (p_mime = 'image/png' and v_ext = 'png') or (p_mime = 'image/webp' and v_ext = 'webp')) then
    raise exception 'A extensão do arquivo não corresponde ao tipo';
  end if;
  if p_tamanho is null or p_tamanho < 1 or p_tamanho > 5242880 then raise exception 'Arquivo vazio ou maior que 5 MB'; end if;
  -- serializa com a limpeza de órfãos: um arquivo já reservado para remoção não pode mais ser vinculado
  perform pg_advisory_xact_lock(hashtext('limpeza_comprovantes'));
  if exists (select 1 from storage_limpeza where caminho = p_path) then
    raise exception 'Este arquivo foi removido pela limpeza de arquivos não vinculados — envie o comprovante de novo';
  end if;
  select id into v_id from comprovantes_pagamento where storage_path = p_path;
  if v_id is not null then return v_id; end if;                                      -- repetição do mesmo registro
  if (select count(*) from comprovantes_pagamento where pagamento_id = p.id) >= 5 then raise exception 'Limite de 5 arquivos por pagamento'; end if;
  if to_regclass('storage.objects') is not null then                                  -- o arquivo precisa existir de verdade no bucket
    execute 'select count(*)::int, (array_agg(metadata))[1] from storage.objects where bucket_id = $1 and name = $2' into v_cnt, v_meta using 'comprovantes', p_path;
    if v_cnt = 0 then raise exception 'Arquivo ainda não está no armazenamento — envie de novo'; end if;
    if v_meta is not null and ((v_meta->>'size') is not null and (v_meta->>'size')::bigint <> p_tamanho or (v_meta->>'mimetype') is not null and v_meta->>'mimetype' <> p_mime) then
      raise exception 'Tamanho/tipo informado não confere com o arquivo enviado';
    end if;
  end if;
  insert into comprovantes_pagamento (pagamento_id, lancamento_id, loja_id, storage_path, nome_original, mime, tamanho, enviado_por)
  values (p.id, p.lancamento_id, p.loja_id, p_path, left(nullif(trim(coalesce(p_nome, '')), ''), 200), p_mime, p_tamanho, auth.uid()) returning id into v_id;
  perform fin_audit(p.lancamento_id, p.id, p.loja_id, 'comprovante_anexado', null, jsonb_build_object('arquivo', p_path, 'mime', p_mime, 'tamanho', p_tamanho));
  return v_id;
end;
$tag_registrar_comprovante$;

revoke execute on function public.limpeza_exige_servidor(), public.comprovantes_orfaos(interval), public.reservar_orfaos_comprovantes(interval, integer),
  public.confirmar_remocao_orfao(text, boolean, text) from public, anon, authenticated;
grant execute on function public.comprovantes_orfaos(interval), public.reservar_orfaos_comprovantes(interval, integer), public.confirmar_remocao_orfao(text, boolean, text) to service_role;

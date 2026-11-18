-- ============================================================
-- 010_acessos.sql — Gestão de acessos: desativar/reativar pessoas e ajustar lojas SEM apagar histórico.
-- Ordem (nada aplicado no remoto): schema.sql -> 002 -> ... -> 009 -> 010. Não altera catálogo, vendas nem estoque.
--  * perfis.ativo: pessoa desativada continua existindo (vendas, caixas, pagamentos, versões de comunicados e auditorias
--    seguem apontando para ela e mostrando o nome), mas TODAS as funções de acesso passam a negá-la — inclusive chamadas diretas à API
--    com um token ainda válido. Reativar devolve o acesso anterior (as lojas vinculadas são mantidas).
--  * Só o dono (ativo) desativa/reativa e altera lojas; ninguém desativa a si mesmo nem o último dono ativo. Tudo fica em acessos_auditoria.
-- ============================================================
alter table perfis add column if not exists ativo boolean not null default true;
alter table perfis add column if not exists desativado_em timestamptz;
alter table perfis add column if not exists desativado_por uuid references perfis(id);
alter table perfis add column if not exists motivo_desativacao text;
create index if not exists idx_perfis_desativado_por on perfis (desativado_por);

create table if not exists acessos_auditoria (
  id uuid primary key default gen_random_uuid(),
  perfil_id uuid not null references perfis(id),
  acao text not null check (acao in ('desativado','reativado','lojas_alteradas')),
  motivo text,
  detalhes jsonb not null default '{}'::jsonb,
  por uuid not null references perfis(id),
  em timestamptz not null default now()
);
create index if not exists idx_acessos_aud_perfil on acessos_auditoria (perfil_id, em desc);
create index if not exists idx_acessos_aud_por on acessos_auditoria (por);
drop trigger if exists acessos_aud_imutavel on acessos_auditoria;
create trigger acessos_aud_imutavel before update or delete on acessos_auditoria for each row execute function trg_fin_imutavel();
alter table acessos_auditoria enable row level security;
revoke all on acessos_auditoria from public, anon, authenticated;

-- ---------- helpers de acesso (mesmas assinaturas; agora exigem pessoa ativa) ----------
create or replace function perfil_ativo() returns boolean
language sql stable security definer set search_path = public as $tag_perfil_ativo$
  select coalesce((select ativo from perfis where id = auth.uid()), false)
$tag_perfil_ativo$;
create or replace function minhas_lojas() returns setof uuid
language sql stable security definer set search_path = public as $tag_minhas_lojas$
  select loja_id from perfis_lojas where perfil_id = auth.uid() and perfil_ativo()
$tag_minhas_lojas$;
create or replace function tenho_acesso_a_loja(p_loja_id uuid) returns boolean
language sql stable security definer set search_path = public as $tag_tenho_acesso$
  select perfil_ativo() and exists (select 1 from perfis_lojas where perfil_id = auth.uid() and loja_id = p_loja_id)
$tag_tenho_acesso$;
create or replace function eh_da_equipe() returns boolean
language sql stable security definer set search_path = public as $tag_eh_da_equipe$
  select perfil_ativo() and exists (select 1 from perfis_lojas where perfil_id = auth.uid())
$tag_eh_da_equipe$;
create or replace function eh_dono() returns boolean
language sql stable security definer set search_path = public as $tag_eh_dono$
  select coalesce((select papel = 'dono' and ativo from perfis where id = auth.uid()), false)
$tag_eh_dono$;
create or replace function eh_gerente() returns boolean
language sql stable security definer set search_path = public as $tag_eh_gerente$
  select exists (select 1 from perfis where id = auth.uid() and ativo and papel in ('gerente','dono'))
$tag_eh_gerente$;

-- políticas que consultavam "perfis" direto agora usam o helper (que respeita ativo); mesma regra de papel
do $mig$
declare r record;
begin
  -- só reescreve políticas que EXISTEM (a 002 pode ter removido as de escrita direta no estoque — não são recriadas)
  for r in select tablename, policyname, cmd from pg_policies where schemaname = 'public' and (qual like '%perfis%papel%' or with_check like '%perfis%papel%') loop
    execute format('drop policy %I on %I', r.policyname, r.tablename);
    execute format('create policy %I on %I for %s %s', r.policyname, r.tablename, case r.cmd when 'ALL' then 'all' else lower(r.cmd) end,
                   case r.cmd when 'INSERT' then 'with check (eh_gerente())' else 'using (eh_gerente())' end);
  end loop;
  drop policy if exists "leitura propria" on perfis_lojas;
  create policy "leitura propria" on perfis_lojas for select using (perfil_id = auth.uid() and perfil_ativo());
end
$mig$;

-- ---------- administração de pessoas (só dono) ----------
create or replace function listar_pessoas() returns jsonb
language plpgsql stable security definer set search_path = public as $tag_listar_pessoas$
begin
  if not eh_dono() then raise exception 'Só o administrador geral gerencia acessos'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'usuario', split_part(u.email, '@', 1), 'nome', p.nome, 'papel', p.papel, 'ativo', p.ativo,
      'desativado_em', p.desativado_em, 'desativado_por_nome', (select nome from perfis where id = p.desativado_por), 'motivo', p.motivo_desativacao,
      'lojas', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'nome', l.nome) order by l.nome) from perfis_lojas pl join lojas l on l.id = pl.loja_id where pl.perfil_id = p.id), '[]'::jsonb))
      order by p.ativo desc, p.nome), '[]'::jsonb)
    from perfis p left join auth.users u on u.id = p.id);
end;
$tag_listar_pessoas$;

create or replace function definir_acesso_pessoa(p_perfil uuid, p_ativo boolean, p_motivo text default null) returns void
language plpgsql security definer set search_path = public as $tag_definir_acesso$
declare p perfis%rowtype;
begin
  if not eh_dono() then raise exception 'Só o administrador geral gerencia acessos'; end if;
  perform pg_advisory_xact_lock(hashtext('acessos'));
  select * into p from perfis where id = p_perfil for update;
  if p.id is null then raise exception 'Pessoa não encontrada'; end if;
  if p_ativo is null then raise exception 'Informe se o acesso fica ativo'; end if;
  if p.ativo = p_ativo then return; end if;
  if not p_ativo then
    if p.id = auth.uid() then raise exception 'Você não pode desativar o seu próprio acesso'; end if;
    if length(trim(coalesce(p_motivo, ''))) < 3 then raise exception 'Informe o motivo da desativação'; end if;
    if p.papel = 'dono' and not exists (select 1 from perfis where papel = 'dono' and ativo and id <> p.id) then raise exception 'Não é possível desativar o último administrador geral'; end if;
  end if;
  update perfis set ativo = p_ativo, desativado_em = case when p_ativo then null else now() end, desativado_por = case when p_ativo then null else auth.uid() end,
         motivo_desativacao = case when p_ativo then null else trim(p_motivo) end where id = p.id;
  insert into acessos_auditoria (perfil_id, acao, motivo, por) values (p.id, case when p_ativo then 'reativado' else 'desativado' end, nullif(trim(coalesce(p_motivo, '')), ''), auth.uid());
end;
$tag_definir_acesso$;

create or replace function definir_lojas_pessoa(p_perfil uuid, p_lojas uuid[]) returns void
language plpgsql security definer set search_path = public as $tag_definir_lojas$
declare v_ant uuid[]; v_novas uuid[] := array(select distinct x from unnest(coalesce(p_lojas, '{}'::uuid[])) x);
begin
  if not eh_dono() then raise exception 'Só o administrador geral gerencia acessos'; end if;
  perform pg_advisory_xact_lock(hashtext('acessos'));
  if not exists (select 1 from perfis where id = p_perfil) then raise exception 'Pessoa não encontrada'; end if;
  if coalesce(array_length(v_novas, 1), 0) = 0 then raise exception 'A pessoa precisa ter pelo menos uma loja (para bloquear o acesso, desative-a)'; end if;
  if exists (select 1 from unnest(v_novas) l where not exists (select 1 from lojas where id = l)) then raise exception 'Loja inválida'; end if;
  v_ant := array(select loja_id from perfis_lojas where perfil_id = p_perfil);
  delete from perfis_lojas where perfil_id = p_perfil and not (loja_id = any(v_novas));
  insert into perfis_lojas (perfil_id, loja_id) select p_perfil, l from unnest(v_novas) l on conflict do nothing;
  insert into acessos_auditoria (perfil_id, acao, detalhes, por) values (p_perfil, 'lojas_alteradas', jsonb_build_object('antes', to_jsonb(v_ant), 'depois', to_jsonb(v_novas)), auth.uid());
end;
$tag_definir_lojas$;

revoke execute on function public.listar_pessoas(), public.definir_acesso_pessoa(uuid, boolean, text), public.definir_lojas_pessoa(uuid, uuid[]) from public, anon;
revoke execute on function public.perfil_ativo() from public, anon;

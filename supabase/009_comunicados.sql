-- ============================================================
-- 009_comunicados.sql — Área "Comunicados": editor de comunicados administrativos (título, cabeçalho, corpo, rodapé),
-- rascunhos POR LOJA, histórico de versões com restauração e publicação como AVISO INTERNO.
-- Ordem (nada foi aplicado no projeto remoto): schema.sql -> 002 -> ... -> 008 -> 009. Não toca em catálogo, produtos, preços, estoque, pedidos, vendas.
--
-- REAPROVEITA os avisos: publicar chama o mesmo publicar_aviso() (prioridade, validade, destaque, leitura individual, "atualizado");
-- republicar atualiza o MESMO aviso (nova versão do aviso); despublicar usa arquivar_aviso(). Nenhuma tabela de aviso é duplicada.
-- TEXTO PURO: o servidor guarda exatamente o que foi digitado (só normaliza quebras de linha para \n). Nada é interpretado como HTML/JS;
-- a tela escapa o conteúdo antes de aplicar a formatação estilo WhatsApp (*negrito* _itálico_ ~tachado~ ```mono```).
-- PERMISSÕES (no servidor): dono acessa todas as lojas; gerente publica/despublica só em lojas que administra; operador vê e edita rascunhos das
-- lojas a que tem acesso, mas NÃO publica. Quem não tem acesso à loja não vê nem edita. Autor e data de cada versão ficam registrados.
-- Mensagem = cabeçalho + corpo + rodapé (blocos não vazios separados por uma linha em branco); o título é o título do aviso/rascunho.
-- ============================================================

create table if not exists comunicados (
  id uuid primary key default gen_random_uuid(),
  loja_id uuid not null references lojas(id),
  titulo text not null check (length(trim(titulo)) between 3 and 120),
  cabecalho text not null default '' check (length(cabecalho) <= 400),
  corpo text not null default '' check (length(corpo) <= 2000),
  rodape text not null default '' check (length(rodape) <= 400),
  status text not null default 'rascunho' check (status in ('rascunho','publicado')),
  versao integer not null default 1,
  aviso_id uuid references avisos(id),
  publicado_versao integer,
  publicado_por uuid references perfis(id),
  publicado_em timestamptz,
  criado_por uuid not null references perfis(id),
  criado_em timestamptz not null default now(),
  atualizado_por uuid not null references perfis(id),
  atualizado_em timestamptz not null default now(),
  chave_criacao uuid not null,
  constraint uq_comunicado_chave unique (criado_por, chave_criacao)
);
create index if not exists idx_comunicados_loja on comunicados (loja_id, atualizado_em desc);
create index if not exists idx_comunicados_aviso on comunicados (aviso_id);
create index if not exists idx_comunicados_atualizado_por on comunicados (atualizado_por);
create index if not exists idx_comunicados_publicado_por on comunicados (publicado_por);

create table if not exists comunicados_versoes (
  id uuid primary key default gen_random_uuid(),
  comunicado_id uuid not null references comunicados(id),
  versao integer not null,
  acao text not null check (acao in ('criado','editado','restaurado','publicado','despublicado')),
  titulo text not null,
  cabecalho text not null default '',
  corpo text not null default '',
  rodape text not null default '',
  restaurado_de integer,
  detalhes jsonb not null default '{}'::jsonb,
  por uuid not null references perfis(id),
  em timestamptz not null default now()
);
create index if not exists idx_com_versoes on comunicados_versoes (comunicado_id, versao, em);
create index if not exists idx_com_versoes_por on comunicados_versoes (por);

drop trigger if exists comunicados_versoes_imutavel on comunicados_versoes;
create trigger comunicados_versoes_imutavel before update or delete on comunicados_versoes for each row execute function trg_fin_imutavel();

create or replace function trg_comunicado_guard() returns trigger
language plpgsql set search_path = public as $tag_trg_comunicado$
begin
  if tg_op = 'DELETE' then raise exception 'Comunicado não pode ser apagado — o histórico é preservado'; end if;
  if coalesce(current_setting('app.comunicado_op', true), '') <> '1' then raise exception 'Comunicado só pode ser alterado pelas funções de salvar/restaurar/publicar'; end if;
  if new.loja_id <> old.loja_id then raise exception 'A loja do comunicado não pode ser alterada'; end if;
  return new;
end;
$tag_trg_comunicado$;
drop trigger if exists comunicados_guard on comunicados;
create trigger comunicados_guard before update or delete on comunicados for each row execute function trg_comunicado_guard();

-- Mensagem composta: blocos não vazios, separados por uma linha em branco (idêntica ao que a tela mostra/copia e ao texto do aviso).
create or replace function comunicado_compor(p_cabecalho text, p_corpo text, p_rodape text) returns text
language sql immutable set search_path = public as $tag_comunicado_compor$
  select coalesce(array_to_string(array(select b from unnest(array[p_cabecalho, p_corpo, p_rodape]) b where b <> ''), E'\n\n'), '')
$tag_comunicado_compor$;

create or replace function comunicado_pode_editar(p_loja uuid) returns boolean
language sql stable security definer set search_path = public as $tag_com_pode_editar$ select eh_dono() or tenho_acesso_a_loja(p_loja) $tag_com_pode_editar$;
create or replace function comunicado_pode_publicar(p_loja uuid) returns boolean
language sql stable security definer set search_path = public as $tag_com_pode_publicar$ select eh_dono() or pode_gerir_loja(p_loja) $tag_com_pode_publicar$;

-- normaliza um bloco: \r\n -> \n; bloco só de espaços vira vazio; fora isso, EXATAMENTE como digitado
create or replace function comunicado_bloco(p_texto text) returns text
language sql immutable set search_path = public as $tag_comunicado_bloco$
  select case when trim(replace(replace(coalesce(p_texto, ''), E'\r\n', E'\n'), E'\r', E'\n'), E' \n\t') = '' then '' else replace(replace(coalesce(p_texto, ''), E'\r\n', E'\n'), E'\r', E'\n') end
$tag_comunicado_bloco$;

create or replace function salvar_comunicado(p_id uuid, p_loja_id uuid, p_titulo text, p_cabecalho text, p_corpo text, p_rodape text, p_versao_base integer, p_chave uuid) returns jsonb
language plpgsql security definer set search_path = public as $tag_salvar_comunicado$
declare c comunicados%rowtype; v_tit text := trim(coalesce(p_titulo, '')); v_cab text := comunicado_bloco(p_cabecalho); v_cor text := comunicado_bloco(p_corpo); v_rod text := comunicado_bloco(p_rodape); v_id uuid;
begin
  if length(v_tit) < 3 or length(v_tit) > 120 then raise exception 'O título precisa ter de 3 a 120 caracteres'; end if;
  if length(v_cab) > 400 then raise exception 'O cabeçalho passa de 400 caracteres'; end if;
  if length(v_rod) > 400 then raise exception 'O rodapé passa de 400 caracteres'; end if;
  if length(v_cor) > 2000 then raise exception 'O corpo passa de 2000 caracteres'; end if;
  if length(comunicado_compor(v_cab, v_cor, v_rod)) > 2000 then raise exception 'A mensagem (cabeçalho + corpo + rodapé) passa de 2000 caracteres'; end if;
  if p_id is null then
    if p_loja_id is null or not comunicado_pode_editar(p_loja_id) then raise exception 'Você não tem permissão para esta loja'; end if;
    if p_chave is null then raise exception 'Chave de repetição obrigatória'; end if;
    perform pg_advisory_xact_lock(hashtext('comunicado:' || auth.uid()::text || p_chave::text));
    select id into v_id from comunicados where criado_por = auth.uid() and chave_criacao = p_chave;
    if v_id is not null then select * into c from comunicados where id = v_id; return jsonb_build_object('id', c.id, 'versao', c.versao, 'atualizado_em', c.atualizado_em, 'repetido', true); end if;
    perform set_config('app.comunicado_op', '1', true);
    insert into comunicados (loja_id, titulo, cabecalho, corpo, rodape, criado_por, atualizado_por, chave_criacao) values (p_loja_id, v_tit, v_cab, v_cor, v_rod, auth.uid(), auth.uid(), p_chave) returning * into c;
    insert into comunicados_versoes (comunicado_id, versao, acao, titulo, cabecalho, corpo, rodape, por) values (c.id, 1, 'criado', v_tit, v_cab, v_cor, v_rod, auth.uid());
    return jsonb_build_object('id', c.id, 'versao', 1, 'atualizado_em', c.atualizado_em, 'repetido', false);
  end if;
  select * into c from comunicados where id = p_id for update;
  if c.id is null then raise exception 'Comunicado não encontrado'; end if;
  if not comunicado_pode_editar(c.loja_id) then raise exception 'Você não tem permissão para esta loja'; end if;
  if p_versao_base is distinct from c.versao then
    raise exception 'Este comunicado foi alterado por outra pessoa (versão atual %). Recarregue antes de salvar.', c.versao;
  end if;
  if v_tit = c.titulo and v_cab = c.cabecalho and v_cor = c.corpo and v_rod = c.rodape then
    return jsonb_build_object('id', c.id, 'versao', c.versao, 'atualizado_em', c.atualizado_em, 'sem_mudanca', true);
  end if;
  perform set_config('app.comunicado_op', '1', true);
  update comunicados set titulo = v_tit, cabecalho = v_cab, corpo = v_cor, rodape = v_rod, versao = versao + 1, atualizado_por = auth.uid(), atualizado_em = now() where id = c.id returning * into c;
  insert into comunicados_versoes (comunicado_id, versao, acao, titulo, cabecalho, corpo, rodape, por) values (c.id, c.versao, 'editado', v_tit, v_cab, v_cor, v_rod, auth.uid());
  return jsonb_build_object('id', c.id, 'versao', c.versao, 'atualizado_em', c.atualizado_em, 'sem_mudanca', false);
end;
$tag_salvar_comunicado$;

create or replace function restaurar_comunicado(p_id uuid, p_versao integer, p_versao_base integer) returns jsonb
language plpgsql security definer set search_path = public as $tag_restaurar_comunicado$
declare c comunicados%rowtype; v comunicados_versoes%rowtype;
begin
  select * into c from comunicados where id = p_id for update;
  if c.id is null then raise exception 'Comunicado não encontrado'; end if;
  if not comunicado_pode_editar(c.loja_id) then raise exception 'Você não tem permissão para esta loja'; end if;
  if p_versao_base is distinct from c.versao then raise exception 'Este comunicado foi alterado por outra pessoa (versão atual %). Recarregue antes de restaurar.', c.versao; end if;
  select * into v from comunicados_versoes where comunicado_id = c.id and versao = p_versao and acao in ('criado','editado','restaurado') order by em limit 1;
  if v.id is null then raise exception 'Versão não encontrada'; end if;
  if v.titulo = c.titulo and v.cabecalho = c.cabecalho and v.corpo = c.corpo and v.rodape = c.rodape then raise exception 'Esta versão já é o conteúdo atual'; end if;
  perform set_config('app.comunicado_op', '1', true);
  update comunicados set titulo = v.titulo, cabecalho = v.cabecalho, corpo = v.corpo, rodape = v.rodape, versao = versao + 1, atualizado_por = auth.uid(), atualizado_em = now() where id = c.id returning * into c;
  insert into comunicados_versoes (comunicado_id, versao, acao, titulo, cabecalho, corpo, rodape, restaurado_de, por) values (c.id, c.versao, 'restaurado', v.titulo, v.cabecalho, v.corpo, v.rodape, p_versao, auth.uid());
  return jsonb_build_object('id', c.id, 'versao', c.versao, 'restaurado_de', p_versao);
end;
$tag_restaurar_comunicado$;

-- Publicar = criar/atualizar o AVISO INTERNO desta loja (mesmo mecanismo dos avisos: prioridade, validade, leitura individual, "atualizado").
create or replace function publicar_comunicado(p_id uuid, p_prioridade text, p_valido_ate timestamptz, p_destaque boolean, p_global boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $tag_publicar_comunicado$
declare c comunicados%rowtype; v_texto text; v_aviso uuid;
begin
  select * into c from comunicados where id = p_id for update;
  if c.id is null then raise exception 'Comunicado não encontrado'; end if;
  if not comunicado_pode_publicar(c.loja_id) then raise exception 'Só gerente da loja ou dono publica comunicados'; end if;
  v_texto := comunicado_compor(c.cabecalho, c.corpo, c.rodape);
  if v_texto = '' then raise exception 'Escreva o texto (cabeçalho, corpo ou rodapé) antes de publicar'; end if;
  v_aviso := publicar_aviso(c.aviso_id, 'comunicado', c.titulo, v_texto, p_prioridade, coalesce(p_destaque, false), p_valido_ate, coalesce(p_global, false),
                            case when coalesce(p_global, false) then '{}'::uuid[] else array[c.loja_id] end);
  perform set_config('app.comunicado_op', '1', true);
  update comunicados set status = 'publicado', aviso_id = v_aviso, publicado_versao = c.versao, publicado_por = auth.uid(), publicado_em = now() where id = c.id;
  insert into comunicados_versoes (comunicado_id, versao, acao, titulo, cabecalho, corpo, rodape, detalhes, por)
  values (c.id, c.versao, 'publicado', c.titulo, c.cabecalho, c.corpo, c.rodape, jsonb_build_object('aviso_id', v_aviso, 'prioridade', p_prioridade, 'valido_ate', p_valido_ate, 'global', coalesce(p_global, false)), auth.uid());
  return jsonb_build_object('id', c.id, 'aviso_id', v_aviso, 'publicado_versao', c.versao);
end;
$tag_publicar_comunicado$;

create or replace function despublicar_comunicado(p_id uuid) returns void
language plpgsql security definer set search_path = public as $tag_despublicar_comunicado$
declare c comunicados%rowtype;
begin
  select * into c from comunicados where id = p_id for update;
  if c.id is null then raise exception 'Comunicado não encontrado'; end if;
  if not comunicado_pode_publicar(c.loja_id) then raise exception 'Só gerente da loja ou dono despublica comunicados'; end if;
  if c.status <> 'publicado' or c.aviso_id is null then raise exception 'Este comunicado não está publicado'; end if;
  perform arquivar_aviso(c.aviso_id);
  perform set_config('app.comunicado_op', '1', true);
  update comunicados set status = 'rascunho' where id = c.id;
  insert into comunicados_versoes (comunicado_id, versao, acao, titulo, cabecalho, corpo, rodape, detalhes, por)
  values (c.id, c.versao, 'despublicado', c.titulo, c.cabecalho, c.corpo, c.rodape, jsonb_build_object('aviso_id', c.aviso_id), auth.uid());
end;
$tag_despublicar_comunicado$;

create or replace function listar_comunicados(p_loja_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $tag_listar_comunicados$
begin
  if p_loja_id is null or not pode_ver_loja(p_loja_id) then raise exception 'Você não tem permissão para esta loja'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'loja_id', c.loja_id, 'titulo', c.titulo, 'status', c.status, 'versao', c.versao, 'publicado_versao', c.publicado_versao,
            'alteracoes_nao_publicadas', c.status = 'publicado' and c.versao > coalesce(c.publicado_versao, 0), 'aviso_id', c.aviso_id,
            'previa', left(comunicado_compor(c.cabecalho, c.corpo, c.rodape), 140), 'criado_por_nome', (select nome from perfis where id = c.criado_por), 'criado_em', c.criado_em,
            'atualizado_por_nome', (select nome from perfis where id = c.atualizado_por), 'atualizado_em', c.atualizado_em,
            'pode_editar', comunicado_pode_editar(c.loja_id), 'pode_publicar', comunicado_pode_publicar(c.loja_id)) order by c.atualizado_em desc), '[]'::jsonb)
          from comunicados c where c.loja_id = p_loja_id);
end;
$tag_listar_comunicados$;

create or replace function comunicado_detalhe(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $tag_comunicado_detalhe$
declare c comunicados%rowtype; a avisos%rowtype;
begin
  select * into c from comunicados where id = p_id;
  if c.id is null or not pode_ver_loja(c.loja_id) then raise exception 'Comunicado não encontrado ou sem permissão'; end if;
  select * into a from avisos where id = c.aviso_id;
  return jsonb_build_object(
    'comunicado', jsonb_build_object('id', c.id, 'loja_id', c.loja_id, 'loja_nome', (select nome from lojas where id = c.loja_id), 'titulo', c.titulo, 'cabecalho', c.cabecalho, 'corpo', c.corpo, 'rodape', c.rodape,
        'status', c.status, 'versao', c.versao, 'publicado_versao', c.publicado_versao, 'alteracoes_nao_publicadas', c.status = 'publicado' and c.versao > coalesce(c.publicado_versao, 0),
        'criado_por_nome', (select nome from perfis where id = c.criado_por), 'criado_em', c.criado_em, 'atualizado_por_nome', (select nome from perfis where id = c.atualizado_por), 'atualizado_em', c.atualizado_em,
        'publicado_por_nome', (select nome from perfis where id = c.publicado_por), 'publicado_em', c.publicado_em,
        'pode_editar', comunicado_pode_editar(c.loja_id), 'pode_publicar', comunicado_pode_publicar(c.loja_id),
        'aviso', case when a.id is null then null else jsonb_build_object('id', a.id, 'ativo', a.ativo, 'prioridade', a.prioridade, 'valido_ate', a.valido_ate, 'destaque', a.destaque, 'global', a.global, 'versao', a.versao) end),
    'versoes', (select coalesce(jsonb_agg(jsonb_build_object('versao', v.versao, 'acao', v.acao, 'titulo', v.titulo, 'cabecalho', v.cabecalho, 'corpo', v.corpo, 'rodape', v.rodape, 'restaurado_de', v.restaurado_de,
                  'detalhes', v.detalhes, 'por_nome', (select nome from perfis where id = v.por), 'em', v.em) order by v.em desc, v.versao desc), '[]'::jsonb) from comunicados_versoes v where v.comunicado_id = c.id));
end;
$tag_comunicado_detalhe$;

alter table comunicados enable row level security;
alter table comunicados_versoes enable row level security;
revoke all on comunicados, comunicados_versoes from public, anon, authenticated;
revoke execute on function public.trg_comunicado_guard(), public.comunicado_compor(text, text, text), public.comunicado_bloco(text), public.comunicado_pode_editar(uuid), public.comunicado_pode_publicar(uuid) from public, anon, authenticated;
revoke execute on function public.salvar_comunicado(uuid, uuid, text, text, text, text, integer, uuid), public.restaurar_comunicado(uuid, integer, integer),
  public.publicar_comunicado(uuid, text, timestamptz, boolean, boolean), public.despublicar_comunicado(uuid), public.listar_comunicados(uuid), public.comunicado_detalhe(uuid) from public, anon;

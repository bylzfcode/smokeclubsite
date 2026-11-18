-- ============================================================
-- 012_calendario.sql — Calendário administrativo: vencimentos de contas (exclusivas e compartilhadas) + compromissos internos.
-- Ordem (nada aplicado no remoto): schema.sql -> 002 -> ... -> 011 -> 012. Só leitura sobre contas/rateios (NÃO duplica registros: cada
-- evento aponta para a conta/rateio existente, que a tela abre no detalhe financeiro já existente). Compromissos são registros novos,
-- por loja, sem valor financeiro; nada aqui toca vendas, caixa, estoque ou catálogo.
-- Situações: pendente, vencido, quitado, cancelado (compromisso: pendente, vencido = passou e não foi concluído, concluído, cancelado).
-- ============================================================
create table if not exists compromissos (
  id uuid primary key default gen_random_uuid(),
  loja_id uuid not null references lojas(id),
  titulo text not null check (length(trim(titulo)) between 3 and 120),
  data date not null,
  responsavel_id uuid references perfis(id),
  observacao text check (observacao is null or length(observacao) <= 1000),
  status text not null default 'pendente' check (status in ('pendente','concluido','cancelado')),
  versao integer not null default 1,
  criado_por uuid not null references perfis(id),
  criado_em timestamptz not null default now(),
  atualizado_por uuid not null references perfis(id),
  atualizado_em timestamptz not null default now(),
  chave_criacao uuid not null,
  constraint uq_compromisso_chave unique (criado_por, chave_criacao)
);
create index if not exists idx_compromissos_loja_data on compromissos (loja_id, data);
create index if not exists idx_compromissos_resp on compromissos (responsavel_id);
create index if not exists idx_compromissos_criado_por on compromissos (criado_por);
create index if not exists idx_compromissos_atualizado_por on compromissos (atualizado_por);

create table if not exists compromissos_historico (
  id uuid primary key default gen_random_uuid(),
  compromisso_id uuid not null references compromissos(id),
  versao integer not null,
  acao text not null check (acao in ('criado','editado','concluido','cancelado','reaberto')),
  snapshot jsonb not null,
  por uuid not null references perfis(id),
  em timestamptz not null default now()
);
create index if not exists idx_comp_hist on compromissos_historico (compromisso_id, versao);
create index if not exists idx_comp_hist_por on compromissos_historico (por);
drop trigger if exists compromissos_hist_imutavel on compromissos_historico;
create trigger compromissos_hist_imutavel before update or delete on compromissos_historico for each row execute function trg_fin_imutavel();

create or replace function trg_compromisso_guard() returns trigger
language plpgsql set search_path = public as $tag_trg_compromisso$
begin
  if tg_op = 'DELETE' then raise exception 'Compromisso não pode ser apagado — cancele-o (o histórico é preservado)'; end if;
  if coalesce(current_setting('app.compromisso_op', true), '') <> '1' then raise exception 'Compromisso só pode ser alterado pelas funções do calendário'; end if;
  if new.loja_id <> old.loja_id then raise exception 'A loja do compromisso não pode ser alterada'; end if;
  return new;
end;
$tag_trg_compromisso$;
drop trigger if exists compromissos_guard on compromissos;
create trigger compromissos_guard before update or delete on compromissos for each row execute function trg_compromisso_guard();
alter table compromissos enable row level security; alter table compromissos_historico enable row level security;
revoke all on compromissos, compromissos_historico from public, anon, authenticated;

create or replace function compromisso_pode(p_loja uuid) returns boolean
language sql stable security definer set search_path = public as $tag_comp_pode$ select eh_dono() or tenho_acesso_a_loja(p_loja) $tag_comp_pode$;

create or replace function salvar_compromisso(p_id uuid, p_loja_id uuid, p_titulo text, p_data date, p_responsavel uuid, p_observacao text, p_versao_base integer, p_chave uuid) returns jsonb
language plpgsql security definer set search_path = public as $tag_salvar_compromisso$
declare c compromissos%rowtype; v_tit text := trim(coalesce(p_titulo, '')); v_obs text := nullif(trim(coalesce(p_observacao, '')), ''); v_id uuid; v_loja uuid;
begin
  if length(v_tit) < 3 or length(v_tit) > 120 then raise exception 'O título precisa ter de 3 a 120 caracteres'; end if;
  if p_data is null then raise exception 'Informe a data'; end if;
  if v_obs is not null and length(v_obs) > 1000 then raise exception 'A observação passa de 1000 caracteres'; end if;
  if p_id is null then
    v_loja := p_loja_id;
    if v_loja is null or not compromisso_pode(v_loja) then raise exception 'Você não tem permissão para esta loja'; end if;
    if p_chave is null then raise exception 'Chave de repetição obrigatória'; end if;
  else
    select * into c from compromissos where id = p_id for update;
    if c.id is null then raise exception 'Compromisso não encontrado'; end if;
    if not compromisso_pode(c.loja_id) then raise exception 'Você não tem permissão para esta loja'; end if;
    v_loja := c.loja_id;
    if p_versao_base is distinct from c.versao then raise exception 'Este compromisso foi alterado por outra pessoa (versão atual %). Recarregue antes de salvar.', c.versao; end if;
    if c.status = 'cancelado' then raise exception 'Compromisso cancelado não pode ser editado — reabra-o antes'; end if;
  end if;
  if p_responsavel is not null and not exists (select 1 from perfis p where p.id = p_responsavel and p.ativo and (exists (select 1 from perfis_lojas pl where pl.perfil_id = p.id and pl.loja_id = v_loja) or p.papel = 'dono')) then
    raise exception 'O responsável precisa ser uma pessoa ativa com acesso a esta loja';
  end if;
  perform set_config('app.compromisso_op', '1', true);
  if p_id is null then
    perform pg_advisory_xact_lock(hashtext('compromisso:' || auth.uid()::text || p_chave::text));
    select id into v_id from compromissos where criado_por = auth.uid() and chave_criacao = p_chave;
    if v_id is not null then return jsonb_build_object('id', v_id, 'repetida', true); end if;
    insert into compromissos (loja_id, titulo, data, responsavel_id, observacao, criado_por, atualizado_por, chave_criacao)
    values (v_loja, v_tit, p_data, p_responsavel, v_obs, auth.uid(), auth.uid(), p_chave) returning id into v_id;
    insert into compromissos_historico (compromisso_id, versao, acao, snapshot, por) select id, 1, 'criado', to_jsonb(compromissos.*), auth.uid() from compromissos where id = v_id;
    return jsonb_build_object('id', v_id, 'versao', 1, 'repetida', false);
  end if;
  if v_tit = c.titulo and p_data = c.data and p_responsavel is not distinct from c.responsavel_id and v_obs is not distinct from c.observacao then
    return jsonb_build_object('id', c.id, 'versao', c.versao, 'sem_mudanca', true);
  end if;
  update compromissos set titulo = v_tit, data = p_data, responsavel_id = p_responsavel, observacao = v_obs, versao = versao + 1, atualizado_por = auth.uid(), atualizado_em = now() where id = c.id;
  insert into compromissos_historico (compromisso_id, versao, acao, snapshot, por) select id, versao, 'editado', to_jsonb(compromissos.*), auth.uid() from compromissos where id = c.id;
  return jsonb_build_object('id', c.id, 'versao', c.versao + 1, 'sem_mudanca', false);
end;
$tag_salvar_compromisso$;

create or replace function mudar_status_compromisso(p_id uuid, p_status text, p_versao_base integer) returns jsonb
language plpgsql security definer set search_path = public as $tag_mudar_status_comp$
declare c compromissos%rowtype; v_acao text;
begin
  if p_status not in ('pendente','concluido','cancelado') then raise exception 'Situação inválida'; end if;
  select * into c from compromissos where id = p_id for update;
  if c.id is null then raise exception 'Compromisso não encontrado'; end if;
  if not compromisso_pode(c.loja_id) then raise exception 'Você não tem permissão para esta loja'; end if;
  if p_versao_base is distinct from c.versao then raise exception 'Este compromisso foi alterado por outra pessoa (versão atual %). Recarregue antes de salvar.', c.versao; end if;
  if c.status = p_status then return jsonb_build_object('id', c.id, 'versao', c.versao, 'sem_mudanca', true); end if;
  v_acao := case p_status when 'concluido' then 'concluido' when 'cancelado' then 'cancelado' else 'reaberto' end;
  perform set_config('app.compromisso_op', '1', true);
  update compromissos set status = p_status, versao = versao + 1, atualizado_por = auth.uid(), atualizado_em = now() where id = c.id;
  insert into compromissos_historico (compromisso_id, versao, acao, snapshot, por) select id, versao, v_acao, to_jsonb(compromissos.*), auth.uid() from compromissos where id = c.id;
  return jsonb_build_object('id', c.id, 'versao', c.versao + 1, 'sem_mudanca', false);
end;
$tag_mudar_status_comp$;

create or replace function compromisso_detalhe(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $tag_comp_detalhe$
declare c compromissos%rowtype;
begin
  select * into c from compromissos where id = p_id;
  if c.id is null or not pode_ver_loja(c.loja_id) then raise exception 'Compromisso não encontrado ou sem permissão'; end if;
  return jsonb_build_object('id', c.id, 'loja_id', c.loja_id, 'loja_nome', (select nome from lojas where id = c.loja_id), 'titulo', c.titulo, 'data', c.data, 'responsavel_id', c.responsavel_id,
     'responsavel_nome', (select nome from perfis where id = c.responsavel_id), 'observacao', c.observacao, 'status', c.status, 'versao', c.versao, 'pode_editar', compromisso_pode(c.loja_id),
     'criado_por_nome', (select nome from perfis where id = c.criado_por), 'criado_em', c.criado_em, 'atualizado_por_nome', (select nome from perfis where id = c.atualizado_por), 'atualizado_em', c.atualizado_em,
     'historico', (select coalesce(jsonb_agg(jsonb_build_object('versao', h.versao, 'acao', h.acao, 'por_nome', (select nome from perfis where id = h.por), 'em', h.em) order by h.versao desc), '[]'::jsonb) from compromissos_historico h where h.compromisso_id = c.id));
end;
$tag_comp_detalhe$;

-- pessoas que podem ser responsáveis por compromissos de uma loja (ativas, com acesso à loja, ou donos)
create or replace function responsaveis_loja(p_loja_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $tag_responsaveis_loja$
begin
  if not pode_ver_loja(p_loja_id) then raise exception 'Você não tem permissão para esta loja'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'nome', p.nome, 'papel', p.papel) order by p.nome), '[]'::jsonb)
            from perfis p where p.ativo and (p.papel = 'dono' or exists (select 1 from perfis_lojas pl where pl.perfil_id = p.id and pl.loja_id = p_loja_id)));
end;
$tag_responsaveis_loja$;

-- ---------- calendário (só leitura): contas + rateios + compromissos no período ----------
create or replace function calendario_admin(p_loja_id uuid default null, p_inicio date default null, p_fim date default null) returns jsonb
language plpgsql stable security definer set search_path = public as $tag_calendario_admin$
declare v_hoje date := (now() at time zone 'America/Sao_Paulo')::date; v_lojas uuid[]; v_ini date; v_fim date; v_ev jsonb; v_total integer;
begin
  if not (eh_dono() or eh_da_equipe()) then raise exception 'Sem permissão'; end if;
  if p_loja_id is not null and not pode_ver_loja(p_loja_id) then raise exception 'Você não tem permissão para esta loja'; end if;
  v_ini := coalesce(p_inicio, date_trunc('month', v_hoje)::date); v_fim := coalesce(p_fim, (date_trunc('month', v_hoje) + interval '1 month - 1 day')::date);
  if v_ini > v_fim then raise exception 'Período inválido'; end if;
  if v_fim - v_ini > 400 then raise exception 'Período máximo: 400 dias'; end if;
  v_lojas := case when p_loja_id is not null then array[p_loja_id] when eh_dono() then array(select id from lojas where ativo) else array(select minhas_lojas()) end;
  with contas as (
    select 'conta'::text as tipo, l.id, l.vencimento as data, coalesce(l.descricao, l.categoria) as titulo, l.loja_id, lo.nome as loja_nome, l.valor,
           case when l.status = 'cancelada' then 0 else l.valor - pt.pago end as saldo, l.tipo as sentido, l.serie_id is not null as recorrente,
           case when l.status = 'cancelada' then 'cancelado' when l.valor - pt.pago <= 0 then 'quitado' when l.vencimento < v_hoje then 'vencido' else 'pendente' end as situacao,
           (pt.pago > 0 and l.valor - pt.pago > 0 and l.status <> 'cancelada') as parcial, null::text as responsavel_nome, null::text as observacao
      from financeiro_lancamentos l join lojas lo on lo.id = l.loja_id
      cross join lateral (select case when exists (select 1 from pagamentos_lancamento p where p.lancamento_id = l.id) then fin_liquido(l.id) when l.status = 'pago' then l.valor else 0 end as pago) pt
     where l.loja_id = any(v_lojas) and l.vencimento between v_ini and v_fim and l.venda_id is null and lower(l.categoria) not in ('venda','estorno')),
  rats as (
    select 'rateio'::text, r.id, r.vencimento, r.descricao, null::uuid, (select string_agg(x.loja_nome, ', ' order by x.loja_nome) from rateio_posicoes(r.id) x where x.loja_uuid = any(v_lojas) or eh_dono()), r.valor_total,
           case when r.status = 'cancelado' then 0 else r.valor_total - rateio_pago_externo(r.id) end, 'saida'::text, false,
           case when r.status = 'cancelado' then 'cancelado' when rateio_pago_externo(r.id) >= r.valor_total then 'quitado' when r.vencimento < v_hoje then 'vencido' else 'pendente' end,
           (rateio_pago_externo(r.id) > 0 and rateio_pago_externo(r.id) < r.valor_total and r.status <> 'cancelado'), null::text, null::text
      from rateios r
     where r.vencimento between v_ini and v_fim
       and exists (select 1 from rateio_parcelas pa where pa.rateio_id = r.id and pa.versao = r.versao and pa.ativa and pa.loja_id = any(v_lojas))),
  comps as (
    select 'compromisso'::text, c.id, c.data, c.titulo, c.loja_id, lo.nome, null::numeric, null::numeric, null::text, false,
           case when c.status = 'cancelado' then 'cancelado' when c.status = 'concluido' then 'concluido' when c.data < v_hoje then 'vencido' else 'pendente' end, false,
           (select nome from perfis where id = c.responsavel_id), c.observacao
      from compromissos c join lojas lo on lo.id = c.loja_id where c.loja_id = any(v_lojas) and c.data between v_ini and v_fim),
  todos as (select * from contas union all select * from rats union all select * from comps),
  lim as (select * from todos order by 3, 4, 2 limit 800)
  select (select count(*) from todos), coalesce(jsonb_agg(jsonb_build_object('tipo', l.tipo, 'id', l.id, 'data', l.data, 'titulo', l.titulo, 'loja_id', l.loja_id, 'loja_nome', l.loja_nome,
          'valor', l.valor, 'saldo', l.saldo, 'sentido', l.sentido, 'recorrente', l.recorrente, 'situacao', l.situacao, 'parcial', l.parcial, 'responsavel_nome', l.responsavel_nome, 'observacao', l.observacao)
          order by l.data, l.titulo, l.id), '[]'::jsonb) into v_total, v_ev from lim l;
  return jsonb_build_object('inicio', v_ini, 'fim', v_fim, 'hoje', v_hoje, 'total', v_total, 'truncado', v_total > 800, 'eventos', v_ev);
end;
$tag_calendario_admin$;

-- o agendador diário das séries (pg_cron) está configurado? (a tela informa; sem pg_cron a geração acontece ao abrir o Financeiro)
create or replace function series_agendamento() returns jsonb
language plpgsql stable security definer set search_path = public as $tag_series_agendamento$
declare v boolean := false;
begin
  if not perfil_ativo() then raise exception 'Sem permissão'; end if;
  if to_regclass('cron.job') is null then return jsonb_build_object('pg_cron', false, 'configurado', false); end if;
  begin
    execute $q$select exists (select 1 from cron.job where active and command ilike '%gerar_series_pendentes%')$q$ into v;
  exception when others then v := false; end;
  return jsonb_build_object('pg_cron', true, 'configurado', v);
end;
$tag_series_agendamento$;

revoke execute on function public.trg_compromisso_guard(), public.compromisso_pode(uuid) from public, anon, authenticated;
revoke execute on function public.salvar_compromisso(uuid, uuid, text, date, uuid, text, integer, uuid), public.mudar_status_compromisso(uuid, text, integer), public.compromisso_detalhe(uuid),
  public.responsaveis_loja(uuid), public.calendario_admin(uuid, date, date), public.series_agendamento() from public, anon;

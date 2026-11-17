-- ============================================================
-- 003_caixa_avisos.sql — Caixa por loja, histórico financeiro e avisos.
-- Rodar DEPOIS de schema.sql e 002_melhorias.sql. Não altera pedidos, catálogo nem contatos.
-- Preserva tudo que já existe: só cria tabelas/funções novas e 2 colunas opcionais em financeiro_lancamentos.
-- Regras vivem no servidor: as tabelas novas NÃO têm acesso direto (só pelas funções abaixo).
-- Fuso de exibição/dia: America/Sao_Paulo. Valores em centavos exatos (numeric(12,2)).
-- ============================================================

-- ---------- 0) Ajustes mínimos no financeiro (comprovante) ----------
alter table financeiro_lancamentos add column if not exists exige_comprovante boolean not null default false;
alter table financeiro_lancamentos add column if not exists comprovante_enviado_em timestamptz;
create index if not exists idx_fin_comprovante_pend on financeiro_lancamentos (loja_id) where exige_comprovante and comprovante_enviado_em is null;

-- ---------- 1) Permissões auxiliares ----------
create or replace function pode_ver_loja(p_loja_id uuid) returns boolean
language sql stable security definer set search_path = public as $tag_pode_ver$
  select eh_dono() or tenho_acesso_a_loja(p_loja_id)
$tag_pode_ver$;

create or replace function pode_gerir_loja(p_loja_id uuid) returns boolean
language sql stable security definer set search_path = public as $tag_pode_gerir$
  select eh_gerente() and tenho_acesso_a_loja(p_loja_id)
$tag_pode_gerir$;

create or replace function valida_valor(p_valor numeric, p_permite_zero boolean default false) returns numeric
language plpgsql immutable set search_path = public as $tag_valida_valor$
begin
  if p_valor is null or p_valor < 0 or (p_valor = 0 and not p_permite_zero) then
    raise exception 'Informe um valor maior que zero';
  end if;
  if round(p_valor, 2) <> p_valor then
    raise exception 'O valor deve ter no máximo 2 casas decimais (centavos)';
  end if;
  if p_valor > 9999999999 then raise exception 'Valor alto demais'; end if;
  return p_valor;
end;
$tag_valida_valor$;

-- ---------- 2) Tabelas do caixa ----------
create table if not exists caixas (
  id uuid primary key default gen_random_uuid(),
  loja_id uuid not null references lojas(id),
  status text not null default 'aberto' check (status in ('aberto','fechado')),
  saldo_inicial numeric(12,2) not null check (saldo_inicial >= 0),
  observacao_abertura text,
  aberto_por uuid not null references perfis(id),
  aberto_em timestamptz not null default now(),
  fechado_por uuid references perfis(id),
  fechado_em timestamptz,
  janela_fim timestamptz,   -- fim do período de vendas deste caixa (fixado no 1º fechamento; reabrir NÃO estende)
  esperado_dinheiro numeric(12,2),
  valor_conferido numeric(12,2) check (valor_conferido is null or valor_conferido >= 0),
  diferenca numeric(12,2),
  justificativa text,
  reaberturas int not null default 0,
  constraint chk_caixa_fechado check (status = 'aberto' or
    (fechado_em is not null and fechado_por is not null and valor_conferido is not null and esperado_dinheiro is not null and diferenca is not null))
);
-- UM caixa aberto por loja, garantido pelo banco (vale mesmo com cliques/abas simultâneos)
create unique index if not exists uq_caixa_aberto_por_loja on caixas (loja_id) where status = 'aberto';
create index if not exists idx_caixas_loja_data on caixas (loja_id, aberto_em desc);
create index if not exists idx_caixas_aberto_por on caixas (aberto_por);

create table if not exists caixa_movimentos (
  id uuid primary key default gen_random_uuid(),
  caixa_id uuid not null references caixas(id),
  loja_id uuid not null references lojas(id),
  tipo text not null check (tipo in ('entrada','saida','retirada','ajuste','estorno')),
  sentido smallint not null check (sentido in (1,-1)),
  meio text not null default 'dinheiro' check (meio in ('dinheiro','pix','cartao','outro')),
  valor numeric(12,2) not null check (valor > 0),
  categoria text not null check (length(trim(categoria)) > 0),
  observacao text,
  estorno_de uuid unique references caixa_movimentos(id),
  criado_por uuid not null references perfis(id),
  criado_em timestamptz not null default now(),
  constraint chk_mov_sentido check ((tipo = 'entrada' and sentido = 1) or (tipo in ('saida','retirada') and sentido = -1) or tipo in ('ajuste','estorno')),
  constraint chk_mov_estorno check ((tipo = 'estorno') = (estorno_de is not null)),
  constraint chk_mov_retirada check (tipo <> 'retirada' or meio = 'dinheiro')
);
create index if not exists idx_cmov_caixa on caixa_movimentos (caixa_id, criado_em);
create index if not exists idx_cmov_loja_data on caixa_movimentos (loja_id, criado_em);
create index if not exists idx_cmov_criado_por on caixa_movimentos (criado_por);

create table if not exists caixa_auditoria (
  id uuid primary key default gen_random_uuid(),
  caixa_id uuid not null references caixas(id),
  loja_id uuid not null references lojas(id),
  acao text not null check (acao in ('abertura','movimento','estorno','fechamento','reabertura')),
  por uuid references perfis(id),
  em timestamptz not null default now(),
  motivo text,
  detalhes jsonb not null default '{}'::jsonb
);
create index if not exists idx_caud_caixa on caixa_auditoria (caixa_id, em);
create index if not exists idx_caud_por on caixa_auditoria (por);

-- Proteções: movimento confirmado nunca muda/apaga; caixa fechado não muda "no silêncio".
create or replace function trg_caixa_mov_guard() returns trigger
language plpgsql set search_path = public as $tag_trg_mov$
declare v_status text; v_loja uuid;
begin
  if tg_op in ('UPDATE','DELETE') then
    raise exception 'Movimentação confirmada não pode ser alterada ou apagada — faça um estorno';
  end if;
  select status, loja_id into v_status, v_loja from caixas where id = new.caixa_id;
  if v_status is distinct from 'aberto' then raise exception 'O caixa não está aberto'; end if;
  if v_loja <> new.loja_id then raise exception 'Movimento e caixa de lojas diferentes'; end if;
  return new;
end;
$tag_trg_mov$;
drop trigger if exists caixa_mov_guard on caixa_movimentos;
create trigger caixa_mov_guard before insert or update or delete on caixa_movimentos for each row execute function trg_caixa_mov_guard();

create or replace function trg_caixa_guard() returns trigger
language plpgsql set search_path = public as $tag_trg_caixa$
begin
  if tg_op = 'DELETE' then raise exception 'Caixa não pode ser apagado'; end if;
  if coalesce(current_setting('app.caixa_op', true), '') <> '1' then
    raise exception 'Caixa só pode ser alterado pelas funções de abrir/fechar/reabrir';
  end if;
  if old.status = 'fechado' and new.status = 'fechado' then
    raise exception 'Caixa fechado não pode ser alterado — reabra com permissão e motivo';
  end if;
  if new.loja_id <> old.loja_id or new.saldo_inicial <> old.saldo_inicial or new.aberto_por <> old.aberto_por or new.aberto_em <> old.aberto_em then
    raise exception 'Dados de abertura do caixa não podem ser alterados';
  end if;
  return new;
end;
$tag_trg_caixa$;
drop trigger if exists caixa_guard on caixas;
create trigger caixa_guard before update or delete on caixas for each row execute function trg_caixa_guard();

create or replace function trg_audit_guard() returns trigger
language plpgsql set search_path = public as $tag_trg_audit$
begin raise exception 'A auditoria não pode ser alterada'; end;
$tag_trg_audit$;
drop trigger if exists caixa_auditoria_guard on caixa_auditoria;
create trigger caixa_auditoria_guard before update or delete on caixa_auditoria for each row execute function trg_audit_guard();

-- ---------- 3) Cálculo do dinheiro esperado (só dinheiro físico) ----------
-- esperado = saldo inicial + movimentos em DINHEIRO (sinal) + vendas pagas em Dinheiro no período do caixa.
-- Pix, cartão, débito e crédito NUNCA entram. As vendas são lidas de `vendas` (não são copiadas),
-- então nada é lançado duas vezes.
create or replace function caixa_esperado(p_caixa_id uuid) returns numeric
language sql stable security definer set search_path = public as $tag_caixa_esperado$
  select c.saldo_inicial
    + coalesce((select sum(m.sentido * m.valor) from caixa_movimentos m where m.caixa_id = c.id and m.meio = 'dinheiro'), 0)
    + coalesce((select sum(v.total) from vendas v
                 where v.loja_id = c.loja_id and v.status = 'concluida' and v.forma_pagamento = 'Dinheiro'
                   and v.criado_em >= c.aberto_em and (c.janela_fim is null or v.criado_em <= c.janela_fim)), 0)
  from caixas c where c.id = p_caixa_id
$tag_caixa_esperado$;

create or replace function caixa_resumo(p_caixa_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $tag_caixa_resumo$
declare c caixas%rowtype; v_fim timestamptz;
begin
  select * into c from caixas where id = p_caixa_id;
  if not found then return null; end if;
  v_fim := coalesce(c.janela_fim, now());
  return jsonb_build_object(
    'id', c.id, 'loja_id', c.loja_id, 'loja_nome', (select nome from lojas where id = c.loja_id), 'status', c.status,
    'saldo_inicial', c.saldo_inicial, 'observacao_abertura', c.observacao_abertura,
    'aberto_em', c.aberto_em, 'aberto_por', c.aberto_por, 'aberto_por_nome', (select nome from perfis where id = c.aberto_por),
    'fechado_em', c.fechado_em, 'fechado_por_nome', (select nome from perfis where id = c.fechado_por),
    'esperado_dinheiro', case when c.status = 'fechado' then c.esperado_dinheiro else caixa_esperado(c.id) end,
    'valor_conferido', c.valor_conferido, 'diferenca', c.diferenca, 'justificativa', c.justificativa, 'reaberturas', c.reaberturas,
    'vendas_dinheiro', coalesce((select sum(total) from vendas v where v.loja_id = c.loja_id and v.status = 'concluida' and v.forma_pagamento = 'Dinheiro' and v.criado_em >= c.aberto_em and v.criado_em <= v_fim), 0),
    'vendas_pix', coalesce((select sum(total) from vendas v where v.loja_id = c.loja_id and v.status = 'concluida' and v.forma_pagamento = 'Pix' and v.criado_em >= c.aberto_em and v.criado_em <= v_fim), 0),
    'vendas_cartao', coalesce((select sum(total) from vendas v where v.loja_id = c.loja_id and v.status = 'concluida' and v.forma_pagamento in ('Cartão','Débito','Crédito') and v.criado_em >= c.aberto_em and v.criado_em <= v_fim), 0),
    'vendas_outro', coalesce((select sum(total) from vendas v where v.loja_id = c.loja_id and v.status = 'concluida' and v.forma_pagamento = 'Outro' and v.criado_em >= c.aberto_em and v.criado_em <= v_fim), 0),
    'mov_dinheiro', coalesce((select sum(sentido * valor) from caixa_movimentos m where m.caixa_id = c.id and m.meio = 'dinheiro'), 0),
    'mov_outros_meios', coalesce((select sum(sentido * valor) from caixa_movimentos m where m.caixa_id = c.id and m.meio <> 'dinheiro'), 0)
  );
end;
$tag_caixa_resumo$;

create or replace function caixa_movimentos_json(p_caixa_id uuid) returns jsonb
language sql stable security definer set search_path = public as $tag_cmov_json$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', m.id, 'tipo', m.tipo, 'sentido', m.sentido, 'meio', m.meio, 'valor', m.valor, 'categoria', m.categoria,
    'observacao', m.observacao, 'estorno_de', m.estorno_de, 'criado_em', m.criado_em,
    'criado_por_nome', (select nome from perfis where id = m.criado_por),
    'estornado', exists (select 1 from caixa_movimentos e where e.estorno_de = m.id)) order by m.criado_em, m.id), '[]'::jsonb)
  from caixa_movimentos m where m.caixa_id = p_caixa_id
$tag_cmov_json$;

-- ---------- 4) Operações do caixa ----------
create or replace function abrir_caixa(p_loja_id uuid, p_saldo_inicial numeric, p_observacao text default null) returns uuid
language plpgsql security definer set search_path = public as $tag_abrir_caixa$
declare v_id uuid;
begin
  if not tenho_acesso_a_loja(p_loja_id) then raise exception 'Você não tem permissão para esta loja'; end if;
  perform valida_valor(p_saldo_inicial, true);
  perform pg_advisory_xact_lock(hashtext('caixa:' || p_loja_id::text));
  if exists (select 1 from caixas where loja_id = p_loja_id and status = 'aberto') then
    raise exception 'Já existe um caixa aberto nesta loja';
  end if;
  begin
    insert into caixas (loja_id, saldo_inicial, observacao_abertura, aberto_por)
    values (p_loja_id, p_saldo_inicial, nullif(trim(coalesce(p_observacao, '')), ''), auth.uid()) returning id into v_id;
  exception when unique_violation then
    raise exception 'Já existe um caixa aberto nesta loja';
  end;
  insert into caixa_auditoria (caixa_id, loja_id, acao, por, detalhes)
  values (v_id, p_loja_id, 'abertura', auth.uid(), jsonb_build_object('saldo_inicial', p_saldo_inicial));
  return v_id;
end;
$tag_abrir_caixa$;

create or replace function registrar_movimento_caixa(p_caixa_id uuid, p_tipo text, p_meio text, p_valor numeric,
  p_categoria text, p_observacao text default null, p_sentido int default null) returns uuid
language plpgsql security definer set search_path = public as $tag_reg_mov$
declare c caixas%rowtype; v_sentido int; v_id uuid; v_esperado numeric;
begin
  select * into c from caixas where id = p_caixa_id for update;
  if not found then raise exception 'Caixa não encontrado'; end if;
  if not tenho_acesso_a_loja(c.loja_id) then raise exception 'Você não tem permissão para esta loja'; end if;
  if c.status <> 'aberto' then raise exception 'O caixa está fechado — reabra para lançar'; end if;
  if p_tipo not in ('entrada','saida','retirada','ajuste') then raise exception 'Tipo inválido (use entrada, saída, retirada ou ajuste)'; end if;
  if coalesce(p_meio, 'dinheiro') not in ('dinheiro','pix','cartao','outro') then raise exception 'Meio de pagamento inválido'; end if;
  perform valida_valor(p_valor);
  if nullif(trim(coalesce(p_categoria, '')), '') is null then raise exception 'Informe a categoria'; end if;
  if p_tipo = 'retirada' and coalesce(p_meio, 'dinheiro') <> 'dinheiro' then raise exception 'Retirada é sempre em dinheiro'; end if;
  if p_tipo = 'ajuste' then
    if not pode_gerir_loja(c.loja_id) then raise exception 'Só gerente ou dono faz ajuste de caixa'; end if;
    if p_sentido is null or p_sentido not in (1,-1) then raise exception 'Ajuste precisa informar se soma (+) ou subtrai (−)'; end if;
    if nullif(trim(coalesce(p_observacao, '')), '') is null then raise exception 'Ajuste exige observação'; end if;
    v_sentido := p_sentido;
  else
    v_sentido := case when p_tipo = 'entrada' then 1 else -1 end;
  end if;
  if v_sentido = -1 and coalesce(p_meio, 'dinheiro') = 'dinheiro' then
    v_esperado := caixa_esperado(c.id);
    if v_esperado - p_valor < 0 then raise exception 'Dinheiro insuficiente no caixa (esperado: R$ %)', to_char(v_esperado, 'FM999G999G990D00'); end if;
  end if;
  insert into caixa_movimentos (caixa_id, loja_id, tipo, sentido, meio, valor, categoria, observacao, criado_por)
  values (c.id, c.loja_id, p_tipo, v_sentido, coalesce(p_meio, 'dinheiro'), p_valor, trim(p_categoria), nullif(trim(coalesce(p_observacao, '')), ''), auth.uid())
  returning id into v_id;
  insert into caixa_auditoria (caixa_id, loja_id, acao, por, detalhes)
  values (c.id, c.loja_id, 'movimento', auth.uid(), jsonb_build_object('movimento_id', v_id, 'tipo', p_tipo, 'meio', coalesce(p_meio, 'dinheiro'), 'valor', p_valor));
  return v_id;
end;
$tag_reg_mov$;

-- Correção de movimentação confirmada = novo lançamento de estorno (o original permanece intacto).
create or replace function estornar_movimento_caixa(p_movimento_id uuid, p_motivo text) returns uuid
language plpgsql security definer set search_path = public as $tag_estornar_mov$
declare m caixa_movimentos%rowtype; c caixas%rowtype; v_id uuid; v_esperado numeric;
begin
  select caixa_id into c.id from caixa_movimentos where id = p_movimento_id;
  if c.id is null then raise exception 'Movimentação não encontrada'; end if;
  select * into c from caixas where id = c.id for update;                 -- serializa com outros lançamentos/fechamento
  select * into m from caixa_movimentos where id = p_movimento_id;
  if not pode_gerir_loja(c.loja_id) then raise exception 'Só gerente ou dono pode estornar'; end if;
  if nullif(trim(coalesce(p_motivo, '')), '') is null then raise exception 'Informe o motivo do estorno'; end if;
  if c.status <> 'aberto' then raise exception 'O caixa está fechado — reabra com motivo para corrigir'; end if;
  if m.tipo = 'estorno' then raise exception 'Um estorno não pode ser estornado'; end if;
  if exists (select 1 from caixa_movimentos where estorno_de = m.id) then raise exception 'Esta movimentação já foi estornada'; end if;
  if (-m.sentido) = -1 and m.meio = 'dinheiro' then
    v_esperado := caixa_esperado(c.id);
    if v_esperado - m.valor < 0 then raise exception 'Dinheiro insuficiente no caixa para este estorno'; end if;
  end if;
  begin
    insert into caixa_movimentos (caixa_id, loja_id, tipo, sentido, meio, valor, categoria, observacao, estorno_de, criado_por)
    values (m.caixa_id, m.loja_id, 'estorno', -m.sentido, m.meio, m.valor, 'estorno', trim(p_motivo), m.id, auth.uid()) returning id into v_id;
  exception when unique_violation then
    raise exception 'Esta movimentação já foi estornada';
  end;
  insert into caixa_auditoria (caixa_id, loja_id, acao, por, motivo, detalhes)
  values (m.caixa_id, m.loja_id, 'estorno', auth.uid(), trim(p_motivo), jsonb_build_object('movimento_original', m.id, 'estorno', v_id, 'valor', m.valor));
  return v_id;
end;
$tag_estornar_mov$;

create or replace function fechar_caixa(p_caixa_id uuid, p_valor_conferido numeric, p_justificativa text default null) returns jsonb
language plpgsql security definer set search_path = public as $tag_fechar_caixa$
declare c caixas%rowtype; v_esp numeric; v_dif numeric; v_just text := nullif(trim(coalesce(p_justificativa, '')), '');
begin
  select * into c from caixas where id = p_caixa_id for update;
  if not found then raise exception 'Caixa não encontrado'; end if;
  if not tenho_acesso_a_loja(c.loja_id) then raise exception 'Você não tem permissão para esta loja'; end if;
  if c.status <> 'aberto' then raise exception 'Este caixa já está fechado'; end if;
  perform valida_valor(p_valor_conferido, true);
  v_esp := caixa_esperado(c.id);
  v_dif := p_valor_conferido - v_esp;
  if v_dif <> 0 and v_just is null then raise exception 'Há diferença de R$ % — informe a justificativa', to_char(v_dif, 'FM999G999G990D00'); end if;
  perform set_config('app.caixa_op', '1', true);
  update caixas set status = 'fechado', fechado_por = auth.uid(), fechado_em = now(), janela_fim = coalesce(janela_fim, now()), esperado_dinheiro = v_esp,
         valor_conferido = p_valor_conferido, diferenca = v_dif, justificativa = v_just where id = c.id;
  insert into caixa_auditoria (caixa_id, loja_id, acao, por, motivo, detalhes)
  values (c.id, c.loja_id, 'fechamento', auth.uid(), v_just, jsonb_build_object('esperado', v_esp, 'conferido', p_valor_conferido, 'diferenca', v_dif));
  return jsonb_build_object('esperado', v_esp, 'conferido', p_valor_conferido, 'diferenca', v_dif);
end;
$tag_fechar_caixa$;

create or replace function reabrir_caixa(p_caixa_id uuid, p_motivo text) returns void
language plpgsql security definer set search_path = public as $tag_reabrir_caixa$
declare c caixas%rowtype;
begin
  select * into c from caixas where id = p_caixa_id for update;
  if not found then raise exception 'Caixa não encontrado'; end if;
  if not pode_gerir_loja(c.loja_id) then raise exception 'Só gerente ou dono pode reabrir o caixa'; end if;
  if length(trim(coalesce(p_motivo, ''))) < 5 then raise exception 'Informe o motivo da reabertura (mínimo 5 letras)'; end if;
  if c.status <> 'fechado' then raise exception 'Este caixa não está fechado'; end if;
  perform pg_advisory_xact_lock(hashtext('caixa:' || c.loja_id::text));
  if exists (select 1 from caixas where loja_id = c.loja_id and status = 'aberto') then
    raise exception 'Já existe outro caixa aberto nesta loja — feche-o antes';
  end if;
  insert into caixa_auditoria (caixa_id, loja_id, acao, por, motivo, detalhes)
  values (c.id, c.loja_id, 'reabertura', auth.uid(), trim(p_motivo),
          jsonb_build_object('fechado_em', c.fechado_em, 'esperado', c.esperado_dinheiro, 'conferido', c.valor_conferido, 'diferenca', c.diferenca, 'justificativa', c.justificativa));
  perform set_config('app.caixa_op', '1', true);
  update caixas set status = 'aberto', fechado_por = null, fechado_em = null, esperado_dinheiro = null, valor_conferido = null,
         diferenca = null, justificativa = null, reaberturas = reaberturas + 1 where id = c.id;
end;
$tag_reabrir_caixa$;

-- ---------- 5) Consultas do caixa ----------
create or replace function caixa_atual(p_loja_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $tag_caixa_atual$
declare v_id uuid; v_ult uuid;
begin
  if not pode_ver_loja(p_loja_id) then raise exception 'Você não tem permissão para esta loja'; end if;
  select id into v_id from caixas where loja_id = p_loja_id and status = 'aberto';
  select id into v_ult from caixas where loja_id = p_loja_id and status = 'fechado' order by fechado_em desc limit 1;
  return jsonb_build_object('aberto', caixa_resumo(v_id), 'movimentos', case when v_id is null then '[]'::jsonb else caixa_movimentos_json(v_id) end,
                            'ultimo_fechado', caixa_resumo(v_ult));
end;
$tag_caixa_atual$;

create or replace function caixa_detalhe(p_caixa_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $tag_caixa_detalhe$
declare v_loja uuid;
begin
  select loja_id into v_loja from caixas where id = p_caixa_id;
  if v_loja is null or not pode_ver_loja(v_loja) then raise exception 'Caixa não encontrado ou sem permissão'; end if;
  return jsonb_build_object('caixa', caixa_resumo(p_caixa_id), 'movimentos', caixa_movimentos_json(p_caixa_id),
    'auditoria', (select coalesce(jsonb_agg(jsonb_build_object('acao', a.acao, 'em', a.em, 'por', (select nome from perfis where id = a.por), 'motivo', a.motivo, 'detalhes', a.detalhes) order by a.em, a.id), '[]'::jsonb)
                  from caixa_auditoria a where a.caixa_id = p_caixa_id));
end;
$tag_caixa_detalhe$;

-- ---------- 6) Histórico financeiro por dia ----------
create or replace function historico_financeiro(p_loja_id uuid default null, p_inicio date default null, p_fim date default null,
  p_responsavel uuid default null, p_situacao text default null) returns jsonb
language plpgsql stable security definer set search_path = public as $tag_historico$
declare
  tz constant text := 'America/Sao_Paulo';
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  v_ini date; v_fim date; v_lojas uuid[]; r jsonb;
begin
  if not (eh_dono() or eh_da_equipe()) then raise exception 'Sem permissão'; end if;
  v_lojas := case when eh_dono() then array(select id from lojas where ativo) else array(select minhas_lojas()) end;
  if p_loja_id is not null and not (p_loja_id = any(v_lojas)) then raise exception 'Você não tem permissão para esta loja'; end if;
  if p_situacao is not null and p_situacao not in ('aberto','fechado','diferenca') then raise exception 'Situação inválida'; end if;
  v_fim := coalesce(p_fim, v_hoje); v_ini := coalesce(p_inicio, v_fim - 30);
  if v_ini > v_fim then raise exception 'Período inválido'; end if;
  if v_fim - v_ini > 366 then raise exception 'Período máximo: 1 ano'; end if;

  with lj as (select id, nome from lojas where id = any(v_lojas) and (p_loja_id is null or id = p_loja_id)),
  cx as (select c.id, c.loja_id, (c.aberto_em at time zone tz)::date as dia, c.status, c.saldo_inicial, c.valor_conferido, c.diferenca, c.aberto_por,
                (select nome from perfis where id = c.aberto_por) as responsavel
           from caixas c join lj on lj.id = c.loja_id
          where (c.aberto_em at time zone tz)::date between v_ini and v_fim
            and (p_responsavel is null or c.aberto_por = p_responsavel)
            and (p_situacao is null or (p_situacao = 'aberto' and c.status = 'aberto') or (p_situacao = 'fechado' and c.status = 'fechado')
                 or (p_situacao = 'diferenca' and coalesce(c.diferenca, 0) <> 0))),
  mv as (select m.loja_id, (m.criado_em at time zone tz)::date as dia, m.tipo, m.sentido, m.valor
           from caixa_movimentos m join lj on lj.id = m.loja_id
          where (m.criado_em at time zone tz)::date between v_ini and v_fim and (p_responsavel is null or m.criado_por = p_responsavel)),
  fin as (select f.loja_id, (f.data_ref at time zone tz)::date as dia, f.tipo, f.categoria, f.valor
           from financeiro_lancamentos f join lj on lj.id = f.loja_id
          where f.status = 'pago' and (f.data_ref at time zone tz)::date between v_ini and v_fim and (p_responsavel is null or f.criado_por = p_responsavel)),
  chaves as (select loja_id, dia from cx
             union select loja_id, dia from mv where p_situacao is null
             union select loja_id, dia from fin where p_situacao is null),
  dias as (
    select k.loja_id, k.dia, (select nome from lj where lj.id = k.loja_id) as loja_nome,
      coalesce((select sum(saldo_inicial) from cx where cx.loja_id = k.loja_id and cx.dia = k.dia), 0) as abertura,
      coalesce((select sum(valor) from mv where mv.loja_id = k.loja_id and mv.dia = k.dia and mv.tipo <> 'estorno' and mv.sentido = 1), 0)
        + coalesce((select sum(valor) from fin where fin.loja_id = k.loja_id and fin.dia = k.dia and fin.tipo = 'entrada' and fin.categoria <> 'estorno'), 0) as entradas,
      coalesce((select sum(valor) from mv where mv.loja_id = k.loja_id and mv.dia = k.dia and mv.tipo <> 'estorno' and mv.sentido = -1), 0)
        + coalesce((select sum(valor) from fin where fin.loja_id = k.loja_id and fin.dia = k.dia and fin.tipo = 'saida' and fin.categoria <> 'estorno'), 0) as saidas,
      coalesce((select sum(sentido * valor) from mv where mv.loja_id = k.loja_id and mv.dia = k.dia and mv.tipo = 'estorno'), 0)
        + coalesce((select sum(case fin.tipo when 'entrada' then fin.valor else -fin.valor end) from fin where fin.loja_id = k.loja_id and fin.dia = k.dia and fin.categoria = 'estorno'), 0) as estornos,
      coalesce((select sum(valor_conferido) from cx where cx.loja_id = k.loja_id and cx.dia = k.dia and cx.status = 'fechado'), 0) as fechamento,
      coalesce((select sum(diferenca) from cx where cx.loja_id = k.loja_id and cx.dia = k.dia and cx.status = 'fechado'), 0) as diferenca,
      case when exists (select 1 from cx where cx.loja_id = k.loja_id and cx.dia = k.dia and cx.status = 'aberto') then 'aberto'
           when exists (select 1 from cx where cx.loja_id = k.loja_id and cx.dia = k.dia) then 'fechado' else 'sem_caixa' end as situacao,
      coalesce((select jsonb_agg(jsonb_build_object('id', cx.id, 'status', cx.status, 'responsavel', cx.responsavel, 'saldo_inicial', cx.saldo_inicial,
                'valor_conferido', cx.valor_conferido, 'diferenca', cx.diferenca) order by cx.id) from cx where cx.loja_id = k.loja_id and cx.dia = k.dia), '[]'::jsonb) as caixas
    from chaves k)
  select coalesce(jsonb_agg(to_jsonb(d) || jsonb_build_object('saldo', d.entradas - d.saidas + d.estornos) order by d.dia desc, d.loja_nome), '[]'::jsonb)
    into r from dias d;
  return r;
end;
$tag_historico$;

create or replace function detalhe_dia_financeiro(p_loja_id uuid, p_dia date) returns jsonb
language plpgsql stable security definer set search_path = public as $tag_detalhe_dia$
declare tz constant text := 'America/Sao_Paulo';
begin
  if p_loja_id is null or p_dia is null or not pode_ver_loja(p_loja_id) then raise exception 'Você não tem permissão para esta loja'; end if;
  return jsonb_build_object(
    'caixas', (select coalesce(jsonb_agg(caixa_resumo(c.id) order by c.aberto_em), '[]'::jsonb) from caixas c
                where c.loja_id = p_loja_id and (c.aberto_em at time zone tz)::date = p_dia),
    'movimentos', (select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'tipo', m.tipo, 'sentido', m.sentido, 'meio', m.meio, 'valor', m.valor, 'categoria', m.categoria,
                    'observacao', m.observacao, 'criado_em', m.criado_em, 'criado_por_nome', (select nome from perfis where id = m.criado_por)) order by m.criado_em), '[]'::jsonb)
                    from caixa_movimentos m where m.loja_id = p_loja_id and (m.criado_em at time zone tz)::date = p_dia),
    'lancamentos', (select coalesce(jsonb_agg(jsonb_build_object('id', f.id, 'tipo', f.tipo, 'categoria', f.categoria, 'descricao', f.descricao, 'valor', f.valor,
                    'forma_pagamento', f.forma_pagamento, 'data_ref', f.data_ref, 'venda_id', f.venda_id) order by f.data_ref), '[]'::jsonb)
                    from financeiro_lancamentos f where f.loja_id = p_loja_id and f.status = 'pago' and (f.data_ref at time zone tz)::date = p_dia));
end;
$tag_detalhe_dia$;

-- ---------- 7) Comprovante (marca que o comprovante foi enviado) ----------
create or replace function marcar_comprovante_enviado(p_id uuid) returns void
language plpgsql security definer set search_path = public as $tag_comprovante$
declare v_loja uuid; v_exige boolean;
begin
  select loja_id, exige_comprovante into v_loja, v_exige from financeiro_lancamentos where id = p_id for update;
  if v_loja is null or not tenho_acesso_a_loja(v_loja) then raise exception 'Lançamento não encontrado ou sem permissão'; end if;
  if not v_exige then raise exception 'Este lançamento não exige comprovante'; end if;
  update financeiro_lancamentos set comprovante_enviado_em = coalesce(comprovante_enviado_em, now()) where id = p_id;
end;
$tag_comprovante$;

-- ---------- 8) Avisos ----------
create table if not exists avisos (
  id uuid primary key default gen_random_uuid(),
  tipo text not null default 'comunicado' check (tipo in ('sistema','comunicado')),
  titulo text not null check (length(trim(titulo)) between 3 and 120),
  descricao text not null check (length(trim(descricao)) between 1 and 2000),
  prioridade text not null default 'info' check (prioridade in ('info','atencao','urgente')),
  destaque boolean not null default false,
  global boolean not null default false,
  valido_ate timestamptz,
  ativo boolean not null default true,
  versao int not null default 1,
  criado_por uuid references perfis(id),
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
create index if not exists idx_avisos_criado_por on avisos (criado_por);
create table if not exists avisos_lojas (
  aviso_id uuid not null references avisos(id) on delete cascade,
  loja_id uuid not null references lojas(id) on delete cascade,
  primary key (aviso_id, loja_id)
);
create index if not exists idx_avisos_lojas_loja on avisos_lojas (loja_id);
create table if not exists avisos_leituras (
  aviso_id uuid not null references avisos(id) on delete cascade,
  perfil_id uuid not null references perfis(id) on delete cascade,
  versao_lida int not null,
  lido_em timestamptz not null default now(),
  primary key (aviso_id, perfil_id)
);
create index if not exists idx_avisos_leituras_perfil on avisos_leituras (perfil_id);
create table if not exists avisos_historico (
  id uuid primary key default gen_random_uuid(),
  aviso_id uuid not null references avisos(id) on delete cascade,
  versao int not null,
  por uuid references perfis(id),
  em timestamptz not null default now(),
  acao text not null,
  snapshot jsonb not null
);
create index if not exists idx_avisos_hist_aviso on avisos_historico (aviso_id, em);
create index if not exists idx_avisos_hist_por on avisos_historico (por);
create table if not exists alertas_lidos (
  perfil_id uuid not null references perfis(id) on delete cascade,
  loja_id uuid not null references lojas(id) on delete cascade,
  chave text not null,
  assinatura text not null,
  lido_em timestamptz not null default now(),
  primary key (perfil_id, loja_id, chave)
);
create index if not exists idx_alertas_lidos_loja on alertas_lidos (loja_id);

create or replace function publicar_aviso(p_id uuid, p_tipo text, p_titulo text, p_descricao text, p_prioridade text,
  p_destaque boolean, p_valido_ate timestamptz, p_global boolean, p_lojas uuid[]) returns uuid
language plpgsql security definer set search_path = public as $tag_publicar_aviso$
declare a avisos%rowtype; v_id uuid; v_lojas uuid[]; v_mudou boolean; l uuid; v_antigas uuid[];
begin
  if not eh_gerente() then raise exception 'Só gerente ou dono publica avisos'; end if;
  if p_tipo not in ('sistema','comunicado') then raise exception 'Tipo inválido'; end if;
  if p_prioridade not in ('info','atencao','urgente') then raise exception 'Prioridade inválida'; end if;
  if p_tipo = 'sistema' and not eh_dono() then raise exception 'Só o administrador geral publica mudanças do sistema'; end if;
  if p_valido_ate is not null and p_valido_ate <= now() then raise exception 'A validade precisa estar no futuro'; end if;
  v_lojas := array(select distinct x from unnest(coalesce(p_lojas, '{}'::uuid[])) x);
  if coalesce(p_global, false) then
    if not eh_dono() then raise exception 'Só o administrador geral publica avisos globais'; end if;
    v_lojas := '{}';
  else
    if coalesce(array_length(v_lojas, 1), 0) = 0 then raise exception 'Escolha pelo menos uma loja (ou aviso global)'; end if;
    foreach l in array v_lojas loop
      if not exists (select 1 from lojas where id = l) then raise exception 'Loja inválida'; end if;
      if not (eh_dono() or tenho_acesso_a_loja(l)) then raise exception 'Você só publica nas lojas que administra'; end if;
    end loop;
  end if;

  if p_id is null then
    insert into avisos (tipo, titulo, descricao, prioridade, destaque, global, valido_ate, criado_por)
    values (p_tipo, trim(p_titulo), trim(p_descricao), p_prioridade, coalesce(p_destaque, false), coalesce(p_global, false), p_valido_ate, auth.uid())
    returning id into v_id;
    insert into avisos_lojas (aviso_id, loja_id) select v_id, unnest(v_lojas);
    insert into avisos_historico (aviso_id, versao, por, acao, snapshot)
    select id, versao, auth.uid(), 'criado', to_jsonb(avisos.*) || jsonb_build_object('lojas', to_jsonb(v_lojas)) from avisos where id = v_id;
    return v_id;
  end if;

  select * into a from avisos where id = p_id for update;
  if not found then raise exception 'Aviso não encontrado'; end if;
  v_antigas := array(select loja_id from avisos_lojas where aviso_id = p_id);
  if not eh_dono() then
    if a.global or a.tipo = 'sistema' then raise exception 'Só o administrador geral edita este aviso'; end if;
    foreach l in array v_antigas loop
      if not tenho_acesso_a_loja(l) then raise exception 'Este aviso inclui lojas que você não administra'; end if;
    end loop;
  end if;
  v_mudou := a.titulo <> trim(p_titulo) or a.descricao <> trim(p_descricao) or a.prioridade <> p_prioridade
             or a.valido_ate is distinct from p_valido_ate or a.global <> coalesce(p_global, false)
             or (select array_agg(x order by x) from unnest(v_antigas) x) is distinct from (select array_agg(x order by x) from unnest(v_lojas) x);
  update avisos set tipo = p_tipo, titulo = trim(p_titulo), descricao = trim(p_descricao), prioridade = p_prioridade,
         destaque = coalesce(p_destaque, false), global = coalesce(p_global, false), valido_ate = p_valido_ate, ativo = true,
         versao = versao + case when v_mudou then 1 else 0 end, atualizado_em = now() where id = p_id;
  delete from avisos_lojas where aviso_id = p_id;
  insert into avisos_lojas (aviso_id, loja_id) select p_id, unnest(v_lojas);
  insert into avisos_historico (aviso_id, versao, por, acao, snapshot)
  select id, versao, auth.uid(), 'editado', to_jsonb(avisos.*) || jsonb_build_object('lojas', to_jsonb(v_lojas)) from avisos where id = p_id;
  return p_id;
end;
$tag_publicar_aviso$;

create or replace function arquivar_aviso(p_id uuid) returns void
language plpgsql security definer set search_path = public as $tag_arquivar_aviso$
declare a avisos%rowtype; l uuid;
begin
  if not eh_gerente() then raise exception 'Só gerente ou dono arquiva avisos'; end if;
  select * into a from avisos where id = p_id for update;
  if not found then raise exception 'Aviso não encontrado'; end if;
  if not eh_dono() then
    if a.global or a.tipo = 'sistema' then raise exception 'Só o administrador geral arquiva este aviso'; end if;
    for l in select loja_id from avisos_lojas where aviso_id = p_id loop
      if not tenho_acesso_a_loja(l) then raise exception 'Este aviso inclui lojas que você não administra'; end if;
    end loop;
  end if;
  update avisos set ativo = false, atualizado_em = now() where id = p_id;
  insert into avisos_historico (aviso_id, versao, por, acao, snapshot) select id, versao, auth.uid(), 'arquivado', to_jsonb(avisos.*) from avisos where id = p_id;
end;
$tag_arquivar_aviso$;

create or replace function marcar_aviso_lido(p_aviso_id uuid, p_loja_id uuid) returns void
language plpgsql security definer set search_path = public as $tag_marcar_aviso$
declare a avisos%rowtype;
begin
  if not pode_ver_loja(p_loja_id) then raise exception 'Você não tem permissão para esta loja'; end if;
  select * into a from avisos where id = p_aviso_id and ativo;
  if not found or not (a.global or exists (select 1 from avisos_lojas where aviso_id = a.id and loja_id = p_loja_id)) then
    raise exception 'Aviso não encontrado';
  end if;
  insert into avisos_leituras (aviso_id, perfil_id, versao_lida) values (a.id, auth.uid(), a.versao)
  on conflict (aviso_id, perfil_id) do update set versao_lida = excluded.versao_lida, lido_em = now();
end;
$tag_marcar_aviso$;

-- Alertas automáticos (calculados na hora). Marcar como lido só silencia o aviso — a pendência continua existindo.
create or replace function alertas_automaticos(p_loja_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $tag_alertas$
declare
  tz constant text := 'America/Sao_Paulo';
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  r jsonb := '[]'::jsonb; n int; s numeric;
begin
  select count(*), coalesce(sum(valor), 0) into n, s from financeiro_lancamentos
   where loja_id = p_loja_id and status <> 'pago' and vencimento is not null and vencimento < v_hoje;
  if n > 0 then r := r || jsonb_build_array(jsonb_build_object('chave', 'contas_vencidas', 'prioridade', 'urgente', 'acao', 'financeiro',
    'titulo', n || ' conta(s) vencida(s)', 'descricao', 'Total em atraso: R$ ' || to_char(s, 'FM999G999G990D00'), 'assinatura', n || ':' || s)); end if;

  select count(*), coalesce(sum(valor), 0) into n, s from financeiro_lancamentos
   where loja_id = p_loja_id and status = 'pago' and exige_comprovante and comprovante_enviado_em is null;
  if n > 0 then r := r || jsonb_build_array(jsonb_build_object('chave', 'comprovantes_pendentes', 'prioridade', 'atencao', 'acao', 'financeiro',
    'titulo', n || ' comprovante(s) com envio pendente', 'descricao', 'Lançamentos pagos que exigem comprovante e ainda não tiveram o envio confirmado.', 'assinatura', n || ':' || s)); end if;

  select count(*) into n from caixas
   where loja_id = p_loja_id and status = 'aberto' and (aberto_em at time zone tz)::date < v_hoje;
  if n > 0 then r := r || jsonb_build_array(jsonb_build_object('chave', 'caixa_dia_anterior', 'prioridade', 'urgente', 'acao', 'caixa',
    'titulo', 'Caixa aberto de dia anterior', 'descricao', 'Feche o caixa de ontem (ou anteriores) antes de seguir.',
    'assinatura', (select string_agg(id::text, ',' order by id) from caixas where loja_id = p_loja_id and status = 'aberto' and (aberto_em at time zone tz)::date < v_hoje))); end if;

  select count(*), coalesce(sum(abs(diferenca)), 0) into n, s from caixas
   where loja_id = p_loja_id and status = 'fechado' and diferenca <> 0 and fechado_em >= now() - interval '7 days';
  if n > 0 then r := r || jsonb_build_array(jsonb_build_object('chave', 'diferenca_fechamento', 'prioridade', 'atencao', 'acao', 'historico',
    'titulo', n || ' fechamento(s) com diferença (7 dias)', 'descricao', 'Soma das diferenças: R$ ' || to_char(s, 'FM999G999G990D00'),
    'assinatura', (select string_agg(id::text || '=' || diferenca::text, ',' order by id) from caixas where loja_id = p_loja_id and status = 'fechado' and diferenca <> 0 and fechado_em >= now() - interval '7 days'))); end if;
  return r;
end;
$tag_alertas$;

create or replace function marcar_alerta_lido(p_loja_id uuid, p_chave text) returns void
language plpgsql security definer set search_path = public as $tag_marcar_alerta$
declare v_ass text;
begin
  if not pode_ver_loja(p_loja_id) then raise exception 'Você não tem permissão para esta loja'; end if;
  select e->>'assinatura' into v_ass from jsonb_array_elements(alertas_automaticos(p_loja_id)) e where e->>'chave' = p_chave;
  if v_ass is null then return; end if;   -- alerta já resolvido: nada a marcar
  insert into alertas_lidos (perfil_id, loja_id, chave, assinatura) values (auth.uid(), p_loja_id, p_chave, v_ass)
  on conflict (perfil_id, loja_id, chave) do update set assinatura = excluded.assinatura, lido_em = now();
end;
$tag_marcar_alerta$;

create or replace function listar_avisos(p_loja_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $tag_listar_avisos$
declare r jsonb;
begin
  if not pode_ver_loja(p_loja_id) then raise exception 'Você não tem permissão para esta loja'; end if;
  select coalesce(jsonb_agg(x), '[]'::jsonb) into r from (
    select jsonb_build_object('origem', 'aviso', 'id', a.id, 'chave', a.id::text, 'tipo', a.tipo, 'titulo', a.titulo, 'descricao', a.descricao,
      'prioridade', a.prioridade, 'destaque', a.destaque, 'global', a.global, 'valido_ate', a.valido_ate, 'criado_em', a.criado_em,
      'atualizado_em', a.atualizado_em, 'versao', a.versao,
      'lojas', (select coalesce(jsonb_agg(lo.nome order by lo.nome), '[]'::jsonb) from avisos_lojas al join lojas lo on lo.id = al.loja_id
                where al.aviso_id = a.id and pode_ver_loja(al.loja_id)),
      'lido', l.perfil_id is not null and l.versao_lida >= a.versao,
      'atualizado', l.perfil_id is not null and l.versao_lida < a.versao,
      'pode_editar', eh_gerente() and (eh_dono() or (not a.global and a.tipo = 'comunicado' and not exists (
                       select 1 from avisos_lojas z where z.aviso_id = a.id and not tenho_acesso_a_loja(z.loja_id))))) as x
      from avisos a left join avisos_leituras l on l.aviso_id = a.id and l.perfil_id = auth.uid()
     where a.ativo and (a.valido_ate is null or a.valido_ate > now())
       and (a.global or exists (select 1 from avisos_lojas al where al.aviso_id = a.id and al.loja_id = p_loja_id))
    union all
    select jsonb_build_object('origem', 'alerta', 'id', null, 'chave', e->>'chave', 'tipo', 'alerta', 'titulo', e->>'titulo', 'descricao', e->>'descricao',
      'prioridade', e->>'prioridade', 'destaque', (e->>'prioridade') = 'urgente', 'global', false, 'valido_ate', null, 'criado_em', now(), 'atualizado_em', now(),
      'acao', e->>'acao', 'lojas', '[]'::jsonb,
      'lido', al.perfil_id is not null and al.assinatura = e->>'assinatura',
      'atualizado', al.perfil_id is not null and al.assinatura <> e->>'assinatura', 'pode_editar', false)
      from jsonb_array_elements(alertas_automaticos(p_loja_id)) e
      left join alertas_lidos al on al.perfil_id = auth.uid() and al.loja_id = p_loja_id and al.chave = e->>'chave'
  ) t;
  select coalesce(jsonb_agg(e order by (e->>'destaque')::boolean desc,
           case e->>'prioridade' when 'urgente' then 0 when 'atencao' then 1 else 2 end, e->>'criado_em' desc), '[]'::jsonb)
    into r from jsonb_array_elements(r) e;
  return r;
end;
$tag_listar_avisos$;

-- ---------- 9) Segurança: tabelas novas só pelas funções ----------
alter table caixas enable row level security;
alter table caixa_movimentos enable row level security;
alter table caixa_auditoria enable row level security;
alter table avisos enable row level security;
alter table avisos_lojas enable row level security;
alter table avisos_leituras enable row level security;
alter table avisos_historico enable row level security;
alter table alertas_lidos enable row level security;
revoke all on caixas, caixa_movimentos, caixa_auditoria, avisos, avisos_lojas, avisos_leituras, avisos_historico, alertas_lidos from public, anon, authenticated;

revoke execute on function public.pode_ver_loja(uuid), public.pode_gerir_loja(uuid), public.valida_valor(numeric, boolean),
  public.caixa_esperado(uuid), public.caixa_resumo(uuid), public.caixa_movimentos_json(uuid), public.alertas_automaticos(uuid),
  public.trg_caixa_mov_guard(), public.trg_caixa_guard(), public.trg_audit_guard() from public, anon, authenticated;
revoke execute on function public.abrir_caixa(uuid, numeric, text), public.registrar_movimento_caixa(uuid, text, text, numeric, text, text, int),
  public.estornar_movimento_caixa(uuid, text), public.fechar_caixa(uuid, numeric, text), public.reabrir_caixa(uuid, text),
  public.caixa_atual(uuid), public.caixa_detalhe(uuid), public.historico_financeiro(uuid, date, date, uuid, text),
  public.detalhe_dia_financeiro(uuid, date), public.marcar_comprovante_enviado(uuid),
  public.publicar_aviso(uuid, text, text, text, text, boolean, timestamptz, boolean, uuid[]), public.arquivar_aviso(uuid),
  public.marcar_aviso_lido(uuid, uuid), public.marcar_alerta_lido(uuid, text), public.listar_avisos(uuid) from public, anon;

-- ---------- 10) Aviso inicial de "mudanças no sistema" ----------
insert into avisos (tipo, titulo, descricao, prioridade, global, destaque)
select 'sistema', 'Novo: caixa, histórico financeiro e avisos',
       'Agora cada loja abre e fecha o caixa (dinheiro separado de Pix e cartão), consulta o histórico financeiro por dia e recebe avisos aqui na tela inicial.',
       'info', true, false
where not exists (select 1 from avisos where titulo = 'Novo: caixa, histórico financeiro e avisos');

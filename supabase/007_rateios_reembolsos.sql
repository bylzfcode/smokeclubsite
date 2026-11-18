-- ============================================================
-- 007_rateios_reembolsos.sql — Despesas COMPARTILHADAS entre lojas (rateio) e reembolsos internos.
-- Ordem (nada foi aplicado no projeto remoto): schema.sql -> 002 -> 003 -> 004 -> 005 -> 006 -> 007.
-- Não toca em vendas, pedidos, estoque, catálogo, nem em contas e pagamentos existentes (estes continuam exatamente como estão).
--
-- MODELO
--  * Conta EXCLUSIVA continua sendo o padrão (financeiro_lancamentos). Um RATEIO só existe se alguém o criar com 2+ lojas.
--  * rateios: a despesa externa única (valor total). rateio_parcelas: a RESPONSABILIDADE de cada loja (soma exata em centavos; versão ativa).
--  * rateio_pagamentos: quem PAGOU o fornecedor (externo). Parcial, repetível só com chave de repetição, corrigido por estorno.
--  * rateio_reembolsos: dinheiro devolvido ENTRE lojas (origem -> destino). NÃO quita a conta externa e NÃO é receita nem despesa.
--  * posição da loja = pago ao externo + reembolsos pagos − reembolsos recebidos − parcela   (+ = a recuperar, − = deve)
--  * Regra de consistência (verificada no servidor após toda operação): o reembolso líquido recebido por uma loja nunca passa do que ela pagou
--    a mais que sua parcela, e o líquido pago nunca passa do que ela ainda deve. Reembolsos só andam em direção ao acerto.
--  * Toda operação trava o rateio (FOR UPDATE): pagamentos, reembolsos e estornos concorrentes são serializados.
--  * Não movimenta o caixa. Pagamentos externos aparecem no fluxo/histórico UMA vez, na loja que pagou (despesa consolidada = total pago ao externo);
--    reembolsos ficam só na tela do rateio (transferência interna).
--  * Rateio com movimentação não é alterado: para revisar ou cancelar, estorne antes todos os pagamentos e reembolsos (o histórico é preservado,
--    a revisão cria uma NOVA VERSÃO das parcelas e guarda a anterior).
-- ============================================================

-- ---------- 1) Tabelas (acesso só pelas funções) ----------
create table if not exists rateios (
  id uuid primary key default gen_random_uuid(),
  descricao text not null check (length(trim(descricao)) between 3 and 200),
  categoria text not null check (length(trim(categoria)) > 0 and lower(trim(categoria)) not in ('venda','estorno')),
  valor_total numeric(12,2) not null check (valor_total > 0),
  vencimento date,
  metodo text not null check (metodo in ('igual','percentual','valores')),
  exige_comprovante boolean not null default false,
  status text not null default 'ativo' check (status in ('ativo','cancelado')),
  versao integer not null default 1,
  chave_criacao uuid not null,
  criado_por uuid not null references perfis(id),
  criado_em timestamptz not null default now(),
  cancelado_em timestamptz,
  cancelado_por uuid references perfis(id),
  motivo_cancelamento text,
  constraint uq_rateio_chave unique (criado_por, chave_criacao)
);
create index if not exists idx_rateios_cancelado_por on rateios (cancelado_por);

create table if not exists rateio_parcelas (
  id uuid primary key default gen_random_uuid(),
  rateio_id uuid not null references rateios(id),
  versao integer not null,
  loja_id uuid not null references lojas(id),
  percentual numeric(9,4),
  valor numeric(12,2) not null check (valor > 0),
  ativa boolean not null default true,
  criado_em timestamptz not null default now(),
  constraint uq_rateio_parcela unique (rateio_id, versao, loja_id)
);
create index if not exists idx_rateio_parcelas_loja on rateio_parcelas (loja_id);

create table if not exists rateio_pagamentos (
  id uuid primary key default gen_random_uuid(),
  rateio_id uuid not null references rateios(id),
  loja_id uuid not null references lojas(id),
  tipo text not null default 'pagamento' check (tipo in ('pagamento','estorno')),
  valor numeric(12,2) not null check (valor > 0),
  data_pagamento date not null,
  forma_pagamento text not null check (forma_pagamento in ('Pix','Transferência','Boleto','Cartão','Débito','Crédito','Dinheiro','Outro')),
  observacao text,
  motivo text,
  estorno_de uuid unique references rateio_pagamentos(id),
  chave uuid not null,
  criado_por uuid not null references perfis(id),
  criado_em timestamptz not null default now(),
  constraint chk_rpag_estorno check ((tipo = 'estorno') = (estorno_de is not null)),
  constraint uq_rpag_chave unique (rateio_id, chave)
);
create index if not exists idx_rpag_loja on rateio_pagamentos (loja_id);
create index if not exists idx_rpag_criado_por on rateio_pagamentos (criado_por);

create table if not exists rateio_reembolsos (
  id uuid primary key default gen_random_uuid(),
  rateio_id uuid not null references rateios(id),
  loja_origem uuid not null references lojas(id),     -- quem devolve (devedora)
  loja_destino uuid not null references lojas(id),    -- quem recebe (pagou a mais)
  tipo text not null default 'reembolso' check (tipo in ('reembolso','estorno')),
  valor numeric(12,2) not null check (valor > 0),
  data_reembolso date not null,
  observacao text,
  motivo text,
  estorno_de uuid unique references rateio_reembolsos(id),
  chave uuid not null,
  criado_por uuid not null references perfis(id),
  criado_em timestamptz not null default now(),
  constraint chk_rreemb_lojas check (loja_origem <> loja_destino),
  constraint chk_rreemb_estorno check ((tipo = 'estorno') = (estorno_de is not null)),
  constraint uq_rreemb_chave unique (rateio_id, chave)
);
create index if not exists idx_rreemb_origem on rateio_reembolsos (loja_origem);
create index if not exists idx_rreemb_destino on rateio_reembolsos (loja_destino);
create index if not exists idx_rreemb_criado_por on rateio_reembolsos (criado_por);

create table if not exists comprovantes_rateio (
  id uuid primary key default gen_random_uuid(),
  rateio_id uuid not null references rateios(id),
  pagamento_id uuid references rateio_pagamentos(id),
  reembolso_id uuid references rateio_reembolsos(id),
  storage_path text not null unique,
  nome_original text,
  mime text not null check (mime in ('application/pdf','image/jpeg','image/png','image/webp')),
  tamanho integer not null check (tamanho between 1 and 5242880),
  enviado_por uuid not null references perfis(id),
  enviado_em timestamptz not null default now(),
  constraint chk_comp_rateio_alvo check ((pagamento_id is null) <> (reembolso_id is null))
);
create index if not exists idx_comp_rateio_rateio on comprovantes_rateio (rateio_id);
create index if not exists idx_comp_rateio_pag on comprovantes_rateio (pagamento_id);
create index if not exists idx_comp_rateio_reemb on comprovantes_rateio (reembolso_id);
create index if not exists idx_comp_rateio_por on comprovantes_rateio (enviado_por);

create table if not exists rateio_auditoria (
  id uuid primary key default gen_random_uuid(),
  rateio_id uuid not null references rateios(id),
  loja_id uuid references lojas(id),
  acao text not null check (acao in ('criado','revisado','cancelado','pagamento_externo','estorno_pagamento','reembolso','estorno_reembolso','comprovante_anexado')),
  por uuid references perfis(id),
  em timestamptz not null default now(),
  motivo text,
  detalhes jsonb not null default '{}'::jsonb
);
create index if not exists idx_raud_rateio on rateio_auditoria (rateio_id, em);
create index if not exists idx_raud_loja on rateio_auditoria (loja_id);
create index if not exists idx_raud_por on rateio_auditoria (por);

-- Movimentações, comprovantes e auditoria são imutáveis (correção = estorno). Rateio/parcelas só mudam pelas funções.
drop trigger if exists rpag_imutavel on rateio_pagamentos;
create trigger rpag_imutavel before update or delete on rateio_pagamentos for each row execute function trg_fin_imutavel();
drop trigger if exists rreemb_imutavel on rateio_reembolsos;
create trigger rreemb_imutavel before update or delete on rateio_reembolsos for each row execute function trg_fin_imutavel();
drop trigger if exists comp_rateio_imutavel on comprovantes_rateio;
create trigger comp_rateio_imutavel before update or delete on comprovantes_rateio for each row execute function trg_fin_imutavel();
drop trigger if exists rateio_aud_imutavel on rateio_auditoria;
create trigger rateio_aud_imutavel before update or delete on rateio_auditoria for each row execute function trg_fin_imutavel();

create or replace function trg_rateio_guard() returns trigger
language plpgsql set search_path = public as $tag_trg_rateio_guard$
begin
  if tg_op = 'DELETE' then raise exception 'Rateio não pode ser apagado — cancele com motivo'; end if;
  if coalesce(current_setting('app.rateio_op', true), '') <> '1' then
    raise exception 'Rateio só pode ser alterado pelas funções de revisar/cancelar';
  end if;
  return new;
end;
$tag_trg_rateio_guard$;
drop trigger if exists rateios_guard on rateios;
create trigger rateios_guard before update or delete on rateios for each row execute function trg_rateio_guard();
drop trigger if exists rateio_parcelas_guard on rateio_parcelas;
create trigger rateio_parcelas_guard before update or delete on rateio_parcelas for each row execute function trg_rateio_guard();

-- ---------- 2) Auxiliares ----------
create or replace function rateio_audit(p_rateio uuid, p_loja uuid, p_acao text, p_motivo text, p_det jsonb) returns void
language sql security definer set search_path = public as $tag_rateio_audit$
  insert into rateio_auditoria (rateio_id, loja_id, acao, por, motivo, detalhes) values (p_rateio, p_loja, p_acao, auth.uid(), p_motivo, coalesce(p_det, '{}'::jsonb))
$tag_rateio_audit$;

-- gerente só envolve lojas em que tem autorização; dono, todas
create or replace function rateio_pode_envolver(p_lojas uuid[]) returns boolean
language sql stable security definer set search_path = public as $tag_rateio_envolver$
  select eh_dono() or (eh_gerente() and not exists (select 1 from unnest(p_lojas) l where l not in (select minhas_lojas())))
$tag_rateio_envolver$;

create or replace function rateio_visivel(p_rateio uuid) returns boolean
language sql stable security definer set search_path = public as $tag_rateio_visivel$
  select eh_dono() or exists (select 1 from rateios r join rateio_parcelas pa on pa.rateio_id = r.id and pa.versao = r.versao and pa.ativa
                               where r.id = p_rateio and pa.loja_id in (select minhas_lojas()))
$tag_rateio_visivel$;

-- Divisão em centavos, DETERMINÍSTICA: ordem das lojas = nome, depois id.
--   igual: base = total/n em centavos; os centavos que sobram vão, um a um, às primeiras lojas da ordem.
--   percentual: maior resto (parte fracionária dos centavos), desempate pela ordem. Percentuais precisam somar exatamente 100.
--   valores: cada parcela informada; a soma precisa ser exatamente o total.
create or replace function rateio_calcular(p_total numeric, p_metodo text, p_itens jsonb)
returns table (ordem integer, loja_uuid uuid, loja_nome text, percentual_calc numeric, valor_calc numeric, ajuste_centavos integer)
language plpgsql stable security definer set search_path = public as $tag_rateio_calcular$
declare v_n int; v_cents bigint; v_ids uuid[]; v_soma numeric; v_resto bigint;
begin
  perform valida_valor(p_total);
  if p_metodo not in ('igual','percentual','valores') then raise exception 'Método de divisão inválido'; end if;
  if p_itens is null or jsonb_typeof(p_itens) <> 'array' or jsonb_array_length(p_itens) < 2 then
    raise exception 'O rateio precisa de pelo menos 2 lojas (para uma loja só, use conta exclusiva)';
  end if;
  v_n := jsonb_array_length(p_itens); v_cents := round(p_total * 100);
  v_ids := array(select (e->>'loja_id')::uuid from jsonb_array_elements(p_itens) e);
  if (select count(distinct x) from unnest(v_ids) x) <> v_n then raise exception 'Há loja repetida no rateio'; end if;
  if (select count(*) from lojas where id = any(v_ids) and ativo) <> v_n then raise exception 'Loja inválida ou inativa no rateio'; end if;
  if p_metodo = 'percentual' then
    if exists (select 1 from jsonb_array_elements(p_itens) e where nullif(e->>'percentual','') is null or (e->>'percentual')::numeric <= 0 or (e->>'percentual')::numeric > 100 or round((e->>'percentual')::numeric, 4) <> (e->>'percentual')::numeric) then
      raise exception 'Cada percentual deve ser maior que zero, até 100 e com no máximo 4 casas'; end if;
    select sum((e->>'percentual')::numeric) into v_soma from jsonb_array_elements(p_itens) e;
    if v_soma <> 100 then raise exception 'Os percentuais somam % e precisam somar exatamente 100', v_soma; end if;
  elsif p_metodo = 'valores' then
    if exists (select 1 from jsonb_array_elements(p_itens) e where nullif(e->>'valor','') is null or (e->>'valor')::numeric <= 0 or round((e->>'valor')::numeric, 2) <> (e->>'valor')::numeric) then
      raise exception 'Cada valor deve ser maior que zero, com no máximo 2 casas decimais (centavos)'; end if;
    select sum((e->>'valor')::numeric) into v_soma from jsonb_array_elements(p_itens) e;
    if v_soma <> p_total then raise exception 'A soma das parcelas (R$ %) difere do total (R$ %)', to_char(v_soma, 'FM999G999G990D00'), to_char(p_total, 'FM999G999G990D00'); end if;
  end if;
  return query
    with it as (select (e->>'loja_id')::uuid as lid, nullif(e->>'percentual','')::numeric as pct, nullif(e->>'valor','')::numeric as val from jsonb_array_elements(p_itens) e),
    base as (select it.lid, it.pct, it.val, lo.nome, (row_number() over (order by lo.nome, lo.id))::int as ord from it join lojas lo on lo.id = it.lid),
    calc as (select b.*,
        case p_metodo when 'igual' then v_cents / v_n when 'percentual' then floor(v_cents * b.pct / 100)::bigint else round(b.val * 100)::bigint end as base_c,
        case p_metodo when 'percentual' then (v_cents * b.pct / 100) - floor(v_cents * b.pct / 100) when 'igual' then 0 else 0 end as frac
      from base b),
    resto as (select v_cents - sum(c.base_c) as r from calc c),
    rk as (select c.*, (row_number() over (order by c.frac desc, c.ord))::int as rnk from calc c)
    select rk.ord, rk.lid, rk.nome::text,
           case p_metodo when 'percentual' then rk.pct when 'igual' then round(100.0 / v_n, 4) else round(rk.val * 100.0 / p_total, 4) end,
           ((rk.base_c + case when p_metodo <> 'valores' and rk.rnk <= (select r from resto) then 1 else 0 end)::numeric / 100),
           (case when p_metodo <> 'valores' and rk.rnk <= (select r from resto) then 1 else 0 end)::int
      from rk order by rk.ord;
end;
$tag_rateio_calcular$;

create or replace function rateio_posicoes(p_rateio uuid)
returns table (loja_uuid uuid, loja_nome text, parcela numeric, pago_externo numeric, reembolso_pago numeric, reembolso_recebido numeric, posicao numeric)
language sql stable security definer set search_path = public as $tag_rateio_posicoes$
  select pa.loja_id, lo.nome::text, pa.valor,
    coalesce((select sum(case x.tipo when 'pagamento' then x.valor else -x.valor end) from rateio_pagamentos x where x.rateio_id = pa.rateio_id and x.loja_id = pa.loja_id), 0),
    coalesce((select sum(case x.tipo when 'reembolso' then x.valor else -x.valor end) from rateio_reembolsos x where x.rateio_id = pa.rateio_id and x.loja_origem = pa.loja_id), 0),
    coalesce((select sum(case x.tipo when 'reembolso' then x.valor else -x.valor end) from rateio_reembolsos x where x.rateio_id = pa.rateio_id and x.loja_destino = pa.loja_id), 0),
    coalesce((select sum(case x.tipo when 'pagamento' then x.valor else -x.valor end) from rateio_pagamentos x where x.rateio_id = pa.rateio_id and x.loja_id = pa.loja_id), 0)
      + coalesce((select sum(case x.tipo when 'reembolso' then x.valor else -x.valor end) from rateio_reembolsos x where x.rateio_id = pa.rateio_id and x.loja_origem = pa.loja_id), 0)
      - coalesce((select sum(case x.tipo when 'reembolso' then x.valor else -x.valor end) from rateio_reembolsos x where x.rateio_id = pa.rateio_id and x.loja_destino = pa.loja_id), 0)
      - pa.valor
  from rateio_parcelas pa join rateios r on r.id = pa.rateio_id and r.versao = pa.versao join lojas lo on lo.id = pa.loja_id
  where pa.rateio_id = p_rateio and pa.ativa
  order by lo.nome, lo.id
$tag_rateio_posicoes$;

create or replace function rateio_pago_externo(p_rateio uuid) returns numeric
language sql stable security definer set search_path = public as $tag_rateio_pago_ext$
  select coalesce(sum(case tipo when 'pagamento' then valor else -valor end), 0) from rateio_pagamentos where rateio_id = p_rateio
$tag_rateio_pago_ext$;

-- Rede de segurança: nenhuma operação pode deixar o rateio incoerente (reverte tudo se falhar).
create or replace function rateio_validar(p_rateio uuid) returns void
language plpgsql stable security definer set search_path = public as $tag_rateio_validar$
declare r record; v_total numeric; v_ext numeric; v_liq numeric; v_excesso numeric;
begin
  select valor_total into v_total from rateios where id = p_rateio;
  v_ext := rateio_pago_externo(p_rateio);
  if v_ext < 0 or v_ext > v_total then raise exception 'Pagamentos externos fora do limite do valor total'; end if;
  for r in select * from rateio_posicoes(p_rateio) loop
    if r.pago_externo < 0 then raise exception 'Pagamento externo negativo'; end if;
    v_liq := r.reembolso_recebido - r.reembolso_pago;          -- reembolso líquido que entrou na loja
    v_excesso := r.pago_externo - r.parcela;                    -- quanto pagou a mais (+) ou a menos (−) que a parcela
    if (v_liq > 0 and v_liq > greatest(0, v_excesso)) or (v_liq < 0 and -v_liq > greatest(0, -v_excesso)) then
      raise exception 'Operação recusada: os reembolsos registrados dependem dos pagamentos externos (estorne os reembolsos antes)';
    end if;
  end loop;
end;
$tag_rateio_validar$;

create or replace function rateio_sem_movimento_liquido(p_rateio uuid) returns boolean
language sql stable security definer set search_path = public as $tag_rateio_sem_mov$
  select not exists (select 1 from rateio_pagamentos where rateio_id = p_rateio group by loja_id having sum(case tipo when 'pagamento' then valor else -valor end) <> 0)
     and not exists (select 1 from rateio_reembolsos where rateio_id = p_rateio group by loja_origem, loja_destino having sum(case tipo when 'reembolso' then valor else -valor end) <> 0)
$tag_rateio_sem_mov$;

-- ---------- 3) Prévia, criação, revisão e cancelamento ----------
create or replace function rateio_previa(p_valor_total numeric, p_metodo text, p_itens jsonb) returns jsonb
language plpgsql stable security definer set search_path = public as $tag_rateio_previa$
declare v_lojas uuid[];
begin
  if not eh_gerente() then raise exception 'Só gerente ou dono cria rateios'; end if;
  v_lojas := array(select (e->>'loja_id')::uuid from jsonb_array_elements(coalesce(p_itens, '[]'::jsonb)) e);
  if not rateio_pode_envolver(v_lojas) then raise exception 'Você só pode ratear entre lojas que administra'; end if;
  return (select jsonb_build_object('total', p_valor_total, 'metodo', p_metodo, 'soma', sum(c.valor_calc),
            'ajustes', coalesce(sum(c.ajuste_centavos), 0),
            'parcelas', jsonb_agg(jsonb_build_object('loja_id', c.loja_uuid, 'loja_nome', c.loja_nome, 'percentual', c.percentual_calc, 'valor', c.valor_calc, 'ajuste_centavos', c.ajuste_centavos) order by c.ordem))
            from rateio_calcular(p_valor_total, p_metodo, p_itens) c);
end;
$tag_rateio_previa$;

create or replace function criar_rateio(p_descricao text, p_categoria text, p_valor_total numeric, p_vencimento date, p_exige_comprovante boolean,
  p_metodo text, p_itens jsonb, p_chave uuid) returns uuid
language plpgsql security definer set search_path = public as $tag_criar_rateio$
declare v_lojas uuid[]; v_id uuid;
begin
  if not eh_gerente() then raise exception 'Só gerente ou dono cria rateios'; end if;
  if p_chave is null then raise exception 'Chave de repetição obrigatória'; end if;
  v_lojas := array(select (e->>'loja_id')::uuid from jsonb_array_elements(coalesce(p_itens, '[]'::jsonb)) e);
  if not rateio_pode_envolver(v_lojas) then raise exception 'Você só pode criar rateios com lojas que administra'; end if;
  if length(trim(coalesce(p_descricao, ''))) < 3 then raise exception 'Informe a descrição'; end if;
  if nullif(trim(coalesce(p_categoria, '')), '') is null or lower(trim(p_categoria)) in ('venda','estorno') then raise exception 'Categoria inválida'; end if;
  perform pg_advisory_xact_lock(hashtext('rateio:' || auth.uid()::text || p_chave::text));
  select id into v_id from rateios where criado_por = auth.uid() and chave_criacao = p_chave;
  if v_id is not null then return v_id; end if;
  perform valida_valor(p_valor_total);
  insert into rateios (descricao, categoria, valor_total, vencimento, metodo, exige_comprovante, chave_criacao, criado_por)
  values (trim(p_descricao), trim(p_categoria), p_valor_total, p_vencimento, p_metodo, coalesce(p_exige_comprovante, false), p_chave, auth.uid()) returning id into v_id;
  insert into rateio_parcelas (rateio_id, versao, loja_id, percentual, valor)
  select v_id, 1, c.loja_uuid, case p_metodo when 'percentual' then c.percentual_calc end, c.valor_calc from rateio_calcular(p_valor_total, p_metodo, p_itens) c;
  perform rateio_audit(v_id, null, 'criado', null, jsonb_build_object('valor_total', p_valor_total, 'metodo', p_metodo,
    'parcelas', (select jsonb_agg(jsonb_build_object('loja_id', loja_id, 'valor', valor) order by loja_id) from rateio_parcelas where rateio_id = v_id)));
  return v_id;
end;
$tag_criar_rateio$;

create or replace function revisar_rateio(p_id uuid, p_descricao text, p_valor_total numeric, p_vencimento date, p_metodo text, p_itens jsonb, p_motivo text) returns integer
language plpgsql security definer set search_path = public as $tag_revisar_rateio$
declare r rateios%rowtype; v_novas uuid[]; v_antigas uuid[]; v_ant jsonb;
begin
  select * into r from rateios where id = p_id for update;
  if r.id is null then raise exception 'Rateio não encontrado'; end if;
  if not eh_gerente() then raise exception 'Só gerente ou dono revisa rateios'; end if;
  v_antigas := array(select loja_id from rateio_parcelas where rateio_id = r.id and versao = r.versao and ativa);
  v_novas := array(select (e->>'loja_id')::uuid from jsonb_array_elements(coalesce(p_itens, '[]'::jsonb)) e);
  if not rateio_pode_envolver(v_antigas || v_novas) then raise exception 'Você só revisa rateios entre lojas que administra'; end if;
  if length(trim(coalesce(p_motivo, ''))) < 5 then raise exception 'Informe o motivo da revisão (mínimo 5 letras)'; end if;
  if r.status <> 'ativo' then raise exception 'Rateio cancelado não pode ser revisado'; end if;
  if not rateio_sem_movimento_liquido(r.id) then
    raise exception 'Este rateio já tem movimentações: estorne todos os pagamentos e reembolsos antes de revisar (o histórico fica preservado)';
  end if;
  if length(trim(coalesce(p_descricao, ''))) < 3 then raise exception 'Informe a descrição'; end if;
  v_ant := (select jsonb_agg(jsonb_build_object('loja_id', loja_id, 'valor', valor) order by loja_id) from rateio_parcelas where rateio_id = r.id and versao = r.versao and ativa);
  perform set_config('app.rateio_op', '1', true);
  update rateio_parcelas set ativa = false where rateio_id = r.id and versao = r.versao;
  update rateios set versao = versao + 1, descricao = trim(p_descricao), valor_total = valor_total, vencimento = p_vencimento, metodo = p_metodo where id = r.id;
  perform valida_valor(p_valor_total);
  update rateios set valor_total = p_valor_total where id = r.id;
  insert into rateio_parcelas (rateio_id, versao, loja_id, percentual, valor)
  select r.id, r.versao + 1, c.loja_uuid, case p_metodo when 'percentual' then c.percentual_calc end, c.valor_calc from rateio_calcular(p_valor_total, p_metodo, p_itens) c;
  perform rateio_audit(r.id, null, 'revisado', trim(p_motivo), jsonb_build_object('versao_anterior', r.versao, 'valor_total_anterior', r.valor_total, 'parcelas_anteriores', v_ant, 'valor_total_novo', p_valor_total, 'metodo', p_metodo));
  return r.versao + 1;
end;
$tag_revisar_rateio$;

create or replace function cancelar_rateio(p_id uuid, p_motivo text) returns void
language plpgsql security definer set search_path = public as $tag_cancelar_rateio$
declare r rateios%rowtype;
begin
  select * into r from rateios where id = p_id for update;
  if r.id is null then raise exception 'Rateio não encontrado'; end if;
  if not eh_gerente() or not rateio_pode_envolver(array(select loja_id from rateio_parcelas where rateio_id = r.id and versao = r.versao and ativa)) then
    raise exception 'Só gerente ou dono das lojas envolvidas cancela o rateio';
  end if;
  if length(trim(coalesce(p_motivo, ''))) < 5 then raise exception 'Informe o motivo do cancelamento (mínimo 5 letras)'; end if;
  if r.status = 'cancelado' then raise exception 'Rateio já cancelado'; end if;
  if not rateio_sem_movimento_liquido(r.id) then raise exception 'Este rateio já tem movimentações: estorne todos os pagamentos e reembolsos antes de cancelar'; end if;
  perform set_config('app.rateio_op', '1', true);
  update rateios set status = 'cancelado', cancelado_em = now(), cancelado_por = auth.uid(), motivo_cancelamento = trim(p_motivo) where id = r.id;
  perform rateio_audit(r.id, null, 'cancelado', trim(p_motivo), jsonb_build_object('valor_total', r.valor_total));
end;
$tag_cancelar_rateio$;

-- ---------- 4) Pagamentos EXTERNOS (quem pagou o fornecedor) ----------
create or replace function registrar_pagamento_rateio(p_rateio_id uuid, p_loja_id uuid, p_valor numeric, p_data date, p_forma text, p_observacao text, p_chave uuid) returns jsonb
language plpgsql security definer set search_path = public as $tag_pag_rateio$
declare
  r rateios%rowtype; e rateio_pagamentos%rowtype; v_id uuid; v_ext numeric;
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date; v_data date := coalesce(p_data, (now() at time zone 'America/Sao_Paulo')::date);
begin
  select * into r from rateios where id = p_rateio_id for update;                    -- serializa tudo deste rateio
  if r.id is null then raise exception 'Rateio não encontrado'; end if;
  if not (eh_dono() or tenho_acesso_a_loja(p_loja_id)) then raise exception 'Você não tem permissão para registrar pagamento desta loja'; end if;
  if not exists (select 1 from rateio_parcelas where rateio_id = r.id and versao = r.versao and ativa and loja_id = p_loja_id) then raise exception 'Esta loja não participa do rateio'; end if;
  if p_chave is null then raise exception 'Chave de repetição obrigatória'; end if;
  select * into e from rateio_pagamentos where rateio_id = r.id and chave = p_chave;
  if e.id is not null then
    if e.loja_id <> p_loja_id or e.tipo <> 'pagamento' or e.valor <> p_valor then raise exception 'Esta chave de repetição já foi usada em outra operação'; end if;
    v_ext := rateio_pago_externo(r.id);
    return jsonb_build_object('pagamento_id', e.id, 'pago_externo', v_ext, 'saldo_externo', r.valor_total - v_ext, 'repetida', true);
  end if;
  if r.status <> 'ativo' then raise exception 'Rateio cancelado não recebe pagamentos'; end if;
  perform valida_valor(p_valor);
  if v_data > v_hoje then raise exception 'A data do pagamento não pode ser futura'; end if;
  if p_forma is null or p_forma not in ('Pix','Transferência','Boleto','Cartão','Débito','Crédito','Dinheiro','Outro') then raise exception 'Forma de pagamento inválida'; end if;
  v_ext := rateio_pago_externo(r.id);
  if v_ext >= r.valor_total then raise exception 'A despesa externa já está quitada'; end if;
  if p_valor > r.valor_total - v_ext then
    raise exception 'Pagamento (R$ %) maior que o saldo externo da despesa (R$ %)', to_char(p_valor, 'FM999G999G990D00'), to_char(r.valor_total - v_ext, 'FM999G999G990D00');
  end if;
  insert into rateio_pagamentos (rateio_id, loja_id, tipo, valor, data_pagamento, forma_pagamento, observacao, chave, criado_por)
  values (r.id, p_loja_id, 'pagamento', p_valor, v_data, p_forma, nullif(trim(coalesce(p_observacao, '')), ''), p_chave, auth.uid()) returning id into v_id;
  perform rateio_validar(r.id);
  perform rateio_audit(r.id, p_loja_id, 'pagamento_externo', null, jsonb_build_object('pagamento_id', v_id, 'valor', p_valor, 'forma', p_forma, 'data', v_data));
  v_ext := rateio_pago_externo(r.id);
  return jsonb_build_object('pagamento_id', v_id, 'pago_externo', v_ext, 'saldo_externo', r.valor_total - v_ext, 'repetida', false);
end;
$tag_pag_rateio$;

create or replace function estornar_pagamento_rateio(p_pagamento_id uuid, p_motivo text) returns jsonb
language plpgsql security definer set search_path = public as $tag_est_pag_rateio$
declare p rateio_pagamentos%rowtype; r rateios%rowtype; v_id uuid; v_ext numeric;
begin
  select * into p from rateio_pagamentos where id = p_pagamento_id;
  if p.id is null then raise exception 'Pagamento não encontrado'; end if;
  select * into r from rateios where id = p.rateio_id for update;
  if not (eh_dono() or pode_gerir_loja(p.loja_id)) then raise exception 'Só gerente da loja que pagou ou o dono pode estornar'; end if;
  if length(trim(coalesce(p_motivo, ''))) < 5 then raise exception 'Informe o motivo do estorno (mínimo 5 letras)'; end if;
  if p.tipo <> 'pagamento' then raise exception 'Um estorno não pode ser estornado'; end if;
  if exists (select 1 from rateio_pagamentos where estorno_de = p.id) then raise exception 'Este pagamento já foi estornado'; end if;
  begin
    insert into rateio_pagamentos (rateio_id, loja_id, tipo, valor, data_pagamento, forma_pagamento, motivo, estorno_de, chave, criado_por)
    values (p.rateio_id, p.loja_id, 'estorno', p.valor, (now() at time zone 'America/Sao_Paulo')::date, p.forma_pagamento, trim(p_motivo), p.id, gen_random_uuid(), auth.uid()) returning id into v_id;
  exception when unique_violation then raise exception 'Este pagamento já foi estornado';
  end;
  perform rateio_validar(p.rateio_id);
  perform rateio_audit(p.rateio_id, p.loja_id, 'estorno_pagamento', trim(p_motivo), jsonb_build_object('pagamento_original', p.id, 'estorno', v_id, 'valor', p.valor));
  v_ext := rateio_pago_externo(p.rateio_id);
  return jsonb_build_object('estorno_id', v_id, 'pago_externo', v_ext, 'saldo_externo', r.valor_total - v_ext);
end;
$tag_est_pag_rateio$;

-- ---------- 5) Reembolsos INTERNOS (origem devolve a destino) ----------
create or replace function registrar_reembolso(p_rateio_id uuid, p_loja_origem uuid, p_loja_destino uuid, p_valor numeric, p_data date, p_observacao text, p_chave uuid) returns jsonb
language plpgsql security definer set search_path = public as $tag_reembolso$
declare
  r rateios%rowtype; e rateio_reembolsos%rowtype; v_id uuid; po record; pd record;
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date; v_data date := coalesce(p_data, (now() at time zone 'America/Sao_Paulo')::date);
begin
  select * into r from rateios where id = p_rateio_id for update;
  if r.id is null then raise exception 'Rateio não encontrado'; end if;
  if not (eh_dono() or tenho_acesso_a_loja(p_loja_origem) or tenho_acesso_a_loja(p_loja_destino)) then raise exception 'Você não tem permissão para registrar reembolso entre estas lojas'; end if;
  if p_chave is null then raise exception 'Chave de repetição obrigatória'; end if;
  select * into e from rateio_reembolsos where rateio_id = r.id and chave = p_chave;
  if e.id is not null then
    if e.loja_origem <> p_loja_origem or e.loja_destino <> p_loja_destino or e.tipo <> 'reembolso' or e.valor <> p_valor then raise exception 'Esta chave de repetição já foi usada em outra operação'; end if;
    return jsonb_build_object('reembolso_id', e.id, 'repetido', true);
  end if;
  if r.status <> 'ativo' then raise exception 'Rateio cancelado não recebe reembolsos'; end if;
  if p_loja_origem = p_loja_destino then raise exception 'Origem e destino do reembolso precisam ser lojas diferentes'; end if;
  perform valida_valor(p_valor);
  if v_data > v_hoje then raise exception 'A data do reembolso não pode ser futura'; end if;
  select * into po from rateio_posicoes(r.id) where loja_uuid = p_loja_origem;
  select * into pd from rateio_posicoes(r.id) where loja_uuid = p_loja_destino;
  if po.loja_uuid is null or pd.loja_uuid is null then raise exception 'As duas lojas precisam participar do rateio'; end if;
  if p_valor > greatest(0, -po.posicao) then
    raise exception 'Reembolso (R$ %) maior que o saldo devido pela loja de origem (R$ %)', to_char(p_valor, 'FM999G999G990D00'), to_char(greatest(0, -po.posicao), 'FM999G999G990D00');
  end if;
  if p_valor > greatest(0, pd.posicao) then
    raise exception 'Reembolso (R$ %) maior que o valor a recuperar da loja de destino (R$ %)', to_char(p_valor, 'FM999G999G990D00'), to_char(greatest(0, pd.posicao), 'FM999G999G990D00');
  end if;
  insert into rateio_reembolsos (rateio_id, loja_origem, loja_destino, tipo, valor, data_reembolso, observacao, chave, criado_por)
  values (r.id, p_loja_origem, p_loja_destino, 'reembolso', p_valor, v_data, nullif(trim(coalesce(p_observacao, '')), ''), p_chave, auth.uid()) returning id into v_id;
  perform rateio_validar(r.id);
  perform rateio_audit(r.id, p_loja_origem, 'reembolso', null, jsonb_build_object('reembolso_id', v_id, 'origem', p_loja_origem, 'destino', p_loja_destino, 'valor', p_valor, 'data', v_data));
  return jsonb_build_object('reembolso_id', v_id, 'repetido', false);
end;
$tag_reembolso$;

create or replace function estornar_reembolso(p_reembolso_id uuid, p_motivo text) returns jsonb
language plpgsql security definer set search_path = public as $tag_est_reembolso$
declare x rateio_reembolsos%rowtype; v_id uuid;
begin
  select * into x from rateio_reembolsos where id = p_reembolso_id;
  if x.id is null then raise exception 'Reembolso não encontrado'; end if;
  perform 1 from rateios where id = x.rateio_id for update;
  if not (eh_dono() or pode_gerir_loja(x.loja_origem) or pode_gerir_loja(x.loja_destino)) then raise exception 'Só gerente de uma das lojas ou o dono pode estornar o reembolso'; end if;
  if length(trim(coalesce(p_motivo, ''))) < 5 then raise exception 'Informe o motivo do estorno (mínimo 5 letras)'; end if;
  if x.tipo <> 'reembolso' then raise exception 'Um estorno não pode ser estornado'; end if;
  if exists (select 1 from rateio_reembolsos where estorno_de = x.id) then raise exception 'Este reembolso já foi estornado'; end if;
  begin
    insert into rateio_reembolsos (rateio_id, loja_origem, loja_destino, tipo, valor, data_reembolso, motivo, estorno_de, chave, criado_por)
    values (x.rateio_id, x.loja_origem, x.loja_destino, 'estorno', x.valor, (now() at time zone 'America/Sao_Paulo')::date, trim(p_motivo), x.id, gen_random_uuid(), auth.uid()) returning id into v_id;
  exception when unique_violation then raise exception 'Este reembolso já foi estornado';
  end;
  perform rateio_validar(x.rateio_id);
  perform rateio_audit(x.rateio_id, x.loja_origem, 'estorno_reembolso', trim(p_motivo), jsonb_build_object('reembolso_original', x.id, 'estorno', v_id, 'valor', x.valor));
  return jsonb_build_object('estorno_id', v_id);
end;
$tag_est_reembolso$;

-- ---------- 6) Comprovantes (pagamento externo = obrigatório se exigido; reembolso = opcional) ----------
-- Caminho: rateio/<rateio_id>/<pagamento_ou_reembolso_id>/<uuid>.<pdf|jpg|jpeg|png|webp>
create or replace function pode_enviar_comprovante(p_name text) returns boolean
language plpgsql stable security definer set search_path = public as $tag_pode_enviar$
declare m text[];
begin
  m := regexp_match(coalesce(p_name, ''), '^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/[0-9a-f-]{36}\.(pdf|jpe?g|png|webp)$');
  if m is not null then
    return exists (select 1 from pagamentos_lancamento p
                    where p.id = m[2]::uuid and p.loja_id = m[1]::uuid and p.tipo = 'pagamento' and tenho_acesso_a_loja(p.loja_id)
                      and not exists (select 1 from pagamentos_lancamento e where e.estorno_de = p.id));
  end if;
  m := regexp_match(coalesce(p_name, ''), '^rateio/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/[0-9a-f-]{36}\.(pdf|jpe?g|png|webp)$');
  if m is null then return false; end if;
  return exists (select 1 from rateio_pagamentos p where p.id = m[2]::uuid and p.rateio_id = m[1]::uuid and p.tipo = 'pagamento'
                    and (eh_dono() or tenho_acesso_a_loja(p.loja_id)) and not exists (select 1 from rateio_pagamentos e where e.estorno_de = p.id))
      or exists (select 1 from rateio_reembolsos x where x.id = m[2]::uuid and x.rateio_id = m[1]::uuid and x.tipo = 'reembolso'
                    and (eh_dono() or tenho_acesso_a_loja(x.loja_origem) or tenho_acesso_a_loja(x.loja_destino)) and not exists (select 1 from rateio_reembolsos e where e.estorno_de = x.id));
end;
$tag_pode_enviar$;

-- leitura: comprovantes de pagamentos comuns (como antes) e os de rateio, para as lojas que participam (conferência) e o dono
create or replace function pode_ver_comprovante(p_name text) returns boolean
language sql stable security definer set search_path = public as $tag_pode_ver_comp$
  select exists (select 1 from comprovantes_pagamento c where c.storage_path = p_name and pode_ver_loja(c.loja_id))
      or exists (select 1 from comprovantes_rateio c where c.storage_path = p_name and rateio_visivel(c.rateio_id))
$tag_pode_ver_comp$;

create or replace function registrar_comprovante_rateio(p_pagamento_id uuid, p_reembolso_id uuid, p_path text, p_nome text, p_mime text, p_tamanho integer) returns uuid
language plpgsql security definer set search_path = public as $tag_comp_rateio$
declare v_rateio uuid; v_mov uuid; v_prefix text; v_id uuid; v_ext text; v_meta jsonb; v_cnt int;
begin
  if (p_pagamento_id is null) = (p_reembolso_id is null) then raise exception 'Informe o pagamento OU o reembolso'; end if;
  if p_pagamento_id is not null then
    select rateio_id, id into v_rateio, v_mov from rateio_pagamentos where id = p_pagamento_id and tipo = 'pagamento';
    if v_mov is null then raise exception 'Pagamento não encontrado'; end if;
    if not (eh_dono() or tenho_acesso_a_loja((select loja_id from rateio_pagamentos where id = v_mov))) then raise exception 'Você não tem permissão para esta loja'; end if;
    if exists (select 1 from rateio_pagamentos where estorno_de = v_mov) then raise exception 'Pagamento estornado não recebe comprovante'; end if;
  else
    select rateio_id, id into v_rateio, v_mov from rateio_reembolsos where id = p_reembolso_id and tipo = 'reembolso';
    if v_mov is null then raise exception 'Reembolso não encontrado'; end if;
    if not (eh_dono() or exists (select 1 from rateio_reembolsos x where x.id = v_mov and (tenho_acesso_a_loja(x.loja_origem) or tenho_acesso_a_loja(x.loja_destino)))) then raise exception 'Você não tem permissão para esta loja'; end if;
    if exists (select 1 from rateio_reembolsos where estorno_de = v_mov) then raise exception 'Reembolso estornado não recebe comprovante'; end if;
  end if;
  v_prefix := 'rateio/' || v_rateio::text || '/' || v_mov::text || '/';
  if p_path is null or left(p_path, length(v_prefix)) <> v_prefix or not pode_enviar_comprovante(p_path) then raise exception 'Caminho do arquivo inválido para esta movimentação'; end if;
  v_ext := lower(substring(p_path from '\.([a-z]+)$'));
  if p_mime not in ('application/pdf','image/jpeg','image/png','image/webp') then raise exception 'Tipo de arquivo não permitido (use PDF, JPG, PNG ou WEBP)'; end if;
  if not ((p_mime = 'application/pdf' and v_ext = 'pdf') or (p_mime = 'image/jpeg' and v_ext in ('jpg','jpeg')) or (p_mime = 'image/png' and v_ext = 'png') or (p_mime = 'image/webp' and v_ext = 'webp')) then
    raise exception 'A extensão do arquivo não corresponde ao tipo';
  end if;
  if p_tamanho is null or p_tamanho < 1 or p_tamanho > 5242880 then raise exception 'Arquivo vazio ou maior que 5 MB'; end if;
  perform pg_advisory_xact_lock(hashtext('limpeza_comprovantes'));
  if exists (select 1 from storage_limpeza where caminho = p_path) then
    raise exception 'Este arquivo foi removido pela limpeza de arquivos não vinculados — envie o comprovante de novo';
  end if;
  select id into v_id from comprovantes_rateio where storage_path = p_path;
  if v_id is not null then return v_id; end if;
  if (select count(*) from comprovantes_rateio where pagamento_id is not distinct from p_pagamento_id and reembolso_id is not distinct from p_reembolso_id) >= 5 then raise exception 'Limite de 5 arquivos por movimentação'; end if;
  if to_regclass('storage.objects') is not null then
    execute 'select count(*)::int, (array_agg(metadata))[1] from storage.objects where bucket_id = $1 and name = $2' into v_cnt, v_meta using 'comprovantes', p_path;
    if v_cnt = 0 then raise exception 'Arquivo ainda não está no armazenamento — envie de novo'; end if;
    if v_meta is not null and ((v_meta->>'size') is not null and (v_meta->>'size')::bigint <> p_tamanho or (v_meta->>'mimetype') is not null and v_meta->>'mimetype' <> p_mime) then
      raise exception 'Tamanho/tipo informado não confere com o arquivo enviado';
    end if;
  end if;
  insert into comprovantes_rateio (rateio_id, pagamento_id, reembolso_id, storage_path, nome_original, mime, tamanho, enviado_por)
  values (v_rateio, p_pagamento_id, p_reembolso_id, p_path, left(nullif(trim(coalesce(p_nome, '')), ''), 200), p_mime, p_tamanho, auth.uid()) returning id into v_id;
  perform rateio_audit(v_rateio, null, 'comprovante_anexado', null, jsonb_build_object('arquivo', p_path, 'pagamento_id', p_pagamento_id, 'reembolso_id', p_reembolso_id));
  return v_id;
end;
$tag_comp_rateio$;

-- ---------- 7) Consultas ----------
create or replace function listar_rateios(p_loja_id uuid default null, p_situacao text default null) returns jsonb
language plpgsql stable security definer set search_path = public as $tag_listar_rateios$
declare v_hoje date := (now() at time zone 'America/Sao_Paulo')::date; v_res jsonb;
begin
  if not (eh_dono() or eh_da_equipe()) then raise exception 'Sem permissão'; end if;
  if p_loja_id is not null and not pode_ver_loja(p_loja_id) then raise exception 'Você não tem permissão para esta loja'; end if;
  if p_situacao is not null and p_situacao not in ('pendente','parcial','paga','cancelado','vencida') then raise exception 'Situação inválida'; end if;
  with vis as (
    select r.* from rateios r
     where (eh_dono() or exists (select 1 from rateio_parcelas pa where pa.rateio_id = r.id and pa.versao = r.versao and pa.ativa and pa.loja_id in (select minhas_lojas())))
       and (p_loja_id is null or exists (select 1 from rateio_parcelas pa where pa.rateio_id = r.id and pa.versao = r.versao and pa.ativa and pa.loja_id = p_loja_id))),
  calc as (
    select v.*, rateio_pago_externo(v.id) as ext,
           case when v.status = 'cancelado' then 'cancelado' when rateio_pago_externo(v.id) >= v.valor_total then 'paga' when rateio_pago_externo(v.id) > 0 then 'parcial' else 'pendente' end as sit
      from vis v)
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', c.id, 'descricao', c.descricao, 'categoria', c.categoria, 'valor_total', c.valor_total, 'vencimento', c.vencimento, 'status', c.status, 'situacao', c.sit,
      'exige_comprovante', c.exige_comprovante, 'pago_externo', c.ext, 'saldo_externo', case when c.status = 'cancelado' then 0 else c.valor_total - c.ext end,
      'vencida', (c.sit in ('pendente','parcial') and c.vencimento is not null and c.vencimento < v_hoje), 'criado_em', c.criado_em,
      'lojas', (select count(*) from rateio_parcelas pa where pa.rateio_id = c.id and pa.versao = c.versao and pa.ativa),
      'minhas', (select coalesce(jsonb_agg(jsonb_build_object('loja_id', p.loja_uuid, 'loja_nome', p.loja_nome, 'parcela', p.parcela, 'pago_externo', p.pago_externo,
                   'reembolso_pago', p.reembolso_pago, 'reembolso_recebido', p.reembolso_recebido, 'posicao', p.posicao) order by p.loja_nome), '[]'::jsonb)
                   from rateio_posicoes(c.id) p where (p_loja_id is null and (eh_dono() or p.loja_uuid in (select minhas_lojas()))) or p.loja_uuid = p_loja_id)
    ) order by c.criado_em desc), '[]'::jsonb)
    into v_res
    from (select * from calc cc where p_situacao is null or (p_situacao = 'vencida' and cc.sit in ('pendente','parcial') and cc.vencimento < v_hoje) or cc.sit = p_situacao order by cc.criado_em desc limit 300) c;
  return v_res;
end;
$tag_listar_rateios$;

create or replace function rateio_detalhe(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $tag_rateio_detalhe$
declare r rateios%rowtype; v_ext numeric; v_lojas uuid[];
begin
  select * into r from rateios where id = p_id;
  if r.id is null or not rateio_visivel(r.id) then raise exception 'Rateio não encontrado ou sem permissão'; end if;
  v_ext := rateio_pago_externo(r.id);
  v_lojas := array(select loja_uuid from rateio_posicoes(r.id));
  return jsonb_build_object(
    'rateio', jsonb_build_object('id', r.id, 'descricao', r.descricao, 'categoria', r.categoria, 'valor_total', r.valor_total, 'vencimento', r.vencimento, 'metodo', r.metodo,
        'status', r.status, 'versao', r.versao, 'exige_comprovante', r.exige_comprovante, 'criado_em', r.criado_em, 'criado_por_nome', (select nome from perfis where id = r.criado_por),
        'cancelado_em', r.cancelado_em, 'motivo_cancelamento', r.motivo_cancelamento,
        'pago_externo', v_ext, 'saldo_externo', case when r.status = 'cancelado' then 0 else r.valor_total - v_ext end,
        'despesa_consolidada', v_ext,
        'situacao', case when r.status = 'cancelado' then 'cancelado' when v_ext >= r.valor_total then 'paga' when v_ext > 0 then 'parcial' else 'pendente' end,
        'pode_revisar', r.status = 'ativo' and eh_gerente() and rateio_pode_envolver(v_lojas) and rateio_sem_movimento_liquido(r.id),
        'pode_cancelar', r.status = 'ativo' and eh_gerente() and rateio_pode_envolver(v_lojas) and rateio_sem_movimento_liquido(r.id),
        'tem_movimento', not rateio_sem_movimento_liquido(r.id)),
    'posicoes', (select coalesce(jsonb_agg(jsonb_build_object('loja_id', p.loja_uuid, 'loja_nome', p.loja_nome, 'parcela', p.parcela, 'pago_externo', p.pago_externo,
                  'reembolso_pago', p.reembolso_pago, 'reembolso_recebido', p.reembolso_recebido, 'posicao', p.posicao, 'minha', (eh_dono() or p.loja_uuid in (select minhas_lojas()))) order by p.loja_nome), '[]'::jsonb)
                  from rateio_posicoes(r.id) p),
    'pagamentos', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'loja_id', x.loja_id, 'loja_nome', (select nome from lojas where id = x.loja_id), 'tipo', x.tipo, 'valor', x.valor,
                  'data', x.data_pagamento, 'forma_pagamento', x.forma_pagamento, 'observacao', x.observacao, 'motivo', x.motivo, 'estorno_de', x.estorno_de, 'criado_em', x.criado_em,
                  'criado_por_nome', (select nome from perfis where id = x.criado_por),
                  'estornado', exists (select 1 from rateio_pagamentos e where e.estorno_de = x.id),
                  'pode_estornar', x.tipo = 'pagamento' and not exists (select 1 from rateio_pagamentos e where e.estorno_de = x.id) and (eh_dono() or pode_gerir_loja(x.loja_id)),
                  'pode_anexar', x.tipo = 'pagamento' and not exists (select 1 from rateio_pagamentos e where e.estorno_de = x.id) and (eh_dono() or tenho_acesso_a_loja(x.loja_id)),
                  'comprovantes', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'nome', c.nome_original, 'mime', c.mime, 'tamanho', c.tamanho, 'path', c.storage_path, 'enviado_em', c.enviado_em,
                                   'enviado_por_nome', (select nome from perfis where id = c.enviado_por)) order by c.enviado_em), '[]'::jsonb) from comprovantes_rateio c where c.pagamento_id = x.id)
                  ) order by x.criado_em, x.id), '[]'::jsonb) from rateio_pagamentos x where x.rateio_id = r.id),
    'reembolsos', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'origem_id', x.loja_origem, 'origem_nome', (select nome from lojas where id = x.loja_origem),
                  'destino_id', x.loja_destino, 'destino_nome', (select nome from lojas where id = x.loja_destino), 'tipo', x.tipo, 'valor', x.valor, 'data', x.data_reembolso,
                  'observacao', x.observacao, 'motivo', x.motivo, 'estorno_de', x.estorno_de, 'criado_em', x.criado_em, 'criado_por_nome', (select nome from perfis where id = x.criado_por),
                  'estornado', exists (select 1 from rateio_reembolsos e where e.estorno_de = x.id),
                  'pode_estornar', x.tipo = 'reembolso' and not exists (select 1 from rateio_reembolsos e where e.estorno_de = x.id) and (eh_dono() or pode_gerir_loja(x.loja_origem) or pode_gerir_loja(x.loja_destino)),
                  'pode_anexar', x.tipo = 'reembolso' and not exists (select 1 from rateio_reembolsos e where e.estorno_de = x.id) and (eh_dono() or tenho_acesso_a_loja(x.loja_origem) or tenho_acesso_a_loja(x.loja_destino)),
                  'comprovantes', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'nome', c.nome_original, 'mime', c.mime, 'tamanho', c.tamanho, 'path', c.storage_path, 'enviado_em', c.enviado_em,
                                   'enviado_por_nome', (select nome from perfis where id = c.enviado_por)) order by c.enviado_em), '[]'::jsonb) from comprovantes_rateio c where c.reembolso_id = x.id)
                  ) order by x.criado_em, x.id), '[]'::jsonb) from rateio_reembolsos x where x.rateio_id = r.id),
    'pode_pagar_lojas', (select coalesce(jsonb_agg(jsonb_build_object('loja_id', p.loja_uuid, 'loja_nome', p.loja_nome) order by p.loja_nome), '[]'::jsonb)
                          from rateio_posicoes(r.id) p where eh_dono() or tenho_acesso_a_loja(p.loja_uuid)),
    'auditoria', (select coalesce(jsonb_agg(jsonb_build_object('acao', a.acao, 'em', a.em, 'por', (select nome from perfis where id = a.por), 'motivo', a.motivo) order by a.em, a.id), '[]'::jsonb)
                    from rateio_auditoria a where a.rateio_id = r.id));
end;
$tag_rateio_detalhe$;

-- ---------- 8) Recriações ADITIVAS (mesmo formato de antes; só acrescentam o rateio) ----------
create or replace function fluxo_pago_itens() returns table (lancamento_id uuid, loja_id uuid, tipo text, categoria text, efeito numeric,
  data_ref timestamptz, criado_por uuid, descricao text, forma_pagamento text, venda_id uuid, origem text)
language sql stable security definer set search_path = public as $tag_fluxo$
  select l.id, l.loja_id, l.tipo, l.categoria, case l.tipo when 'entrada' then l.valor else -l.valor end, l.data_ref, l.criado_por, l.descricao,
         l.forma_pagamento, l.venda_id, case when l.venda_id is not null then 'venda' when l.categoria = 'estorno' then 'estorno_venda' else 'conta' end
    from financeiro_lancamentos l
   where l.status = 'pago' and not exists (select 1 from pagamentos_lancamento p where p.lancamento_id = l.id)
  union all
  select l.id, p.loja_id, l.tipo, l.categoria, case when (l.tipo = 'entrada') = (p.tipo = 'pagamento') then p.valor else -p.valor end,
         (p.data_pagamento::timestamp at time zone 'America/Sao_Paulo'), p.criado_por, l.descricao, p.forma_pagamento, null::uuid,
         case p.tipo when 'pagamento' then 'pagamento' else 'estorno_pagamento' end
    from pagamentos_lancamento p join financeiro_lancamentos l on l.id = p.lancamento_id
  union all
  -- pagamentos EXTERNOS de despesas compartilhadas (uma vez só, na loja que pagou). Reembolsos entre lojas NÃO entram aqui.
  select r.id, p.loja_id, 'saida'::text, case p.tipo when 'pagamento' then r.categoria else 'estorno' end, case p.tipo when 'pagamento' then -p.valor else p.valor end,
         (p.data_pagamento::timestamp at time zone 'America/Sao_Paulo'), p.criado_por, r.descricao, p.forma_pagamento, null::uuid,
         case p.tipo when 'pagamento' then 'rateio_pagamento' else 'rateio_estorno' end
    from rateio_pagamentos p join rateios r on r.id = p.rateio_id
$tag_fluxo$;

-- limpeza de órfãos (006): arquivos vinculados a comprovantes de rateio também NUNCA são removidos
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
        and not exists (select 1 from public.comprovantes_rateio c2 where c2.storage_path = o.name)
      order by o.created_at' using p_tolerancia;
end;
$tag_orfaos$;

-- alertas: acrescenta "despesa compartilhada com saldo externo vencido"
create or replace function alertas_automaticos(p_loja_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $tag_alertas$
declare
  tz constant text := 'America/Sao_Paulo';
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  r jsonb := '[]'::jsonb; n int; s numeric;
begin
  select count(*), coalesce(sum(saldo), 0) into n, s from contas_abertas() c where c.loja_id = p_loja_id and c.vencimento is not null and c.vencimento < v_hoje;
  if n > 0 then r := r || jsonb_build_array(jsonb_build_object('chave', 'contas_vencidas', 'prioridade', 'urgente', 'acao', 'financeiro',
    'titulo', n || ' conta(s) vencida(s)', 'descricao', 'Saldo vencido: R$ ' || to_char(s, 'FM999G999G990D00'), 'assinatura', n || ':' || s)); end if;

  select count(*), coalesce(sum(x.v), 0) into n, s from (
    select p.valor as v from pagamentos_lancamento p join financeiro_lancamentos l on l.id = p.lancamento_id
     where p.loja_id = p_loja_id and p.tipo = 'pagamento' and l.exige_comprovante
       and not exists (select 1 from pagamentos_lancamento e where e.estorno_de = p.id)
       and not exists (select 1 from envios_comprovante v where v.pagamento_id = p.id)
    union all
    select l.valor from financeiro_lancamentos l
     where l.loja_id = p_loja_id and l.status = 'pago' and l.exige_comprovante and l.comprovante_enviado_em is null
       and not exists (select 1 from pagamentos_lancamento p where p.lancamento_id = l.id)) x;
  if n > 0 then r := r || jsonb_build_array(jsonb_build_object('chave', 'comprovantes_pendentes', 'prioridade', 'atencao', 'acao', 'financeiro',
    'titulo', n || ' comprovante(s) com envio pendente', 'descricao', 'Pagamentos de contas que exigem comprovante e ainda não tiveram o envio confirmado.', 'assinatura', n || ':' || s)); end if;

  select count(*) into n from rateios rt join rateio_parcelas pa on pa.rateio_id = rt.id and pa.versao = rt.versao and pa.ativa and pa.loja_id = p_loja_id
   where rt.status = 'ativo' and rt.vencimento is not null and rt.vencimento < v_hoje
     and rt.valor_total - coalesce((select sum(case x.tipo when 'pagamento' then x.valor else -x.valor end) from rateio_pagamentos x where x.rateio_id = rt.id), 0) > 0;
  if n > 0 then r := r || jsonb_build_array(jsonb_build_object('chave', 'rateios_vencidos', 'prioridade', 'urgente', 'acao', 'financeiro',
    'titulo', n || ' despesa(s) compartilhada(s) com saldo externo vencido', 'descricao', 'O valor externo ainda não foi pago por completo e o vencimento passou.',
    'assinatura', (select string_agg(r2.id::text, ',' order by r2.id) from rateios r2 join rateio_parcelas pa2 on pa2.rateio_id = r2.id and pa2.versao = r2.versao and pa2.ativa and pa2.loja_id = p_loja_id
        where r2.status = 'ativo' and r2.vencimento < v_hoje and r2.valor_total - coalesce((select sum(case x.tipo when 'pagamento' then x.valor else -x.valor end) from rateio_pagamentos x where x.rateio_id = r2.id), 0) > 0))); end if;

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

-- ---------- 9) Segurança ----------
alter table rateios enable row level security;
alter table rateio_parcelas enable row level security;
alter table rateio_pagamentos enable row level security;
alter table rateio_reembolsos enable row level security;
alter table comprovantes_rateio enable row level security;
alter table rateio_auditoria enable row level security;
revoke all on rateios, rateio_parcelas, rateio_pagamentos, rateio_reembolsos, comprovantes_rateio, rateio_auditoria from public, anon, authenticated;

revoke execute on function public.rateio_audit(uuid, uuid, text, text, jsonb), public.rateio_pode_envolver(uuid[]), public.rateio_visivel(uuid),
  public.rateio_calcular(numeric, text, jsonb), public.rateio_posicoes(uuid), public.rateio_pago_externo(uuid), public.rateio_validar(uuid),
  public.rateio_sem_movimento_liquido(uuid), public.trg_rateio_guard() from public, anon, authenticated;
revoke execute on function public.rateio_previa(numeric, text, jsonb), public.criar_rateio(text, text, numeric, date, boolean, text, jsonb, uuid),
  public.revisar_rateio(uuid, text, numeric, date, text, jsonb, text), public.cancelar_rateio(uuid, text),
  public.registrar_pagamento_rateio(uuid, uuid, numeric, date, text, text, uuid), public.estornar_pagamento_rateio(uuid, text),
  public.registrar_reembolso(uuid, uuid, uuid, numeric, date, text, uuid), public.estornar_reembolso(uuid, text),
  public.registrar_comprovante_rateio(uuid, uuid, text, text, text, integer), public.listar_rateios(uuid, text), public.rateio_detalhe(uuid) from public, anon;
-- funções recriadas acima mantêm as permissões anteriores; reforça as que não podem ser chamadas pelo painel
revoke execute on function public.fluxo_pago_itens(), public.alertas_automaticos(uuid) from public, anon, authenticated;
revoke execute on function public.comprovantes_orfaos(interval) from public, anon, authenticated;
grant execute on function public.comprovantes_orfaos(interval) to service_role;

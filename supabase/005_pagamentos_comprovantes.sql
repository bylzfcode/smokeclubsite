-- ============================================================
-- 005_pagamentos_comprovantes.sql — Pagamentos parciais e comprovantes privados nas CONTAS do financeiro.
-- Ordem de aplicação (nada disto foi aplicado no projeto remoto):
--   schema.sql -> 002_melhorias.sql -> 003_caixa_avisos.sql -> 004_entradas_sem_caixa.sql -> 005_pagamentos_comprovantes.sql
-- Não toca em vendas, pedidos, estoque nem catálogo. Não escreve mais em migrações anteriores (recria só funções de leitura
-- e de "pagar" para que enxerguem pagamentos parciais).
--
-- COMO OS DADOS EXISTENTES SÃO TRATADOS (nada é reescrito, nenhum registro é alterado):
--  * Lançamento antigo com status 'pago' e SEM pagamentos novos = "legado quitado": conta como pago o valor inteiro, na data
--    em que já constava (data_ref). Não ganha pagamento retroativo, não pode ser estornado por aqui e não aceita novo pagamento.
--  * Lançamento antigo 'pendente'/'atrasado' sem pagamentos: saldo = valor inteiro; aceita pagamentos normalmente.
--    ('atrasado' continua aceito no banco por compatibilidade, mas "vencida" agora é calculado pela data de vencimento.)
--  * Entradas de venda e estornos de venda (lançados por registrar_venda/cancelar_venda) seguem como estavam e não aceitam pagamentos.
--  * A marcação antiga comprovante_enviado_em continua existindo SOMENTE para lançamentos legados. Ela NÃO vira "arquivo anexado"
--    nem "envio confirmado" de nenhum pagamento novo.
--  * Pagamentos de contas NÃO movimentam o caixa (gaveta). Não há integração, logo não há dupla contagem: despesa paga em
--    dinheiro da gaveta continua sendo lançada no Caixa (retirada/saída), como antes.
-- Datas exibidas em America/Sao_Paulo; valores em centavos (numeric(12,2)).
-- ============================================================

-- ---------- 1) Contas: novas situações e colunas ----------
do $mig$
declare r record;
begin
  for r in select conname from pg_constraint
            where conrelid = 'public.financeiro_lancamentos'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%pendente%' loop
    execute format('alter table public.financeiro_lancamentos drop constraint %I', r.conname);
  end loop;
end
$mig$;
alter table financeiro_lancamentos add constraint chk_fin_status check (status in ('pago','pendente','atrasado','parcial','cancelada'));
alter table financeiro_lancamentos add column if not exists cancelada_em timestamptz;
alter table financeiro_lancamentos add column if not exists cancelada_por uuid references perfis(id);
alter table financeiro_lancamentos add column if not exists motivo_cancelamento text;
alter table financeiro_lancamentos add column if not exists chave_criacao uuid;
create unique index if not exists uq_fin_chave_criacao on financeiro_lancamentos (loja_id, chave_criacao) where chave_criacao is not null;
create index if not exists idx_fin_cancelada_por on financeiro_lancamentos (cancelada_por);

-- ---------- 2) Tabelas novas (acesso só pelas funções) ----------
create table if not exists pagamentos_lancamento (
  id uuid primary key default gen_random_uuid(),
  lancamento_id uuid not null references financeiro_lancamentos(id),
  loja_id uuid not null references lojas(id),
  tipo text not null default 'pagamento' check (tipo in ('pagamento','estorno')),
  valor numeric(12,2) not null check (valor > 0),
  data_pagamento date not null,
  forma_pagamento text not null check (forma_pagamento in ('Pix','Transferência','Boleto','Cartão','Débito','Crédito','Dinheiro','Outro')),
  observacao text,
  motivo text,
  estorno_de uuid unique references pagamentos_lancamento(id),
  chave uuid not null,
  criado_por uuid not null references perfis(id),
  criado_em timestamptz not null default now(),
  constraint chk_pag_estorno check ((tipo = 'estorno') = (estorno_de is not null)),
  constraint uq_pag_chave unique (loja_id, chave)
);
create index if not exists idx_pag_lanc on pagamentos_lancamento (lancamento_id, criado_em);
create index if not exists idx_pag_loja on pagamentos_lancamento (loja_id, data_pagamento);
create index if not exists idx_pag_criado_por on pagamentos_lancamento (criado_por);

create table if not exists comprovantes_pagamento (
  id uuid primary key default gen_random_uuid(),
  pagamento_id uuid not null references pagamentos_lancamento(id),
  lancamento_id uuid not null references financeiro_lancamentos(id),
  loja_id uuid not null references lojas(id),
  storage_path text not null unique,
  nome_original text,
  mime text not null check (mime in ('application/pdf','image/jpeg','image/png','image/webp')),
  tamanho integer not null check (tamanho between 1 and 5242880),
  enviado_por uuid not null references perfis(id),
  enviado_em timestamptz not null default now()
);
create index if not exists idx_comp_pag on comprovantes_pagamento (pagamento_id);
create index if not exists idx_comp_lanc on comprovantes_pagamento (lancamento_id);
create index if not exists idx_comp_loja on comprovantes_pagamento (loja_id);
create index if not exists idx_comp_enviado_por on comprovantes_pagamento (enviado_por);

-- "envio manual confirmado": alguém confirma que enviou o comprovante (por fora do sistema). Independe de haver arquivo.
create table if not exists envios_comprovante (
  pagamento_id uuid primary key references pagamentos_lancamento(id),
  loja_id uuid not null references lojas(id),
  confirmado_por uuid not null references perfis(id),
  confirmado_em timestamptz not null default now(),
  observacao text
);
create index if not exists idx_envios_loja on envios_comprovante (loja_id);
create index if not exists idx_envios_por on envios_comprovante (confirmado_por);

create table if not exists financeiro_auditoria (
  id uuid primary key default gen_random_uuid(),
  lancamento_id uuid references financeiro_lancamentos(id),
  pagamento_id uuid references pagamentos_lancamento(id),
  loja_id uuid not null references lojas(id),
  acao text not null check (acao in ('conta_criada','pagamento','estorno_pagamento','comprovante_anexado','envio_confirmado','conta_cancelada')),
  por uuid references perfis(id),
  em timestamptz not null default now(),
  motivo text,
  detalhes jsonb not null default '{}'::jsonb
);
create index if not exists idx_faud_lanc on financeiro_auditoria (lancamento_id, em);
create index if not exists idx_faud_pag on financeiro_auditoria (pagamento_id);
create index if not exists idx_faud_loja on financeiro_auditoria (loja_id);
create index if not exists idx_faud_por on financeiro_auditoria (por);

-- Registros confirmados não mudam nem somem (correção = estorno).
create or replace function trg_fin_imutavel() returns trigger
language plpgsql set search_path = public as $tag_trg_fin_imutavel$
begin
  raise exception 'Registro financeiro confirmado não pode ser alterado ou apagado — use estorno';
end;
$tag_trg_fin_imutavel$;
drop trigger if exists pagamentos_imutavel on pagamentos_lancamento;
create trigger pagamentos_imutavel before update or delete on pagamentos_lancamento for each row execute function trg_fin_imutavel();
drop trigger if exists comprovantes_imutavel on comprovantes_pagamento;
create trigger comprovantes_imutavel before update or delete on comprovantes_pagamento for each row execute function trg_fin_imutavel();
drop trigger if exists envios_imutavel on envios_comprovante;
create trigger envios_imutavel before update or delete on envios_comprovante for each row execute function trg_fin_imutavel();
drop trigger if exists fin_auditoria_imutavel on financeiro_auditoria;
create trigger fin_auditoria_imutavel before update or delete on financeiro_auditoria for each row execute function trg_fin_imutavel();

create or replace function trg_pagamento_guard() returns trigger
language plpgsql set search_path = public as $tag_trg_pagamento_guard$
declare v_loja uuid;
begin
  select loja_id into v_loja from financeiro_lancamentos where id = new.lancamento_id;
  if v_loja is distinct from new.loja_id then raise exception 'Pagamento e conta de lojas diferentes'; end if;
  return new;
end;
$tag_trg_pagamento_guard$;
drop trigger if exists pagamento_guard on pagamentos_lancamento;
create trigger pagamento_guard before insert on pagamentos_lancamento for each row execute function trg_pagamento_guard();

-- ---------- 3) Funções de apoio (cálculos únicos, usados por todos os resumos) ----------
create or replace function fin_audit(p_lanc uuid, p_pag uuid, p_loja uuid, p_acao text, p_motivo text, p_det jsonb) returns void
language sql security definer set search_path = public as $tag_fin_audit$
  insert into financeiro_auditoria (lancamento_id, pagamento_id, loja_id, acao, por, motivo, detalhes) values (p_lanc, p_pag, p_loja, p_acao, auth.uid(), p_motivo, coalesce(p_det, '{}'::jsonb))
$tag_fin_audit$;

create or replace function fin_liquido(p_lanc uuid) returns numeric
language sql stable security definer set search_path = public as $tag_fin_liquido$
  select coalesce(sum(case tipo when 'pagamento' then valor else -valor end), 0) from pagamentos_lancamento where lancamento_id = p_lanc
$tag_fin_liquido$;

-- Contas em aberto (pendente/parcial/atrasado) com saldo > 0. Legado 'pago' e canceladas ficam de fora.
create or replace function contas_abertas() returns table (lancamento_id uuid, loja_id uuid, tipo text, vencimento date, valor numeric, pago numeric, saldo numeric)
language sql stable security definer set search_path = public as $tag_contas_abertas$
  select l.id, l.loja_id, l.tipo, l.vencimento, l.valor, coalesce(p.liq, 0), l.valor - coalesce(p.liq, 0)
    from financeiro_lancamentos l
    left join (select lancamento_id, sum(case tipo when 'pagamento' then valor else -valor end) as liq from pagamentos_lancamento group by 1) p on p.lancamento_id = l.id
   where l.status in ('pendente','parcial','atrasado') and l.valor - coalesce(p.liq, 0) > 0
$tag_contas_abertas$;

-- Dinheiro que de fato entrou/saiu (legado quitado + pagamentos + estornos de pagamento). efeito > 0 entra; < 0 sai.
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
$tag_fluxo$;

create or replace function fin_recalcular(p_lanc uuid) returns text
language plpgsql security definer set search_path = public as $tag_fin_recalcular$
declare l financeiro_lancamentos%rowtype; v_liq numeric; v_novo text;
begin
  select * into l from financeiro_lancamentos where id = p_lanc for update;
  if l.status = 'cancelada' then return l.status; end if;
  v_liq := fin_liquido(p_lanc);
  v_novo := case when v_liq >= l.valor then 'pago' when v_liq > 0 then 'parcial' else 'pendente' end;
  update financeiro_lancamentos set status = v_novo,
         pago_em = case when v_novo = 'pago' then coalesce(pago_em, now()) else null end where id = p_lanc;
  return v_novo;
end;
$tag_fin_recalcular$;

-- ---------- 4) Operações ----------
create or replace function criar_conta(p_loja_id uuid, p_tipo text, p_categoria text, p_descricao text, p_valor numeric, p_vencimento date,
  p_forma text, p_exige_comprovante boolean, p_chave uuid) returns uuid
language plpgsql security definer set search_path = public as $tag_criar_conta$
declare v_id uuid;
begin
  if not tenho_acesso_a_loja(p_loja_id) then raise exception 'Você não tem permissão para esta loja'; end if;
  if p_chave is null then raise exception 'Chave de repetição obrigatória'; end if;
  if p_tipo not in ('entrada','saida') then raise exception 'Tipo inválido'; end if;
  if nullif(trim(coalesce(p_categoria, '')), '') is null or lower(trim(p_categoria)) in ('venda','estorno') then raise exception 'Categoria inválida'; end if;
  perform valida_valor(p_valor);
  perform pg_advisory_xact_lock(hashtext('conta:' || p_loja_id::text || p_chave::text));
  select id into v_id from financeiro_lancamentos where loja_id = p_loja_id and chave_criacao = p_chave;
  if v_id is not null then return v_id; end if;
  insert into financeiro_lancamentos (loja_id, tipo, categoria, descricao, valor, forma_pagamento, status, vencimento, exige_comprovante, criado_por, chave_criacao)
  values (p_loja_id, p_tipo, trim(p_categoria), nullif(trim(coalesce(p_descricao, '')), ''), p_valor, nullif(trim(coalesce(p_forma, '')), ''), 'pendente',
          p_vencimento, coalesce(p_exige_comprovante, false), auth.uid(), p_chave) returning id into v_id;
  perform fin_audit(v_id, null, p_loja_id, 'conta_criada', null, jsonb_build_object('valor', p_valor, 'tipo', p_tipo, 'vencimento', p_vencimento));
  return v_id;
end;
$tag_criar_conta$;

create or replace function registrar_pagamento(p_lancamento_id uuid, p_valor numeric, p_data date, p_forma text, p_observacao text, p_chave uuid) returns jsonb
language plpgsql security definer set search_path = public as $tag_registrar_pagamento$
declare
  l financeiro_lancamentos%rowtype; e pagamentos_lancamento%rowtype; v_id uuid; v_liq numeric; v_status text;
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date; v_data date := coalesce(p_data, (now() at time zone 'America/Sao_Paulo')::date);
begin
  select * into l from financeiro_lancamentos where id = p_lancamento_id for update;   -- serializa pagamentos da mesma conta
  if l.id is null then raise exception 'Conta não encontrada'; end if;
  if l.loja_id is null or not tenho_acesso_a_loja(l.loja_id) then raise exception 'Você não tem permissão para esta conta'; end if;
  if p_chave is null then raise exception 'Chave de repetição obrigatória'; end if;
  -- repetição da mesma requisição (clique duplo / reenvio): devolve o pagamento já gravado, sem gravar de novo
  select * into e from pagamentos_lancamento where loja_id = l.loja_id and chave = p_chave;
  if e.id is not null then
    if e.lancamento_id <> l.id or e.tipo <> 'pagamento' or e.valor <> p_valor then raise exception 'Esta chave de repetição já foi usada em outra operação'; end if;
    return jsonb_build_object('pagamento_id', e.id, 'total_pago', fin_liquido(l.id), 'saldo', l.valor - fin_liquido(l.id), 'situacao', l.status, 'repetida', true);
  end if;
  if l.venda_id is not null or lower(l.categoria) in ('venda','estorno') then raise exception 'Lançamentos de venda não recebem pagamento por aqui'; end if;
  if l.status = 'cancelada' then raise exception 'Conta cancelada não recebe pagamentos'; end if;
  if l.status = 'pago' then raise exception 'Esta conta já está quitada'; end if;
  perform valida_valor(p_valor);
  if v_data > v_hoje then raise exception 'A data do pagamento não pode ser futura'; end if;
  if p_forma is null or p_forma not in ('Pix','Transferência','Boleto','Cartão','Débito','Crédito','Dinheiro','Outro') then raise exception 'Forma de pagamento inválida'; end if;
  v_liq := fin_liquido(l.id);
  if p_valor > l.valor - v_liq then
    raise exception 'Pagamento (R$ %) maior que o saldo da conta (R$ %)', to_char(p_valor, 'FM999G999G990D00'), to_char(l.valor - v_liq, 'FM999G999G990D00');
  end if;
  insert into pagamentos_lancamento (lancamento_id, loja_id, tipo, valor, data_pagamento, forma_pagamento, observacao, chave, criado_por)
  values (l.id, l.loja_id, 'pagamento', p_valor, v_data, p_forma, nullif(trim(coalesce(p_observacao, '')), ''), p_chave, auth.uid()) returning id into v_id;
  v_status := fin_recalcular(l.id);
  perform fin_audit(l.id, v_id, l.loja_id, 'pagamento', null, jsonb_build_object('valor', p_valor, 'forma', p_forma, 'data', v_data, 'situacao', v_status));
  v_liq := fin_liquido(l.id);
  return jsonb_build_object('pagamento_id', v_id, 'total_pago', v_liq, 'saldo', l.valor - v_liq, 'situacao', v_status, 'repetida', false);
end;
$tag_registrar_pagamento$;

-- Estorno de pagamento confirmado: novo registro ligado ao original (que permanece intacto), com motivo e auditoria.
create or replace function estornar_pagamento(p_pagamento_id uuid, p_motivo text) returns jsonb
language plpgsql security definer set search_path = public as $tag_estornar_pagamento$
declare p pagamentos_lancamento%rowtype; l financeiro_lancamentos%rowtype; v_id uuid; v_status text; v_liq numeric;
begin
  select * into p from pagamentos_lancamento where id = p_pagamento_id;
  if p.id is null then raise exception 'Pagamento não encontrado'; end if;
  select * into l from financeiro_lancamentos where id = p.lancamento_id for update;
  if not pode_gerir_loja(l.loja_id) then raise exception 'Só gerente ou dono pode estornar pagamentos'; end if;
  if length(trim(coalesce(p_motivo, ''))) < 5 then raise exception 'Informe o motivo do estorno (mínimo 5 letras)'; end if;
  if p.tipo <> 'pagamento' then raise exception 'Um estorno não pode ser estornado'; end if;
  if exists (select 1 from pagamentos_lancamento where estorno_de = p.id) then raise exception 'Este pagamento já foi estornado'; end if;
  begin
    insert into pagamentos_lancamento (lancamento_id, loja_id, tipo, valor, data_pagamento, forma_pagamento, motivo, estorno_de, chave, criado_por)
    values (p.lancamento_id, p.loja_id, 'estorno', p.valor, (now() at time zone 'America/Sao_Paulo')::date, p.forma_pagamento, trim(p_motivo), p.id, gen_random_uuid(), auth.uid())
    returning id into v_id;
  exception when unique_violation then
    raise exception 'Este pagamento já foi estornado';
  end;
  v_status := fin_recalcular(p.lancamento_id);
  perform fin_audit(p.lancamento_id, v_id, p.loja_id, 'estorno_pagamento', trim(p_motivo), jsonb_build_object('pagamento_original', p.id, 'valor', p.valor, 'situacao', v_status));
  v_liq := fin_liquido(p.lancamento_id);
  return jsonb_build_object('estorno_id', v_id, 'total_pago', v_liq, 'saldo', l.valor - v_liq, 'situacao', v_status);
end;
$tag_estornar_pagamento$;

create or replace function cancelar_conta(p_id uuid, p_motivo text) returns void
language plpgsql security definer set search_path = public as $tag_cancelar_conta$
declare l financeiro_lancamentos%rowtype;
begin
  select * into l from financeiro_lancamentos where id = p_id for update;
  if l.id is null then raise exception 'Conta não encontrada'; end if;
  if not pode_gerir_loja(l.loja_id) then raise exception 'Só gerente ou dono cancela contas'; end if;
  if length(trim(coalesce(p_motivo, ''))) < 5 then raise exception 'Informe o motivo do cancelamento (mínimo 5 letras)'; end if;
  if l.venda_id is not null or lower(l.categoria) in ('venda','estorno') then raise exception 'Lançamentos de venda não são cancelados por aqui'; end if;
  if l.status = 'cancelada' then raise exception 'Conta já cancelada'; end if;
  if exists (select 1 from pagamentos_lancamento where lancamento_id = l.id) then raise exception 'A conta tem pagamentos — estorne-os antes de cancelar'; end if;
  if l.status = 'pago' then raise exception 'Conta quitada não pode ser cancelada'; end if;
  update financeiro_lancamentos set status = 'cancelada', cancelada_em = now(), cancelada_por = auth.uid(), motivo_cancelamento = trim(p_motivo) where id = l.id;
  perform fin_audit(l.id, null, l.loja_id, 'conta_cancelada', trim(p_motivo), jsonb_build_object('valor', l.valor));
end;
$tag_cancelar_conta$;

-- Compatibilidade: "pagar" a conta inteira = pagamento do saldo restante (mesma regra de pagamentos, mesma auditoria).
create or replace function pagar_lancamento(p_id uuid) returns void
language plpgsql security definer set search_path = public as $tag_pagar_lancamento$
declare l financeiro_lancamentos%rowtype;
begin
  select * into l from financeiro_lancamentos where id = p_id;
  if l.id is null then raise exception 'Lançamento não encontrado'; end if;
  if l.loja_id is null or not tenho_acesso_a_loja(l.loja_id) then raise exception 'Você não tem permissão para este lançamento'; end if;
  if l.venda_id is not null then raise exception 'Lançamentos de venda não podem ser alterados; cancele a venda'; end if;
  if l.status = 'pago' then raise exception 'Este lançamento já está pago'; end if;
  perform registrar_pagamento(p_id, l.valor - fin_liquido(p_id), null, coalesce(nullif(l.forma_pagamento, ''), 'Outro'), null, gen_random_uuid());
end;
$tag_pagar_lancamento$;

-- A marcação antiga serve só para lançamentos legados; pagamentos novos usam confirmar_envio_comprovante.
create or replace function marcar_comprovante_enviado(p_id uuid) returns void
language plpgsql security definer set search_path = public as $tag_comprovante$
declare v_loja uuid; v_exige boolean;
begin
  select loja_id, exige_comprovante into v_loja, v_exige from financeiro_lancamentos where id = p_id for update;
  if v_loja is null or not tenho_acesso_a_loja(v_loja) then raise exception 'Lançamento não encontrado ou sem permissão'; end if;
  if not v_exige then raise exception 'Este lançamento não exige comprovante'; end if;
  if exists (select 1 from pagamentos_lancamento where lancamento_id = p_id) then raise exception 'Esta conta tem pagamentos: confirme o envio em cada pagamento'; end if;
  update financeiro_lancamentos set comprovante_enviado_em = coalesce(comprovante_enviado_em, now()) where id = p_id;
end;
$tag_comprovante$;

-- ---------- 5) Comprovantes (arquivo no bucket privado + registro) ----------
-- Caminho: <loja_id>/<pagamento_id>/<uuid>.<pdf|jpg|jpeg|png|webp>
create or replace function pode_enviar_comprovante(p_name text) returns boolean
language plpgsql stable security definer set search_path = public as $tag_pode_enviar$
declare m text[];
begin
  m := regexp_match(coalesce(p_name, ''), '^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/[0-9a-f-]{36}\.(pdf|jpe?g|png|webp)$');
  if m is null then return false; end if;
  return exists (select 1 from pagamentos_lancamento p
                  where p.id = m[2]::uuid and p.loja_id = m[1]::uuid and p.tipo = 'pagamento' and tenho_acesso_a_loja(p.loja_id)
                    and not exists (select 1 from pagamentos_lancamento e where e.estorno_de = p.id));
end;
$tag_pode_enviar$;

create or replace function pode_ver_comprovante(p_name text) returns boolean
language sql stable security definer set search_path = public as $tag_pode_ver_comp$
  select exists (select 1 from comprovantes_pagamento c where c.storage_path = p_name and pode_ver_loja(c.loja_id))
$tag_pode_ver_comp$;

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

create or replace function confirmar_envio_comprovante(p_pagamento_id uuid, p_observacao text default null) returns jsonb
language plpgsql security definer set search_path = public as $tag_confirmar_envio$
declare p pagamentos_lancamento%rowtype; e envios_comprovante%rowtype;
begin
  select * into p from pagamentos_lancamento where id = p_pagamento_id;
  if p.id is null or p.tipo <> 'pagamento' then raise exception 'Pagamento não encontrado'; end if;
  if not tenho_acesso_a_loja(p.loja_id) then raise exception 'Você não tem permissão para esta loja'; end if;
  if exists (select 1 from pagamentos_lancamento where estorno_de = p.id) then raise exception 'Pagamento estornado'; end if;
  select * into e from envios_comprovante where pagamento_id = p.id;
  if e.pagamento_id is not null then return jsonb_build_object('confirmado_em', e.confirmado_em, 'repetido', true); end if;
  begin
    insert into envios_comprovante (pagamento_id, loja_id, confirmado_por, observacao) values (p.id, p.loja_id, auth.uid(), nullif(trim(coalesce(p_observacao, '')), ''))
    returning * into e;
  exception when unique_violation then
    select * into e from envios_comprovante where pagamento_id = p.id;
    return jsonb_build_object('confirmado_em', e.confirmado_em, 'repetido', true);
  end;
  perform fin_audit(p.lancamento_id, p.id, p.loja_id, 'envio_confirmado', null, jsonb_build_object('observacao', e.observacao));
  return jsonb_build_object('confirmado_em', e.confirmado_em, 'repetido', false);
end;
$tag_confirmar_envio$;

-- ---------- 6) Consultas ----------
create or replace function listar_contas(p_loja_id uuid, p_inicio date default null, p_fim date default null, p_situacao text default null) returns jsonb
language plpgsql stable security definer set search_path = public as $tag_listar_contas$
declare tz constant text := 'America/Sao_Paulo'; v_hoje date := (now() at time zone 'America/Sao_Paulo')::date; r jsonb;
begin
  if not pode_ver_loja(p_loja_id) then raise exception 'Você não tem permissão para esta loja'; end if;
  if p_situacao is not null and p_situacao not in ('pendente','parcial','paga','cancelada','vencida','comprovante_pendente') then raise exception 'Situação inválida'; end if;
  with calc as (
    select l.*, exists (select 1 from pagamentos_lancamento p where p.lancamento_id = l.id) as tem_pag,
           fin_liquido(l.id) as liquido
      from financeiro_lancamentos l where l.loja_id = p_loja_id),
  c2 as (
    select c.*, case when c.tem_pag then c.liquido when c.status = 'pago' then c.valor else 0 end as pago_total from calc c),
  c3 as (
    select c.*, case when c.status = 'cancelada' then 0 else c.valor - c.pago_total end as saldo_calc,
           case c.status when 'cancelada' then 'cancelada' when 'pago' then 'paga' when 'parcial' then 'parcial' else 'pendente' end as situacao_calc,
           (select count(*) from comprovantes_pagamento cp where cp.lancamento_id = c.id) as qtd_comp,
           (select count(*) from pagamentos_lancamento p where p.lancamento_id = c.id and p.tipo = 'pagamento') as qtd_pag,
           (case when c.exige_comprovante then
              (select count(*) from pagamentos_lancamento p where p.lancamento_id = c.id and p.tipo = 'pagamento'
                  and not exists (select 1 from pagamentos_lancamento e where e.estorno_de = p.id) and not exists (select 1 from envios_comprovante v where v.pagamento_id = p.id))
              + case when not c.tem_pag and c.status = 'pago' and c.comprovante_enviado_em is null then 1 else 0 end
            else 0 end) as envios_pend
      from c2 c),
  c4 as (select c.*, (c.situacao_calc in ('pendente','parcial') and c.vencimento is not null and c.vencimento < v_hoje) as vencida from c3 c)
  select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'tipo', c.tipo, 'categoria', c.categoria, 'descricao', c.descricao, 'valor', c.valor, 'total_pago', c.pago_total,
           'saldo', c.saldo_calc, 'situacao', c.situacao_calc, 'vencida', c.vencida, 'vencimento', c.vencimento, 'forma_pagamento', c.forma_pagamento, 'data_ref', c.data_ref,
           'criado_em', c.criado_em, 'exige_comprovante', c.exige_comprovante, 'qtd_pagamentos', c.qtd_pag, 'qtd_comprovantes', c.qtd_comp, 'envios_pendentes', c.envios_pend,
           'legado', (not c.tem_pag and c.status = 'pago'), 'venda_id', c.venda_id) order by c.data_ref desc, c.id), '[]'::jsonb)
    into r
    from (select * from c4 c
           where (p_situacao is null or (p_situacao = 'vencida' and c.vencida) or (p_situacao = 'comprovante_pendente' and c.envios_pend > 0) or c.situacao_calc = p_situacao)
             and (p_situacao in ('pendente','parcial','vencida','comprovante_pendente')
                  or ((p_inicio is null or (c.data_ref at time zone tz)::date >= p_inicio) and (p_fim is null or (c.data_ref at time zone tz)::date <= p_fim)))
           order by c.data_ref desc, c.id limit 500) c;
  return r;
end;
$tag_listar_contas$;

create or replace function conta_detalhe(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $tag_conta_detalhe$
declare l financeiro_lancamentos%rowtype; v_tem boolean; v_pago numeric; v_saldo numeric; v_hoje date := (now() at time zone 'America/Sao_Paulo')::date; v_sit text;
begin
  select * into l from financeiro_lancamentos where id = p_id;
  if l.id is null or l.loja_id is null or not pode_ver_loja(l.loja_id) then raise exception 'Conta não encontrada ou sem permissão'; end if;
  v_tem := exists (select 1 from pagamentos_lancamento where lancamento_id = l.id);
  v_pago := case when v_tem then fin_liquido(l.id) when l.status = 'pago' then l.valor else 0 end;
  v_saldo := case when l.status = 'cancelada' then 0 else l.valor - v_pago end;
  v_sit := case l.status when 'cancelada' then 'cancelada' when 'pago' then 'paga' when 'parcial' then 'parcial' else 'pendente' end;
  return jsonb_build_object(
    'conta', jsonb_build_object('id', l.id, 'loja_id', l.loja_id, 'tipo', l.tipo, 'categoria', l.categoria, 'descricao', l.descricao, 'valor', l.valor, 'vencimento', l.vencimento,
       'situacao', v_sit, 'vencida', v_sit in ('pendente','parcial') and l.vencimento is not null and l.vencimento < v_hoje, 'total_pago', v_pago, 'saldo', v_saldo,
       'exige_comprovante', l.exige_comprovante, 'legado', (not v_tem and l.status = 'pago'), 'venda_id', l.venda_id,
       'marcacao_antiga_comprovante', l.comprovante_enviado_em, 'criado_em', l.criado_em, 'criado_por_nome', (select nome from perfis where id = l.criado_por),
       'cancelada_em', l.cancelada_em, 'motivo_cancelamento', l.motivo_cancelamento),
    'pagamentos', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'tipo', p.tipo, 'valor', p.valor, 'data_pagamento', p.data_pagamento, 'forma_pagamento', p.forma_pagamento,
        'observacao', p.observacao, 'motivo', p.motivo, 'estorno_de', p.estorno_de, 'criado_em', p.criado_em, 'criado_por_nome', (select nome from perfis where id = p.criado_por),
        'estornado', exists (select 1 from pagamentos_lancamento e where e.estorno_de = p.id),
        'comprovantes', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'nome', c.nome_original, 'mime', c.mime, 'tamanho', c.tamanho, 'path', c.storage_path,
                          'enviado_em', c.enviado_em, 'enviado_por_nome', (select nome from perfis where id = c.enviado_por)) order by c.enviado_em), '[]'::jsonb)
                         from comprovantes_pagamento c where c.pagamento_id = p.id),
        'envio', (select jsonb_build_object('confirmado_em', v.confirmado_em, 'confirmado_por_nome', (select nome from perfis where id = v.confirmado_por), 'observacao', v.observacao)
                    from envios_comprovante v where v.pagamento_id = p.id)) order by p.criado_em, p.id), '[]'::jsonb)
        from pagamentos_lancamento p where p.lancamento_id = l.id),
    'auditoria', (select coalesce(jsonb_agg(jsonb_build_object('acao', a.acao, 'em', a.em, 'por', (select nome from perfis where id = a.por), 'motivo', a.motivo) order by a.em, a.id), '[]'::jsonb)
                    from financeiro_auditoria a where a.lancamento_id = l.id));
end;
$tag_conta_detalhe$;

-- ---------- 7) Resumos que passam a enxergar pagamentos parciais (mesmo formato de retorno de antes) ----------
create or replace function painel_resumo(p_loja_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $tag_painel_resumo$
declare
  tz constant text := 'America/Sao_Paulo';
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  v_mes date := date_trunc('month', now() at time zone 'America/Sao_Paulo')::date;
begin
  if not tenho_acesso_a_loja(p_loja_id) then
    raise exception 'Sem permissão para esta loja';
  end if;
  return jsonb_build_object(
    'hoje', (select jsonb_build_object('qtd', count(*), 'total', coalesce(sum(total),0))
             from vendas where loja_id = p_loja_id and status = 'concluida' and (criado_em at time zone tz)::date = v_hoje),
    'mes', (select jsonb_build_object('qtd', count(*), 'total', coalesce(sum(total),0))
            from vendas where loja_id = p_loja_id and status = 'concluida' and (criado_em at time zone tz)::date >= v_mes),
    'saldo_caixa', (select coalesce(sum(efeito),0) from fluxo_pago_itens() f where f.loja_id = p_loja_id),
    'a_receber', (select jsonb_build_object('qtd', count(*), 'total', coalesce(sum(saldo),0)) from contas_abertas() c where c.loja_id = p_loja_id and c.tipo = 'entrada'),
    'a_pagar', (select jsonb_build_object('qtd', count(*), 'total', coalesce(sum(saldo),0)) from contas_abertas() c where c.loja_id = p_loja_id and c.tipo = 'saida'),
    'atrasados', (select jsonb_build_object('qtd', count(*), 'total', coalesce(sum(saldo),0)) from contas_abertas() c where c.loja_id = p_loja_id and c.vencimento < v_hoje),
    'por_dia', (select coalesce(jsonb_agg(jsonb_build_object('dia', d.dia, 'total', coalesce(t.total,0), 'qtd', coalesce(t.qtd,0)) order by d.dia), '[]'::jsonb)
                from generate_series(v_hoje - 6, v_hoje, interval '1 day') as g(dia_ts)
                cross join lateral (select g.dia_ts::date as dia) d
                left join (select (criado_em at time zone tz)::date as dia, sum(total) as total, count(*) as qtd
                           from vendas where loja_id = p_loja_id and status = 'concluida'
                             and (criado_em at time zone tz)::date >= v_hoje - 6
                           group by 1) t on t.dia = d.dia),
    'top_produtos', (select coalesce(jsonb_agg(x), '[]'::jsonb) from (
                       select vi.nome_snapshot as nome, sum(vi.quantidade)::int as qtd,
                              sum(vi.quantidade * vi.preco_unitario) as total
                       from venda_itens vi join vendas v on v.id = vi.venda_id
                       where v.loja_id = p_loja_id and v.status = 'concluida' and (v.criado_em at time zone tz)::date >= v_mes
                       group by vi.nome_snapshot order by sum(vi.quantidade) desc, vi.nome_snapshot limit 5) x)
  );
end;
$tag_painel_resumo$;

create or replace function financeiro_resumo(p_loja_id uuid, p_inicio date, p_fim date) returns jsonb
language plpgsql stable security definer set search_path = public as $tag_financeiro_resumo$
declare
  tz constant text := 'America/Sao_Paulo';
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  v_entradas numeric; v_saidas numeric;
begin
  if not tenho_acesso_a_loja(p_loja_id) then
    raise exception 'Sem permissão para esta loja';
  end if;
  select coalesce(sum(efeito) filter (where efeito > 0), 0), coalesce(-sum(efeito) filter (where efeito < 0), 0)
    into v_entradas, v_saidas
    from fluxo_pago_itens() f
   where f.loja_id = p_loja_id
     and (p_inicio is null or (f.data_ref at time zone tz)::date >= p_inicio)
     and (p_fim is null or (f.data_ref at time zone tz)::date <= p_fim);
  return jsonb_build_object(
    'entradas', v_entradas, 'saidas', v_saidas, 'saldo_periodo', v_entradas - v_saidas,
    'saldo_caixa', (select coalesce(sum(efeito),0) from fluxo_pago_itens() f where f.loja_id = p_loja_id),
    'a_receber', (select jsonb_build_object('qtd', count(*), 'total', coalesce(sum(saldo),0)) from contas_abertas() c where c.loja_id = p_loja_id and c.tipo = 'entrada'),
    'a_pagar', (select jsonb_build_object('qtd', count(*), 'total', coalesce(sum(saldo),0)) from contas_abertas() c where c.loja_id = p_loja_id and c.tipo = 'saida'),
    'atrasados', (select jsonb_build_object('qtd', count(*), 'total', coalesce(sum(saldo),0)) from contas_abertas() c where c.loja_id = p_loja_id and c.vencimento < v_hoje)
  );
end;
$tag_financeiro_resumo$;

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
  fin as (select f.loja_id, (f.data_ref at time zone tz)::date as dia, f.efeito, (f.categoria = 'estorno' or f.origem = 'estorno_pagamento') as eh_estorno
           from fluxo_pago_itens() f join lj on lj.id = f.loja_id
          where (f.data_ref at time zone tz)::date between v_ini and v_fim and (p_responsavel is null or f.criado_por = p_responsavel)),
  chaves as (select loja_id, dia from cx
             union select loja_id, dia from mv where p_situacao is null
             union select loja_id, dia from fin where p_situacao is null),
  dias as (
    select k.loja_id, k.dia, (select nome from lj where lj.id = k.loja_id) as loja_nome,
      coalesce((select sum(saldo_inicial) from cx where cx.loja_id = k.loja_id and cx.dia = k.dia), 0) as abertura,
      coalesce((select sum(valor) from mv where mv.loja_id = k.loja_id and mv.dia = k.dia and mv.tipo <> 'estorno' and mv.sentido = 1), 0)
        + coalesce((select sum(efeito) from fin where fin.loja_id = k.loja_id and fin.dia = k.dia and not fin.eh_estorno and fin.efeito > 0), 0) as entradas,
      coalesce((select sum(valor) from mv where mv.loja_id = k.loja_id and mv.dia = k.dia and mv.tipo <> 'estorno' and mv.sentido = -1), 0)
        + coalesce((select -sum(efeito) from fin where fin.loja_id = k.loja_id and fin.dia = k.dia and not fin.eh_estorno and fin.efeito < 0), 0) as saidas,
      coalesce((select sum(sentido * valor) from mv where mv.loja_id = k.loja_id and mv.dia = k.dia and mv.tipo = 'estorno'), 0)
        + coalesce((select sum(efeito) from fin where fin.loja_id = k.loja_id and fin.dia = k.dia and fin.eh_estorno), 0) as estornos,
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
    'lancamentos', (select coalesce(jsonb_agg(jsonb_build_object('id', f.lancamento_id, 'tipo', f.tipo, 'categoria', f.categoria, 'descricao', f.descricao, 'valor', abs(f.efeito),
                    'efeito', f.efeito, 'forma_pagamento', f.forma_pagamento, 'data_ref', f.data_ref, 'venda_id', f.venda_id, 'origem', f.origem) order by f.data_ref, f.lancamento_id), '[]'::jsonb)
                    from fluxo_pago_itens() f where f.loja_id = p_loja_id and (f.data_ref at time zone tz)::date = p_dia));
end;
$tag_detalhe_dia$;

-- Alertas distintos: "saldo vencido" (contas com saldo) e "envio de comprovante pendente" (pagamentos sem envio confirmado).
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

-- ---------- 8) Armazenamento privado (Supabase Storage) ----------
-- Bucket privado, 5 MB, só PDF/JPG/PNG/WEBP. Sem política de UPDATE/DELETE: arquivos enviados não são trocados nem apagados pelo cliente.
do $storage$
begin
  if to_regclass('storage.buckets') is not null and to_regclass('storage.objects') is not null then
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('comprovantes', 'comprovantes', false, 5242880, array['application/pdf','image/jpeg','image/png','image/webp'])
    on conflict (id) do update set public = false, file_size_limit = 5242880, allowed_mime_types = array['application/pdf','image/jpeg','image/png','image/webp'];
    drop policy if exists comprovantes_enviar on storage.objects;
    drop policy if exists comprovantes_ler on storage.objects;
    create policy comprovantes_enviar on storage.objects for insert to authenticated
      with check (bucket_id = 'comprovantes' and public.pode_enviar_comprovante(name));
    create policy comprovantes_ler on storage.objects for select to authenticated
      using (bucket_id = 'comprovantes' and public.pode_ver_comprovante(name));
  else
    raise notice 'Schema storage não encontrado: bucket e políticas de comprovantes NÃO foram criados (rode no Supabase).';
  end if;
end
$storage$;

-- ---------- 9) Segurança ----------
alter table pagamentos_lancamento enable row level security;
alter table comprovantes_pagamento enable row level security;
alter table envios_comprovante enable row level security;
alter table financeiro_auditoria enable row level security;
revoke all on pagamentos_lancamento, comprovantes_pagamento, envios_comprovante, financeiro_auditoria from public, anon, authenticated;

revoke execute on function public.fin_audit(uuid, uuid, uuid, text, text, jsonb), public.fin_liquido(uuid), public.contas_abertas(), public.fluxo_pago_itens(),
  public.fin_recalcular(uuid), public.trg_fin_imutavel(), public.trg_pagamento_guard() from public, anon, authenticated;
revoke execute on function public.criar_conta(uuid, text, text, text, numeric, date, text, boolean, uuid), public.registrar_pagamento(uuid, numeric, date, text, text, uuid),
  public.estornar_pagamento(uuid, text), public.cancelar_conta(uuid, text), public.registrar_comprovante(uuid, text, text, text, integer),
  public.confirmar_envio_comprovante(uuid, text), public.listar_contas(uuid, date, date, text), public.conta_detalhe(uuid),
  public.pagar_lancamento(uuid), public.marcar_comprovante_enviado(uuid), public.painel_resumo(uuid), public.financeiro_resumo(uuid, date, date),
  public.historico_financeiro(uuid, date, date, uuid, text), public.detalhe_dia_financeiro(uuid, date), public.alertas_automaticos(uuid) from public, anon;
revoke execute on function public.alertas_automaticos(uuid) from authenticated;
-- as políticas do Storage rodam com o papel do usuário: precisam poder chamar só estas duas
revoke execute on function public.pode_enviar_comprovante(text), public.pode_ver_comprovante(text) from public, anon;
grant execute on function public.pode_enviar_comprovante(text), public.pode_ver_comprovante(text) to authenticated;

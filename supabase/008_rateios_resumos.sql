-- ============================================================
-- 008_rateios_resumos.sql — Integra os rateios aos resumos financeiros, SEM duplicar valores.
-- Ordem (nada foi aplicado no projeto remoto): schema.sql -> 002 -> 003 -> 004 -> 005 -> 006 -> 007 -> 008.
-- Não altera contas, pagamentos, rateios, caixa, vendas, pedidos, estoque nem catálogo. Só LEITURA + 2 funções de resumo recriadas
-- com UMA chave nova ("rateios"); as chaves antigas continuam idênticas.
--
-- REGRAS DOS INDICADORES (cada um declara a data que usa em "datas")
--  * Consolidado: cada despesa externa aparece UMA vez (total, pago, saldo externo), qualquer que seja o número de lojas.
--      previsto  = valor_total das despesas ATIVAS cuja DATA PREVISTA está no período (data prevista = vencimento; sem vencimento, a data de criação).
--      pago      = pagamentos externos (líquidos de estornos) cuja DATA DO PAGAMENTO está no período — é a mesma visão de caixa de entradas/saídas.
--      saldo externo pendente / vencido = FOTO DE HOJE (independe do período), como "a pagar" e "atrasadas" das contas exclusivas.
--  * Por loja (separados, nunca somados entre si):
--      parcela de responsabilidade (prevista, no período) · pagamentos externos realizados (no período) ·
--      ACERTO ENTRE LOJAS (foto de hoje): a receber de outras lojas = o que pagou a mais que a parcela, líquido de reembolsos;
--      a reembolsar a outras lojas = parcela ainda não coberta, SÓ em rateios cujo saldo externo já foi quitado (aí o acerto é todo entre lojas);
--      parcela ainda não coberta = o mesmo, em rateios com saldo externo EM ABERTO (pode ser coberta pagando o fornecedor OU reembolsando outra loja).
--      A posição de rateio NUNCA é chamada de dívida ao fornecedor: o saldo externo é outra informação.
--  * Reembolsos internos: informados à parte, NÃO entram como receita nem despesa e não alteram entradas/saídas/saldo.
--  * Permissões: as mesmas do rateio (dono vê tudo; demais, só rateios de que suas lojas participam e só as próprias lojas na seção "por loja").
-- ============================================================

create or replace function rateios_resumo(p_loja_id uuid default null, p_inicio date default null, p_fim date default null) returns jsonb
language plpgsql stable security definer set search_path = public as $tag_rateios_resumo$
declare
  tz constant text := 'America/Sao_Paulo';
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  v_res jsonb;
begin
  if not (eh_dono() or eh_da_equipe()) then raise exception 'Sem permissão'; end if;
  if p_loja_id is not null and not pode_ver_loja(p_loja_id) then raise exception 'Você não tem permissão para esta loja'; end if;
  if p_inicio is not null and p_fim is not null and p_inicio > p_fim then raise exception 'Período inválido'; end if;

  with vis as (
    select r.*, coalesce(r.vencimento, (r.criado_em at time zone tz)::date) as data_prevista, rateio_pago_externo(r.id) as ext
      from rateios r
     where (eh_dono() or exists (select 1 from rateio_parcelas pa where pa.rateio_id = r.id and pa.versao = r.versao and pa.ativa and pa.loja_id in (select minhas_lojas())))
       and (p_loja_id is null or exists (select 1 from rateio_parcelas pa where pa.rateio_id = r.id and pa.versao = r.versao and pa.ativa and pa.loja_id = p_loja_id))),
  ativos as (select v.*, v.valor_total - v.ext as saldo from vis v where v.status = 'ativo'),
  noper as (select a.* from ativos a where (p_inicio is null or a.data_prevista >= p_inicio) and (p_fim is null or a.data_prevista <= p_fim)),
  pagper as (select x.rateio_id, x.loja_id, sum(case x.tipo when 'pagamento' then x.valor else -x.valor end) as liq
               from rateio_pagamentos x join vis v on v.id = x.rateio_id
              where (p_inicio is null or x.data_pagamento >= p_inicio) and (p_fim is null or x.data_pagamento <= p_fim) group by 1, 2),
  reemper as (select x.rateio_id, x.loja_origem, x.loja_destino, sum(case x.tipo when 'reembolso' then x.valor else -x.valor end) as liq
               from rateio_reembolsos x join vis v on v.id = x.rateio_id
              where (p_inicio is null or x.data_reembolso >= p_inicio) and (p_fim is null or x.data_reembolso <= p_fim) group by 1, 2, 3),
  pos as (select a.id as rid, a.saldo, (a.id in (select n.id from noper n)) as no_periodo, p.*
            from ativos a cross join lateral rateio_posicoes(a.id) p
           where (p_loja_id is null and (eh_dono() or p.loja_uuid in (select minhas_lojas()))) or p.loja_uuid = p_loja_id),
  porloja as (
    select pos.loja_uuid, pos.loja_nome,
           coalesce(sum(pos.parcela) filter (where pos.no_periodo), 0) as parcela_periodo,
           coalesce(sum(greatest(pos.posicao, 0)), 0) as a_receber,
           coalesce(sum(greatest(-pos.posicao, 0)) filter (where pos.saldo <= 0), 0) as a_reembolsar,
           coalesce(sum(greatest(-pos.posicao, 0)) filter (where pos.saldo > 0), 0) as nao_coberta
      from pos group by pos.loja_uuid, pos.loja_nome)
  select jsonb_build_object(
    'periodo', jsonb_build_object('inicio', p_inicio, 'fim', p_fim, 'hoje', v_hoje),
    'datas', jsonb_build_object(
      'previsto', 'data prevista = vencimento (sem vencimento: data de criação), dentro do período',
      'pago', 'data do pagamento externo, dentro do período (líquido de estornos)',
      'saldo_externo', 'foto de hoje (independe do período)',
      'acerto_entre_lojas', 'foto de hoje (independe do período)',
      'reembolsos', 'data do reembolso, dentro do período'),
    'consolidado', jsonb_build_object(
      'qtd_periodo', (select count(*) from noper),
      'previsto_periodo', coalesce((select sum(valor_total) from noper), 0),
      'pago_periodo', coalesce((select sum(liq) from pagper), 0),
      'saldo_externo_pendente', jsonb_build_object('qtd', (select count(*) from ativos where saldo > 0), 'total', coalesce((select sum(saldo) from ativos where saldo > 0), 0)),
      'saldo_externo_vencido', jsonb_build_object('qtd', (select count(*) from ativos where saldo > 0 and vencimento is not null and vencimento < v_hoje), 'total', coalesce((select sum(saldo) from ativos where saldo > 0 and vencimento is not null and vencimento < v_hoje), 0)),
      'canceladas', (select count(*) from vis where status = 'cancelado'),
      'itens', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'tipo_conta', 'compartilhada', 'descricao', i.descricao, 'categoria', i.categoria, 'valor_total', i.valor_total,
                   'pago_total', i.ext, 'pago_no_periodo', coalesce((select sum(liq) from pagper pp where pp.rateio_id = i.id), 0), 'saldo_externo', i.valor_total - i.ext,
                   'vencimento', i.vencimento, 'data_prevista', i.data_prevista, 'no_periodo', (i.id in (select id from noper)),
                   'situacao', case when i.ext >= i.valor_total then 'paga' when i.ext > 0 then 'parcial' else 'pendente' end,
                   'vencida', (i.valor_total - i.ext > 0 and i.vencimento is not null and i.vencimento < v_hoje),
                   'lojas', (select count(*) from rateio_parcelas pa where pa.rateio_id = i.id and pa.versao = i.versao and pa.ativa)) order by i.data_prevista, i.id)
                   from (select * from ativos a where a.id in (select id from noper) or a.id in (select rateio_id from pagper) order by a.data_prevista, a.id limit 200) i), '[]'::jsonb)),
    'por_loja', coalesce((select jsonb_agg(jsonb_build_object('loja_id', l.loja_uuid, 'loja_nome', l.loja_nome,
                   'parcela_periodo', l.parcela_periodo,
                   'pago_externo_periodo', coalesce((select sum(liq) from pagper pp where pp.loja_id = l.loja_uuid), 0),
                   'a_receber_de_outras_lojas', l.a_receber, 'a_reembolsar_a_outras_lojas', l.a_reembolsar, 'parcela_ainda_nao_coberta', l.nao_coberta,
                   'reembolsos_pagos_periodo', coalesce((select sum(liq) from reemper re where re.loja_origem = l.loja_uuid), 0),
                   'reembolsos_recebidos_periodo', coalesce((select sum(liq) from reemper re where re.loja_destino = l.loja_uuid), 0)) order by l.loja_nome)
                   from porloja l), '[]'::jsonb),
    'reembolsos_internos', jsonb_build_object('liquido_periodo', coalesce((select sum(liq) from reemper), 0),
        'nota', 'Reembolsos entre lojas não são receita nem despesa e não alteram entradas, saídas nem o saldo do consolidado.'))
    into v_res;
  return v_res;
end;
$tag_rateios_resumo$;

-- resumos existentes (mesmas chaves de antes + "rateios"). financeiro_resumo também passa a abater estornos de pagamento na própria família
-- (sem estornos de pagamento, os números são idênticos aos de antes).
create or replace function painel_resumo(p_loja_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $tag_painel_resumo$
declare
  tz constant text := 'America/Sao_Paulo';
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  v_mes date := date_trunc('month', now() at time zone 'America/Sao_Paulo')::date;
  v_fim_mes date := (date_trunc('month', now() at time zone 'America/Sao_Paulo') + interval '1 month - 1 day')::date;
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
                       group by vi.nome_snapshot order by sum(vi.quantidade) desc, vi.nome_snapshot limit 5) x),
    'rateios', rateios_resumo(p_loja_id, v_mes, v_fim_mes)
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
  -- entradas/saídas por FAMÍLIA da conta (não pelo sinal): o estorno de um pagamento de despesa abate as saídas, em vez de aparecer como entrada
  select coalesce(sum(efeito) filter (where f.tipo = 'entrada'), 0), coalesce(-sum(efeito) filter (where f.tipo = 'saida'), 0)
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
    'atrasados', (select jsonb_build_object('qtd', count(*), 'total', coalesce(sum(saldo),0)) from contas_abertas() c where c.loja_id = p_loja_id and c.vencimento < v_hoje),
    'rateios', rateios_resumo(p_loja_id, p_inicio, p_fim)
  );
end;
$tag_financeiro_resumo$;

revoke execute on function public.rateios_resumo(uuid, date, date) from public, anon;

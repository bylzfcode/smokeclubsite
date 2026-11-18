-- Testes da integração dos rateios aos resumos financeiros (008). Transação desfeita; relatório em "erro" RELATORIO_RESUMOS.
begin;
create schema testk;
create table testk.res (n text, ok boolean, d text);
create function testk.chk(p_n text, p_ok boolean, p_d text default null) returns void language sql as $f$ insert into testk.res values (p_n, coalesce(p_ok, false), p_d) $f$;
create function testk.tenta(p_sql text) returns text language plpgsql as $f$ begin execute p_sql; return 'OK'; exception when others then return sqlerrm; end; $f$;
create function testk.adm(p text) returns numeric language plpgsql security definer as $f$ declare b numeric; begin execute p into b; return b; end; $f$;
create function testk.como(p_uid uuid) returns void language plpgsql as $f$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
  execute 'set local role authenticated';
end; $f$;
-- valor de uma loja na seção "por loja" (por nome) e do consolidado
create function testk.pl(r jsonb, nome text, campo text) returns numeric language sql as $f$ select (e->>campo)::numeric from jsonb_array_elements(r->'por_loja') e where e->>'loja_nome' = nome $f$;
grant usage on schema testk to public; grant all on all tables in schema testk to public; grant execute on all functions in schema testk to public;

do $teste$
declare
  luiz uuid; enzo uuid; rafael uuid; dono uuid := gen_random_uuid();
  smoke uuid; startbr uuid; ez uuid; hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  itens3 jsonb; r jsonb; rj jsonb; fs jsonb; ft jsonb; fe jsonb; fs0 jsonb; ft0 jsonb; fe0 jsonb; R1 uuid; R2 uuid; R3 uuid; C1 uuid; pa uuid; rb uuid; p2 uuid; ini date; fim date; sold_ant numeric;
begin
  select id into luiz from auth.users where email = 'luiz@painel.local'; select id into enzo from auth.users where email = 'enzo@painel.local'; select id into rafael from auth.users where email = 'rafael@painel.local';
  select id into smoke from lojas where slug = 'smoke-club'; select id into startbr from lojas where slug = 'start-br01'; select id into ez from lojas where slug = 'ez-store';
  insert into auth.users (id, email) values (dono, 'dono.res@painel.local'); insert into perfis (id, nome, papel) values (dono, 'Dono Res', 'dono'); insert into perfis_lojas (perfil_id, loja_id) values (dono, startbr);
  itens3 := jsonb_build_array(jsonb_build_object('loja_id', smoke), jsonb_build_object('loja_id', startbr), jsonb_build_object('loja_id', ez));
  ini := hoje - 1; fim := hoje + 30;

  perform testk.como(luiz);
  -- conta EXCLUSIVA (para provar que as duas famílias não se misturam): 200, paga 50
  C1 := criar_conta(smoke, 'saida', 'aluguel', 'Aluguel exclusivo', 200, hoje + 3, 'Pix', false, gen_random_uuid());
  perform registrar_pagamento(C1, 50, hoje, 'Pix', null, gen_random_uuid());
  R1 := criar_rateio('Reforma da fachada', 'manutenção', 900, hoje + 5, false, 'igual', itens3, gen_random_uuid());
  fs0 := financeiro_resumo(smoke, ini, fim); ft0 := financeiro_resumo(startbr, ini, fim); fe0 := financeiro_resumo(ez, ini, fim);

  -- ================= ANTES DE QUALQUER PAGAMENTO =================
  r := financeiro_resumo(smoke, ini, fim)->'rateios';
  perform testk.chk('antes de pagar: previsto 900 (vencimento no período), pago 0, saldo externo pendente 900', (r->'consolidado'->>'previsto_periodo')::numeric = 900 and (r->'consolidado'->>'pago_periodo')::numeric = 0
     and (r->'consolidado'->'saldo_externo_pendente'->>'total')::numeric = 900 and (r->'consolidado'->'saldo_externo_pendente'->>'qtd')::int = 1, (r->'consolidado')::text);
  perform testk.chk('por loja (Smoke): parcela 300 PREVISTA; nenhum pagamento; a parcela ainda não coberta (300) NÃO vira "a reembolsar" nem dívida', testk.pl(r, 'Smoke Club', 'parcela_periodo') = 300 and testk.pl(r, 'Smoke Club', 'pago_externo_periodo') = 0
     and testk.pl(r, 'Smoke Club', 'parcela_ainda_nao_coberta') = 300 and testk.pl(r, 'Smoke Club', 'a_reembolsar_a_outras_lojas') = 0 and testk.pl(r, 'Smoke Club', 'a_receber_de_outras_lojas') = 0);
  perform testk.chk('contas exclusivas e compartilhadas não se misturam: a pagar exclusivo = 150 (200−50), sem os 900 do rateio', (financeiro_resumo(smoke, ini, fim)->'a_pagar'->>'total')::numeric = 150 and (financeiro_resumo(smoke, ini, fim)->'a_pagar'->>'qtd')::int = 1);
  perform testk.chk('os itens do consolidado identificam a conta como compartilhada e aparecem uma vez', jsonb_array_length(r->'consolidado'->'itens') = 1 and r->'consolidado'->'itens'->0->>'tipo_conta' = 'compartilhada');
  perform testk.chk('cada indicador declara a data que usa', r->'datas'->>'previsto' like '%vencimento%' and r->'datas'->>'pago' like '%data do pagamento%' and r->'datas'->>'saldo_externo' like '%hoje%');

  -- ================= A PAGA TUDO (R$ 900) =================
  pa := (registrar_pagamento_rateio(R1, smoke, 900, hoje, 'Transferência', 'A paga tudo', gen_random_uuid())->>'pagamento_id')::uuid;
  r := financeiro_resumo(smoke, ini, fim)->'rateios';
  perform testk.chk('A paga tudo: despesa consolidada (pago) 900, saldo externo ZERO, previsto 900', (r->'consolidado'->>'pago_periodo')::numeric = 900 and (r->'consolidado'->'saldo_externo_pendente'->>'total')::numeric = 0 and (r->'consolidado'->>'previsto_periodo')::numeric = 900);
  perform testk.chk('Smoke (A): parcela 300, pagou 900 ao externo, R$ 600 a recuperar de outras lojas', testk.pl(r, 'Smoke Club', 'parcela_periodo') = 300 and testk.pl(r, 'Smoke Club', 'pago_externo_periodo') = 900 and testk.pl(r, 'Smoke Club', 'a_receber_de_outras_lojas') = 600);
  rj := rateios_resumo(null, ini, fim);
  perform testk.chk('consolidado das 3 lojas (Luiz): Start e EZ têm R$ 300 a reembolsar (acerto entre lojas, externo quitado) e nenhuma parcela "não coberta"', testk.pl(rj, 'Start BR01', 'a_reembolsar_a_outras_lojas') = 300 and testk.pl(rj, 'EZ Store', 'a_reembolsar_a_outras_lojas') = 300
     and testk.pl(rj, 'Start BR01', 'parcela_ainda_nao_coberta') = 0 and testk.pl(rj, 'Start BR01', 'pago_externo_periodo') = 0);
  perform testk.chk('a despesa de 900 aparece UMA vez no consolidado, mesmo com 3 lojas, sem multiplicar', (rj->'consolidado'->>'previsto_periodo')::numeric = 900 and (rj->'consolidado'->>'pago_periodo')::numeric = 900 and jsonb_array_length(rj->'consolidado'->'itens') = 1);
  fs := financeiro_resumo(smoke, ini, fim); ft := financeiro_resumo(startbr, ini, fim); fe := financeiro_resumo(ez, ini, fim);
  perform testk.chk('entradas/saídas efetivadas: o pagamento externo (−900) conta só na Smoke, na data do pagamento; Start e EZ inalteradas', (fs->>'saidas')::numeric = (fs0->>'saidas')::numeric + 900 and (ft->>'saidas')::numeric = (ft0->>'saidas')::numeric and (fe->>'saidas')::numeric = (fe0->>'saidas')::numeric);
  perform testk.chk('soma das saídas das 3 lojas aumentou 900 (e não 2.700)', ((fs->>'saidas')::numeric + (ft->>'saidas')::numeric + (fe->>'saidas')::numeric) - ((fs0->>'saidas')::numeric + (ft0->>'saidas')::numeric + (fe0->>'saidas')::numeric) = 900);

  -- ================= B REEMBOLSA R$ 100 =================
  perform testk.como(enzo);
  rb := (registrar_reembolso(R1, startbr, smoke, 100, hoje, 'B devolve 100', gen_random_uuid())->>'reembolso_id')::uuid;
  perform testk.como(luiz);
  r := financeiro_resumo(smoke, ini, fim)->'rateios'; rj := rateios_resumo(null, ini, fim);
  perform testk.chk('B reembolsa 100: despesa PERMANECE 900 e saldo externo segue zero; A passa a recuperar R$ 500', (r->'consolidado'->>'pago_periodo')::numeric = 900 and (r->'consolidado'->'saldo_externo_pendente'->>'total')::numeric = 0 and testk.pl(r, 'Smoke Club', 'a_receber_de_outras_lojas') = 500);
  perform testk.chk('B passa a dever R$ 200 e C continua devendo R$ 300', testk.pl(rj, 'Start BR01', 'a_reembolsar_a_outras_lojas') = 200 and testk.pl(rj, 'EZ Store', 'a_reembolsar_a_outras_lojas') = 300);
  perform testk.chk('reembolsos internos aparecem à parte (líquido do período 100) com a nota de que não são receita nem despesa', (rj->'reembolsos_internos'->>'liquido_periodo')::numeric = 100 and rj->'reembolsos_internos'->>'nota' like '%não são receita nem despesa%'
     and testk.pl(rj, 'Start BR01', 'reembolsos_pagos_periodo') = 100 and testk.pl(rj, 'Smoke Club', 'reembolsos_recebidos_periodo') = 100);
  perform testk.chk('o reembolso NÃO alterou entradas, saídas nem saldo efetivado de nenhuma loja', (financeiro_resumo(smoke, ini, fim)->>'saidas') = (fs->>'saidas') and (financeiro_resumo(smoke, ini, fim)->>'entradas') = (fs->>'entradas') and (financeiro_resumo(smoke, ini, fim)->>'saldo_caixa') = (fs->>'saldo_caixa')
     and (financeiro_resumo(startbr, ini, fim)->>'saidas') = (ft->>'saidas') and (financeiro_resumo(startbr, ini, fim)->>'entradas') = (ft->>'entradas') and (financeiro_resumo(startbr, ini, fim)->>'saldo_caixa') = (ft->>'saldo_caixa'));
  perform testk.chk('fluxo consolidado do rateio: um único −900', testk.adm(format($q$select count(*) from fluxo_pago_itens() where lancamento_id=%L$q$, R1)) = 1 and testk.adm(format($q$select sum(efeito) from fluxo_pago_itens() where lancamento_id=%L$q$, R1)) = -900);

  -- ================= PAGAMENTO EXTERNO PARCIAL + VENCIMENTO (R2 vencido) =================
  R2 := criar_rateio('Internet (vencida)', 'serviços', 1000, hoje - 3, false, 'igual', itens3, gen_random_uuid());
  p2 := (registrar_pagamento_rateio(R2, smoke, 400, hoje, 'Pix', 'Smoke paga parte', gen_random_uuid())->>'pagamento_id')::uuid;
  rj := rateios_resumo(null, ini, fim);
  perform testk.chk('parcial: saldo externo pendente = 600 (R2); vencido = 600 (vencimento passou); R1 não entra', (rj->'consolidado'->'saldo_externo_pendente'->>'total')::numeric = 600 and (rj->'consolidado'->'saldo_externo_pendente'->>'qtd')::int = 1
     and (rj->'consolidado'->'saldo_externo_vencido'->>'total')::numeric = 600 and (rj->'consolidado'->'saldo_externo_vencido'->>'qtd')::int = 1, (rj->'consolidado')::text);
  perform testk.chk('previsto do período (ini=hoje−1) NÃO inclui R2 (venceu antes) mas o pago de hoje (400) conta: previsto 900, pago 1300', (rj->'consolidado'->>'previsto_periodo')::numeric = 900 and (rj->'consolidado'->>'pago_periodo')::numeric = 1300);
  perform testk.chk('R2 aparece nos itens (tem pagamento no período) com total 1000, pago 400, saldo 600, vencida', (select (e->>'valor_total')::numeric = 1000 and (e->>'pago_total')::numeric = 400 and (e->>'saldo_externo')::numeric = 600 and (e->>'vencida')::boolean and e->>'situacao' = 'parcial' and not (e->>'no_periodo')::boolean
        from jsonb_array_elements(rj->'consolidado'->'itens') e where (e->>'id')::uuid = R2));
  perform testk.chk('período mais largo (hoje−10): previsto passa a 1900 (900 + 1000), sem duplicar', (rateios_resumo(null, hoje - 10, fim)->'consolidado'->>'previsto_periodo')::numeric = 1900);
  perform testk.chk('com saldo externo em aberto, a posição negativa vira "parcela ainda não coberta" (não "a reembolsar", não dívida ao fornecedor): Start 333,33 e EZ 333,34 em R2', testk.pl(rj, 'Start BR01', 'parcela_ainda_nao_coberta') = 333.33 and testk.pl(rj, 'EZ Store', 'parcela_ainda_nao_coberta') = 333.34
     and testk.pl(rj, 'Start BR01', 'a_reembolsar_a_outras_lojas') = 200 and testk.pl(rj, 'Smoke Club', 'a_receber_de_outras_lojas') = 500 + 66.67);
  perform testk.chk('parcelas em centavos (1000/3): Smoke 333,33 + Start 333,33 + EZ 333,34 = 1000,00', testk.adm(format('select sum(valor) from rateio_parcelas where rateio_id=%L', R2)) = 1000);
  perform testk.chk('o alerta de rateio vencido continua coerente com o resumo (1 despesa)', exists (select 1 from jsonb_array_elements(listar_avisos(smoke)) e where e->>'chave' = 'rateios_vencidos' and e->>'titulo' like '1 despesa%'));

  -- ================= FILTRO DE PERÍODO =================
  rj := rateios_resumo(null, hoje + 20, hoje + 30);
  perform testk.chk('período futuro (hoje+20…hoje+30): previsto 0 e pago 0, MAS o saldo externo pendente (foto de hoje) permanece 600', (rj->'consolidado'->>'previsto_periodo')::numeric = 0 and (rj->'consolidado'->>'pago_periodo')::numeric = 0
     and (rj->'consolidado'->'saldo_externo_pendente'->>'total')::numeric = 600 and testk.pl(rj, 'Smoke Club', 'a_receber_de_outras_lojas') = 566.67);
  perform testk.chk('sem período (tudo): mesmos totais acumulados, sem duplicar (previsto 1900, pago 1300)', (rateios_resumo(null, null, null)->'consolidado'->>'previsto_periodo')::numeric = 1900 and (rateios_resumo(null, null, null)->'consolidado'->>'pago_periodo')::numeric = 1300);
  perform testk.chk('período inválido recusado', testk.tenta(format('select rateios_resumo(null, %L, %L)', hoje, hoje - 1)) like '%Período inválido%');

  -- ================= ESTORNOS =================
  perform estornar_pagamento_rateio(p2, 'pagamento lançado em duplicidade');
  rj := rateios_resumo(null, ini, fim);
  perform testk.chk('estorno do pagamento parcial de R2: pago líquido do período volta a 900 (400 − 400 no mesmo período), saldo externo de R2 = 1000', (rj->'consolidado'->>'pago_periodo')::numeric = 900 and (rj->'consolidado'->'saldo_externo_pendente'->>'total')::numeric = 1000
     and testk.pl(rj, 'Smoke Club', 'a_receber_de_outras_lojas') = 500);
  perform estornar_reembolso(rb, 'reembolso lançado errado');
  rj := rateios_resumo(null, ini, fim);
  perform testk.chk('estorno do reembolso: B volta a dever 300, A volta a recuperar 600; despesa e entradas/saídas inalteradas', testk.pl(rj, 'Start BR01', 'a_reembolsar_a_outras_lojas') = 300 and testk.pl(rj, 'Smoke Club', 'a_receber_de_outras_lojas') = 600 and (rj->'consolidado'->>'pago_periodo')::numeric = 900
     and (rj->'reembolsos_internos'->>'liquido_periodo')::numeric = 0 and (financeiro_resumo(smoke, ini, fim)->>'saidas')::numeric = (fs->>'saidas')::numeric and (financeiro_resumo(smoke, ini, fim)->>'entradas')::numeric = (fs->>'entradas')::numeric and (financeiro_resumo(smoke, ini, fim)->>'saldo_caixa')::numeric = (fs->>'saldo_caixa')::numeric);
  R3 := criar_rateio('Cancelado', 'outro', 500, hoje + 1, false, 'igual', itens3, gen_random_uuid()); perform cancelar_rateio(R3, 'lançado por engano');
  rj := rateios_resumo(null, ini, fim);
  perform testk.chk('rateio cancelado fica fora dos totais e é apenas contado', (rj->'consolidado'->>'previsto_periodo')::numeric = 900 and (rj->'consolidado'->>'canceladas')::int = 1);

  -- ================= USUÁRIO DE UMA ÚNICA LOJA (enzo = Start BR01) =================
  perform testk.como(enzo);
  r := financeiro_resumo(startbr, ini, fim)->'rateios';
  perform testk.chk('enzo (só Start): vê os rateios de que a Start participa, cada um uma vez (900 + 1000), e só a própria loja em "por loja"', (r->'consolidado'->>'previsto_periodo')::numeric = 900 and jsonb_array_length(r->'por_loja') = 1 and r->'por_loja'->0->>'loja_nome' = 'Start BR01', r::text);
  perform testk.chk('enzo: Start deve 300 de R1 (acerto) e 333,33 ainda não coberta em R2; nada sobre as outras lojas', testk.pl(r, 'Start BR01', 'a_reembolsar_a_outras_lojas') = 300 and testk.pl(r, 'Start BR01', 'parcela_ainda_nao_coberta') = 333.33 and testk.pl(r, 'Smoke Club', 'a_receber_de_outras_lojas') is null);
  perform testk.chk('enzo não pede resumo da Smoke; sem filtro de loja só enxerga a Start', testk.tenta(format('select rateios_resumo(%L, null, null)', smoke)) like '%permissão%' and jsonb_array_length(rateios_resumo(null, ini, fim)->'por_loja') = 1);
  perform testk.chk('enzo não abre financeiro_resumo da Smoke', testk.tenta(format('select financeiro_resumo(%L, null, null)', smoke)) like '%permissão%');
  perform testk.como(rafael);
  perform testk.chk('rafael (Streaks): nenhum rateio, nenhuma linha por loja', (rateios_resumo(null, ini, fim)->'consolidado'->>'qtd_periodo')::int = 0 and jsonb_array_length(rateios_resumo(null, ini, fim)->'por_loja') = 0);
  perform testk.como(dono);
  rj := rateios_resumo(null, ini, fim);
  perform testk.chk('dono (vinculado só à Start) vê o consolidado de todas as lojas: Smoke, Start e EZ em "por loja", cada despesa uma vez', jsonb_array_length(rj->'por_loja') = 3 and (rj->'consolidado'->>'previsto_periodo')::numeric = 900);
  execute 'reset role'; execute 'set local role anon';
  perform testk.chk('anônimo não executa', testk.tenta('select rateios_resumo()') like '%permission denied%');
  perform testk.como(luiz);

  -- ================= PAINEL E COMPATIBILIDADE =================
  r := painel_resumo(smoke);
  perform testk.chk('painel_resumo: chaves antigas preservadas e nova chave "rateios" (mês)', r ? 'hoje' and r ? 'mes' and r ? 'saldo_caixa' and r ? 'a_pagar' and r ? 'a_receber' and r ? 'atrasados' and r ? 'por_dia' and r ? 'top_produtos' and r ? 'rateios' and r->'rateios' ? 'consolidado');
  perform testk.chk('painel: o saldo em caixa já considera o pagamento externo uma única vez (−900 −50 da conta exclusiva)', (r->>'saldo_caixa')::numeric = -950, (r->>'saldo_caixa'));
  perform testk.chk('financeiro_resumo: chaves antigas preservadas (entradas, saidas, saldo_periodo, saldo_caixa, a_receber, a_pagar, atrasados)', fs ? 'entradas' and fs ? 'saidas' and fs ? 'saldo_periodo' and fs ? 'saldo_caixa' and fs ? 'a_receber' and fs ? 'a_pagar' and fs ? 'atrasados');
  perform testk.chk('caixa preservado: nenhum movimento de caixa foi criado pelos rateios', testk.adm('select count(*) from caixa_movimentos') = 0 and testk.adm('select count(*) from caixas') = 0);

  execute 'reset role';
  select jsonb_build_object('total', count(*), 'ok', count(*) filter (where x.ok), 'falhas', count(*) filter (where not x.ok),
         'detalhe_falhas', coalesce(jsonb_agg(jsonb_build_object('n', x.n, 'd', x.d)) filter (where not x.ok), '[]'::jsonb)) into r from testk.res x;
  raise exception 'RELATORIO_RESUMOS: %', r::text;
end;
$teste$;

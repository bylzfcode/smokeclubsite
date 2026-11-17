-- ============================================================
-- Testes do caixa, histórico financeiro e avisos (003_caixa_avisos.sql).
-- Rodam numa transação DESFEITA no final; o relatório aparece como "erro" RELATORIO_CAIXA: {...}
-- Precisa dos 5 usuários do painel (luiz, victor, enzo, rafael, vinicius). Rode DEPOIS de schema, 002 e 003.
-- ============================================================
begin;
create schema testk;
create table testk.res (n text, ok boolean, d text);
create function testk.chk(p_n text, p_ok boolean, p_d text default null) returns void language sql as $f$ insert into testk.res values (p_n, coalesce(p_ok, false), p_d) $f$;
-- executa um comando e devolve a mensagem de erro (ou 'OK' se funcionou) — com o papel/usuário atual
create function testk.tenta(p_sql text) returns text language plpgsql as $f$ begin execute p_sql; return 'OK'; exception when others then return sqlerrm; end; $f$;
create function testk.como(p_uid uuid) returns void language plpgsql as $f$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
  execute 'set local role authenticated';
end; $f$;
create function testk.adm(p text) returns boolean language plpgsql security definer as $f$ declare b boolean; begin execute p into b; return b; end; $f$;
grant usage on schema testk to public; grant all on all tables in schema testk to public; grant execute on all functions in schema testk to public;

do $teste$
declare
  luiz uuid; enzo uuid; rafael uuid; victor uuid;
  operador uuid := gen_random_uuid(); dono uuid := gen_random_uuid(); estranho uuid := gen_random_uuid();
  smoke uuid; startbr uuid; ez uuid; streaks uuid;
  v_cat uuid; item1 uuid; cx1 uuid; cx2 uuid; cx_sb uuid; cx3 uuid;
  m_ent uuid; m_saida uuid; m_ret uuid; m_pix uuid; m_aj uuid; m_est uuid;
  r jsonb; j jsonb; msg text; n int; t numeric; hoje date; dia_json jsonb; a1 uuid; a2 uuid; a3 uuid; lanc uuid; v_chave uuid;
begin
  select id into luiz from auth.users where email = 'luiz@painel.local';
  select id into enzo from auth.users where email = 'enzo@painel.local';
  select id into rafael from auth.users where email = 'rafael@painel.local';
  select id into victor from auth.users where email = 'victor@painel.local';
  select id into smoke from lojas where slug = 'smoke-club';
  select id into startbr from lojas where slug = 'start-br01';
  select id into ez from lojas where slug = 'ez-store';
  select id into streaks from lojas where slug = 'streaks-store';
  hoje := (now() at time zone 'America/Sao_Paulo')::date;

  insert into auth.users (id, email) values (operador, 'op.caixa@painel.local'), (dono, 'dono.caixa@painel.local'), (estranho, 'estranho.caixa@painel.local');
  insert into perfis (id, nome, papel) values (operador, 'Operador Caixa', 'operador'), (dono, 'Dono Caixa', 'dono'), (estranho, 'Estranho', 'operador');
  insert into perfis_lojas (perfil_id, loja_id) values (operador, startbr), (operador, smoke), (dono, startbr);

  -- item e preço para vendas de teste (Luiz = gerente em Smoke/Start/EZ)
  perform testk.como(luiz);
  insert into categorias(nome) values ('CAT CAIXA') returning id into v_cat;
  item1 := criar_item(smoke, 'produto', null, v_cat, 'Item caixa', null, null, 50, 1);
  insert into precos_loja(loja_id, item_id, preco) values (smoke, item1, 25);

  -- ================= ABERTURA =================
  cx1 := abrir_caixa(smoke, 100, 'troco inicial');
  perform testk.chk('abrir caixa: grava saldo, loja, responsável e data', testk.adm(format($q$select saldo_inicial = 100 and loja_id = %L and aberto_por = %L and status = 'aberto' and aberto_em is not null from caixas where id = %L$q$, smoke, luiz, cx1)));
  perform testk.chk('abrir 2º caixa na mesma loja é recusado', testk.tenta(format('select abrir_caixa(%L, 10)', smoke)) like '%Já existe um caixa aberto%');
  perform testk.chk('saldo inicial negativo recusado', testk.tenta(format('select abrir_caixa(%L, -1)', startbr)) like '%maior que zero%');
  perform testk.chk('centavos: 10,005 recusado', testk.tenta(format('select abrir_caixa(%L, 10.005)', startbr)) like '%2 casas%');
  perform testk.chk('sem registro de auditoria extra após recusas', testk.adm(format($q$select count(*) = 1 from caixa_auditoria where caixa_id = %L$q$, cx1)));
  perform testk.como(enzo);
  perform testk.chk('enzo (só Start BR01) não abre caixa na Smoke', testk.tenta(format('select abrir_caixa(%L, 10)', smoke)) like '%permissão%');
  cx_sb := abrir_caixa(startbr, 50);
  perform testk.chk('lojas diferentes têm caixas independentes', cx_sb is not null and cx_sb <> cx1);
  perform testk.chk('enzo não lança na Smoke', testk.tenta(format($q$select registrar_movimento_caixa(%L,'entrada','dinheiro',10,'x')$q$, cx1)) like '%permissão%');
  perform testk.chk('enzo não lê o caixa da Smoke', testk.tenta(format('select caixa_atual(%L)', smoke)) like '%permissão%');
  perform testk.chk('enzo não vê detalhe do caixa da Smoke', testk.tenta(format('select caixa_detalhe(%L)', cx1)) like '%sem permissão%');
  perform testk.como(estranho);
  perform testk.chk('usuário sem loja não abre caixa', testk.tenta(format('select abrir_caixa(%L, 1)', smoke)) like '%permissão%');
  perform testk.chk('usuário sem loja não lê histórico', testk.tenta('select historico_financeiro()') like '%Sem permissão%');
  execute 'reset role'; execute 'set local role anon';
  perform testk.chk('anônimo não executa abrir_caixa', testk.tenta(format('select abrir_caixa(%L, 1)', smoke)) like '%permission denied%');
  perform testk.chk('anônimo não lê tabelas do caixa', testk.tenta('select * from caixas') like '%permission denied%');
  perform testk.como(luiz);
  perform testk.chk('autenticado não lê tabela caixas direto', testk.tenta('select * from caixas') like '%permission denied%');
  perform testk.chk('autenticado não escreve em caixa_movimentos direto', testk.tenta(format($q$insert into caixa_movimentos(caixa_id,loja_id,tipo,sentido,valor,categoria,criado_por) values (%L,%L,'entrada',1,5,'x',%L)$q$, cx1, smoke, luiz)) like '%permission denied%');

  -- (a partir daqui os testes LEEM as tabelas para conferir; a proteção direta já foi provada acima. Tudo é desfeito no final.)
  execute 'reset role'; grant select on caixas, caixa_movimentos, caixa_auditoria, avisos, avisos_historico, avisos_leituras, alertas_lidos to authenticated; create policy t_l on caixas for select to authenticated using (true); create policy t_l on caixa_movimentos for select to authenticated using (true); create policy t_l on caixa_auditoria for select to authenticated using (true); create policy t_l on avisos for select to authenticated using (true); create policy t_l on avisos_historico for select to authenticated using (true); perform testk.como(luiz);

  -- ================= MOVIMENTOS =================
  m_ent := registrar_movimento_caixa(cx1, 'entrada', 'dinheiro', 20, 'suprimento', 'troco extra');
  m_saida := registrar_movimento_caixa(cx1, 'saida', 'dinheiro', 5, 'despesa', 'café');
  m_ret := registrar_movimento_caixa(cx1, 'retirada', 'dinheiro', 15, 'sangria');
  m_pix := registrar_movimento_caixa(cx1, 'entrada', 'pix', 40, 'recebimento');
  r := caixa_atual(smoke);
  perform testk.chk('esperado em dinheiro = 100+20−5−15 (Pix de 40 NÃO entra)', (r->'aberto'->>'esperado_dinheiro')::numeric = 100.00, r->'aberto'->>'esperado_dinheiro');
  perform testk.chk('movimentos listados com autor', jsonb_array_length(r->'movimentos') = 4 and r->'movimentos'->0->>'criado_por_nome' = 'Luiz');
  perform testk.chk('outros meios separados do dinheiro', (r->'aberto'->>'mov_outros_meios')::numeric = 40 and (r->'aberto'->>'mov_dinheiro')::numeric = 0);
  perform registrar_venda(smoke, jsonb_build_array(jsonb_build_object('item_id', item1, 'quantidade', 2)), null, 'Dinheiro', 0, gen_random_uuid());
  perform registrar_venda(smoke, jsonb_build_array(jsonb_build_object('item_id', item1, 'quantidade', 1)), null, 'Pix', 0, gen_random_uuid());
  perform registrar_venda(smoke, jsonb_build_array(jsonb_build_object('item_id', item1, 'quantidade', 1)), null, 'Crédito', 0, gen_random_uuid());
  r := caixa_atual(smoke)->'aberto';
  perform testk.chk('venda em dinheiro soma no esperado (100+50=150); Pix e cartão não', (r->>'esperado_dinheiro')::numeric = 150 and (r->>'vendas_dinheiro')::numeric = 50 and (r->>'vendas_pix')::numeric = 25 and (r->>'vendas_cartao')::numeric = 25, r::text);
  perform testk.chk('vendas NÃO foram duplicadas em movimentos do caixa', (select count(*) from caixa_movimentos where caixa_id = cx1) = 4);
  perform testk.chk('saída maior que o dinheiro do caixa recusada', testk.tenta(format($q$select registrar_movimento_caixa(%L,'saida','dinheiro',1000,'x')$q$, cx1)) like '%Dinheiro insuficiente%');
  perform testk.chk('retirada em Pix recusada', testk.tenta(format($q$select registrar_movimento_caixa(%L,'retirada','pix',1,'x')$q$, cx1)) like '%sempre em dinheiro%');
  perform testk.chk('valor com 3 casas recusado', testk.tenta(format($q$select registrar_movimento_caixa(%L,'entrada','dinheiro',0.001,'x')$q$, cx1)) like '%2 casas%');
  perform testk.chk('valor zero/negativo recusado', testk.tenta(format($q$select registrar_movimento_caixa(%L,'entrada','dinheiro',-3,'x')$q$, cx1)) like '%maior que zero%');
  perform testk.chk('categoria obrigatória', testk.tenta(format($q$select registrar_movimento_caixa(%L,'entrada','dinheiro',3,'  ')$q$, cx1)) like '%categoria%');
  perform testk.chk('tipo inválido recusado', testk.tenta(format($q$select registrar_movimento_caixa(%L,'estorno','dinheiro',3,'x')$q$, cx1)) like '%Tipo inválido%');
  perform testk.chk('ajuste sem observação recusado', testk.tenta(format($q$select registrar_movimento_caixa(%L,'ajuste','dinheiro',2.5,'quebra',null,1)$q$, cx1)) like '%observação%');
  perform testk.chk('ajuste sem sentido recusado', testk.tenta(format($q$select registrar_movimento_caixa(%L,'ajuste','dinheiro',2.5,'quebra','obs',null)$q$, cx1)) like '%soma%');
  m_aj := registrar_movimento_caixa(cx1, 'ajuste', 'dinheiro', 2.50, 'quebra de caixa', 'moeda achada', 1);
  perform testk.chk('ajuste por gerente soma 2,50 (esperado 152,50)', (caixa_atual(smoke)->'aberto'->>'esperado_dinheiro')::numeric = 152.50);
  perform testk.como(operador);
  perform testk.chk('operador lança entrada normal', testk.tenta(format($q$select registrar_movimento_caixa(%L,'entrada','dinheiro',1,'gorjeta')$q$, cx1)) = 'OK');
  perform testk.chk('operador NÃO faz ajuste', testk.tenta(format($q$select registrar_movimento_caixa(%L,'ajuste','dinheiro',1,'x','y',1)$q$, cx1)) like '%gerente ou dono%');
  perform testk.chk('operador NÃO estorna', testk.tenta(format($q$select estornar_movimento_caixa(%L,'erro')$q$, m_saida)) like '%gerente ou dono%');
  perform testk.chk('operador NÃO reabre', testk.tenta(format($q$select reabrir_caixa(%L,'quero reabrir')$q$, cx1)) like '%gerente ou dono%');
  perform testk.como(luiz);   -- esperado agora 153,50 (com a gorjeta de 1)

  -- ================= ESTORNO =================
  m_est := estornar_movimento_caixa(m_saida, 'lançado errado');
  perform testk.chk('estorno cria novo movimento ligado ao original', (select tipo = 'estorno' and estorno_de = m_saida and sentido = 1 and valor = 5 and meio = 'dinheiro' from caixa_movimentos where id = m_est));
  perform testk.chk('movimento original permanece intacto', (select tipo = 'saida' and valor = 5 and sentido = -1 and observacao = 'café' from caixa_movimentos where id = m_saida));
  perform testk.chk('estorno devolve o valor ao esperado (153,50+5)', (caixa_atual(smoke)->'aberto'->>'esperado_dinheiro')::numeric = 158.50);
  perform testk.chk('original aparece marcado como estornado', (select (e->>'estornado')::boolean from jsonb_array_elements(caixa_atual(smoke)->'movimentos') e where e->>'id' = m_saida::text));
  perform testk.chk('estornar duas vezes é recusado', testk.tenta(format($q$select estornar_movimento_caixa(%L,'de novo')$q$, m_saida)) like '%já foi estornada%');
  perform testk.chk('estorno de estorno é recusado', testk.tenta(format($q$select estornar_movimento_caixa(%L,'x')$q$, m_est)) like '%não pode ser estornado%');
  perform testk.chk('estorno sem motivo recusado', testk.tenta(format($q$select estornar_movimento_caixa(%L,' ')$q$, m_ent)) like '%motivo%');
  perform testk.chk('estornar entrada em Pix não mexe na gaveta (permitido)', (select testk.tenta(format($q$select estornar_movimento_caixa(%L,'x')$q$, m_pix))) = 'OK'); -- Pix não afeta a gaveta
  execute 'reset role';
  perform testk.chk('UPDATE em movimento é bloqueado mesmo para dono do banco', testk.tenta(format('update caixa_movimentos set valor = 1 where id = %L', m_saida)) like '%não pode ser alterada%');
  perform testk.chk('DELETE em movimento é bloqueado', testk.tenta(format('delete from caixa_movimentos where id = %L', m_saida)) like '%não pode ser alterada%');
  perform testk.chk('auditoria não pode ser apagada', testk.tenta('delete from caixa_auditoria') like '%não pode ser alterada%');
  perform testk.chk('caixa não pode ser editado fora das funções', testk.tenta(format('update caixas set saldo_inicial = 999 where id = %L', cx1)) like '%só pode ser alterado pelas funções%');
  perform testk.como(luiz);

  -- ================= FECHAMENTO =================
  perform testk.chk('fechar com diferença exige justificativa', testk.tenta(format('select fechar_caixa(%L, 150)', cx1)) like '%justificativa%');
  perform testk.chk('fechar com valor negativo recusado', testk.tenta(format('select fechar_caixa(%L, -1, %L)', cx1, 'x')) like '%maior que zero%');
  j := fechar_caixa(cx1, 150, 'faltou troco');
  perform testk.chk('fechamento: esperado 158,50, conferido 150, diferença −8,50', (j->>'esperado')::numeric = 158.50 and (j->>'conferido')::numeric = 150 and (j->>'diferenca')::numeric = -8.50, j::text);
  perform testk.chk('caixa gravado como fechado com responsável e hora', (select status = 'fechado' and fechado_por = luiz and fechado_em is not null and justificativa = 'faltou troco' and diferenca = -8.50 from caixas where id = cx1));
  perform testk.chk('fechar de novo é recusado', testk.tenta(format('select fechar_caixa(%L, 1, %L)', cx1, 'x')) like '%já está fechado%');
  perform testk.chk('lançar em caixa fechado é recusado', testk.tenta(format($q$select registrar_movimento_caixa(%L,'entrada','dinheiro',1,'x')$q$, cx1)) like '%fechado%');
  perform testk.chk('estornar em caixa fechado é recusado', testk.tenta(format($q$select estornar_movimento_caixa(%L,'x')$q$, m_ent)) like '%fechado%');
  execute 'reset role';
  perform testk.chk('caixa fechado não muda no silêncio (nem pelo dono do banco)', testk.tenta(format($q$select set_config('app.caixa_op','1',true); update caixas set justificativa = 'mudei' where id = %L$q$, cx1)) is not null
    and (select justificativa from caixas where id = cx1) = 'faltou troco');
  perform testk.como(luiz);
  j := registrar_venda(smoke, jsonb_build_array(jsonb_build_object('item_id', item1, 'quantidade', 1)), null, 'Dinheiro', 0, gen_random_uuid());
  execute 'reset role'; update vendas set criado_em = criado_em + interval '1 second' where id = (j->>'id')::uuid; perform testk.como(luiz);  -- (o teste roda numa transação só: afasta 1s para ficar DEPOIS do fechamento)
  perform testk.chk('venda em dinheiro DEPOIS do fechamento não altera o fechado', (select esperado_dinheiro = 158.50 from caixas where id = cx1) and (caixa_detalhe(cx1)->'caixa'->>'esperado_dinheiro')::numeric = 158.50);

  -- ================= REABERTURA =================
  perform testk.chk('reabrir sem motivo recusado', testk.tenta(format($q$select reabrir_caixa(%L,'  ')$q$, cx1)) like '%motivo%');
  perform testk.como(enzo);
  perform testk.chk('gerente de OUTRA loja não reabre', testk.tenta(format($q$select reabrir_caixa(%L,'quero tentar reabrir')$q$, cx1)) like '%gerente ou dono pode reabrir%');
  perform testk.como(luiz);
  cx2 := abrir_caixa(smoke, 10);   -- novo caixa enquanto o anterior está fechado
  execute 'reset role'; alter table caixas disable trigger caixa_guard; update caixas set aberto_em = now() + interval '0.5 seconds' where id = cx2; alter table caixas enable trigger caixa_guard; perform testk.como(luiz);  -- (transação única: separa no tempo as vendas feitas antes da abertura do 2º caixa)
  perform testk.chk('com outro caixa aberto, reabrir o antigo é recusado', testk.tenta(format($q$select reabrir_caixa(%L,'preciso corrigir')$q$, cx1)) like '%outro caixa aberto%');
  perform fechar_caixa(cx2, 38, 'sobrou 3');   -- esperado 10 + 25 (venda em dinheiro feita com o caixa aberto) = 35
  perform reabrir_caixa(cx1, 'preciso corrigir estorno');
  perform testk.chk('reabertura: volta a aberto, limpa fechamento e conta reaberturas', (select status = 'aberto' and fechado_em is null and valor_conferido is null and reaberturas = 1 from caixas where id = cx1));
  perform testk.chk('auditoria guarda o fechamento anterior e o motivo', (select count(*) from caixa_auditoria where caixa_id = cx1 and acao = 'reabertura' and motivo = 'preciso corrigir estorno' and (detalhes->>'diferenca')::numeric = -8.50 and por = luiz) = 1);
  perform fechar_caixa(cx1, 158.50, null);   -- a venda de 25 feita depois do 1º fechamento NÃO entra (janela fixa)
  perform testk.chk('fechamento sem diferença não exige justificativa', (select diferenca = 0 and esperado_dinheiro = 158.50 from caixas where id = cx1));

  -- ================= HISTÓRICO =================
  r := historico_financeiro(smoke, hoje - 1, hoje + 1, null, null);
  dia_json := r->0;
  perform testk.chk('histórico: 1 linha para Smoke hoje, agrupada por dia', jsonb_array_length(r) = 1 and (dia_json->>'dia')::date = hoje and dia_json->>'loja_nome' = 'Smoke Club', r::text);
  select coalesce(sum(valor),0) into t from financeiro_lancamentos where loja_id = smoke and tipo = 'entrada' and categoria <> 'estorno' and status = 'pago';
  perform testk.chk('entradas do dia = financeiro (vendas) + movimentos do caixa, sem duplicar',
    (dia_json->>'entradas')::numeric = t + (select coalesce(sum(valor),0) from caixa_movimentos where loja_id = smoke and tipo <> 'estorno' and sentido = 1), (dia_json->>'entradas') || ' vs ' || t);
  perform testk.chk('nenhum lançamento do financeiro foi criado pelo caixa', (select count(*) from financeiro_lancamentos where loja_id = smoke) = 4);
  perform testk.chk('estornos do dia aparecem (+5 da saída estornada, −40 do Pix estornado)', (dia_json->>'estornos')::numeric = -35, dia_json->>'estornos');
  perform testk.chk('abertura somada (100 + 10) e fechamento conferido', (dia_json->>'abertura')::numeric = 110 and (dia_json->>'fechamento')::numeric = 158.50 + 38, dia_json::text);
  perform testk.chk('saldo = entradas − saídas + estornos', (dia_json->>'saldo')::numeric = (dia_json->>'entradas')::numeric - (dia_json->>'saidas')::numeric + (dia_json->>'estornos')::numeric);
  perform testk.chk('situação "diferenca" mostra o caixa com sobra de 3', coalesce(jsonb_array_length(historico_financeiro(smoke, hoje, hoje, null, 'diferenca')) = 1
     and (historico_financeiro(smoke, hoje, hoje, null, 'diferenca')->0->>'diferenca')::numeric = 3, false), historico_financeiro(smoke, hoje, hoje, null, 'diferenca')::text);
  perform testk.chk('situação "aberto" não traz a Smoke (tudo fechado)', jsonb_array_length(historico_financeiro(smoke, hoje, hoje, null, 'aberto')) = 0);
  perform testk.chk('filtro por responsável', jsonb_array_length(historico_financeiro(smoke, hoje, hoje, luiz, null)) = 1 and jsonb_array_length(historico_financeiro(smoke, hoje, hoje, victor, null)) = 0);
  perform testk.chk('situação inválida recusada', testk.tenta($q$select historico_financeiro(null,null,null,null,'xyz')$q$) like '%Situação inválida%');
  perform testk.chk('período maior que 1 ano recusado', testk.tenta($q$select historico_financeiro(null,'2020-01-01','2022-01-01',null,null)$q$) like '%Período máximo%');
  j := detalhe_dia_financeiro(smoke, hoje);
  perform testk.chk('detalhe do dia: caixas, movimentos e lançamentos', jsonb_array_length(j->'caixas') = 2 and jsonb_array_length(j->'movimentos') >= 6 and jsonb_array_length(j->'lancamentos') >= 3);
  perform testk.chk('luiz vê Smoke/Start/EZ e não a Streaks', testk.tenta(format('select historico_financeiro(%L)', streaks)) like '%permissão%' and testk.tenta(format('select historico_financeiro(%L)', ez)) = 'OK');
  perform testk.como(enzo);
  r := historico_financeiro(null, hoje - 1, hoje + 1, null, null);
  perform testk.chk('enzo só enxerga a Start BR01 (isolamento)', (select bool_and(e->>'loja_nome' = 'Start BR01') from jsonb_array_elements(r) e) and jsonb_array_length(r) = 1, r::text);
  perform testk.chk('enzo não consulta Smoke no histórico nem no detalhe', testk.tenta(format('select historico_financeiro(%L)', smoke)) like '%permissão%' and testk.tenta(format('select detalhe_dia_financeiro(%L, %L)', smoke, hoje)) like '%permissão%');
  perform testk.chk('situação "aberto" da Start BR01 traz o caixa aberto', jsonb_array_length(historico_financeiro(null, hoje, hoje, null, 'aberto')) = 1);
  perform testk.como(dono);
  r := historico_financeiro(null, hoje - 1, hoje + 1, null, null);
  perform testk.chk('administrador geral tem visão consolidada (Smoke + Start BR01)', (select count(distinct e->>'loja_nome') from jsonb_array_elements(r) e) = 2, r::text);
  perform testk.chk('administrador geral abre o detalhe de qualquer loja', testk.tenta(format('select detalhe_dia_financeiro(%L, %L)', smoke, hoje)) = 'OK' and testk.tenta(format('select caixa_detalhe(%L)', cx1)) = 'OK');
  perform testk.como(rafael);
  perform testk.chk('rafael (Streaks) não vê nada da Smoke', jsonb_array_length(historico_financeiro(null, hoje - 1, hoje + 1, null, null)) = 0);

  -- ================= AVISOS =================
  perform testk.como(operador);
  perform testk.chk('operador não publica aviso', testk.tenta(format($q$select publicar_aviso(null,'comunicado','Teste aviso','texto','info',false,null,false,%L)$q$, array[startbr]::uuid[])) like '%Só gerente ou dono publica%');
  perform testk.como(luiz);
  perform testk.chk('gerente não publica aviso global', testk.tenta($q$select publicar_aviso(null,'comunicado','Teste global','texto','info',false,null,true,null)$q$) like '%administrador geral%');
  perform testk.chk('gerente não publica "mudança de sistema"', testk.tenta(format($q$select publicar_aviso(null,'sistema','Mudança','texto','info',false,null,false,%L)$q$, array[smoke]::uuid[])) like '%administrador geral%');
  perform testk.chk('aviso sem loja e não global recusado', testk.tenta($q$select publicar_aviso(null,'comunicado','Sem destino','texto','info',false,null,false,'{}')$q$) like '%pelo menos uma loja%');
  perform testk.chk('validade no passado recusada', testk.tenta(format($q$select publicar_aviso(null,'comunicado','Vencido','texto','info',false,now() - interval '1 day',false,%L)$q$, array[smoke]::uuid[])) like '%validade%');
  a1 := publicar_aviso(null, 'comunicado', 'Troca de turno', 'Conferir o caixa na troca.', 'atencao', true, null, false, array[smoke]);
  a2 := publicar_aviso(null, 'comunicado', 'Aviso Start e Smoke', 'Reunião sexta.', 'info', false, now() + interval '2 days', false, array[smoke, startbr]);
  perform testk.chk('gerente de Smoke/Start não publica em loja que não administra (Streaks)', testk.tenta(format($q$select publicar_aviso(null,'comunicado','Invasão','texto','info',false,null,false,%L)$q$, array[streaks]::uuid[])) like '%lojas que administra%');
  perform testk.como(rafael);
  perform testk.chk('gerente da Streaks não publica na Smoke', testk.tenta(format($q$select publicar_aviso(null,'comunicado','Invasão','texto','info',false,null,false,%L)$q$, array[smoke]::uuid[])) like '%lojas que administra%');
  perform testk.chk('gerente da Streaks não edita aviso da Smoke', testk.tenta(format($q$select publicar_aviso(%L,'comunicado','Troca de turno','mudei','info',false,null,false,%L)$q$, a1, array[streaks]::uuid[])) is not null
    and (select descricao from avisos where id = a1) = 'Conferir o caixa na troca.');
  perform testk.chk('gerente da Streaks não lista avisos da Smoke', testk.tenta(format('select listar_avisos(%L)', smoke)) like '%permissão%');
  perform testk.como(dono);
  a3 := publicar_aviso(null, 'sistema', 'Atualização do painel', 'Nova aba de caixa.', 'info', false, null, true, null);
  perform testk.chk('administrador geral publica aviso global', a3 is not null);
  perform testk.como(enzo);
  j := listar_avisos(startbr);
  perform testk.chk('enzo (Start) vê o aviso Start+Smoke e o global, mas NÃO o exclusivo da Smoke',
    exists (select 1 from jsonb_array_elements(j) e where e->>'titulo' = 'Aviso Start e Smoke') and exists (select 1 from jsonb_array_elements(j) e where e->>'titulo' = 'Atualização do painel')
    and not exists (select 1 from jsonb_array_elements(j) e where e->>'titulo' = 'Troca de turno'), (select string_agg(e->>'titulo', '|') from jsonb_array_elements(j) e));
  perform testk.chk('enzo só vê nomes de lojas que ele acessa no aviso', (select e->'lojas' from jsonb_array_elements(j) e where e->>'titulo' = 'Aviso Start e Smoke') = '["Start BR01"]'::jsonb);
  perform testk.chk('aviso começa como não lido', not (select (e->>'lido')::boolean from jsonb_array_elements(j) e where e->>'titulo' = 'Aviso Start e Smoke'));
  perform marcar_aviso_lido(a2, startbr);
  perform testk.chk('lido individual: enzo lê, aviso fica lido para ele', (select (e->>'lido')::boolean from jsonb_array_elements(listar_avisos(startbr)) e where e->>'titulo' = 'Aviso Start e Smoke'));
  perform testk.chk('enzo não marca aviso exclusivo da Smoke', testk.tenta(format('select marcar_aviso_lido(%L, %L)', a1, startbr)) like '%não encontrado%');
  perform testk.como(luiz);
  perform testk.chk('leitura é individual: Luiz ainda vê como NÃO lido', not (select (e->>'lido')::boolean from jsonb_array_elements(listar_avisos(smoke)) e where e->>'titulo' = 'Aviso Start e Smoke'));
  perform testk.chk('destaque vem primeiro na lista', listar_avisos(smoke)->0->>'titulo' = 'Troca de turno' and (listar_avisos(smoke)->0->>'destaque')::boolean);
  perform publicar_aviso(a2, 'comunicado', 'Aviso Start e Smoke', 'Reunião sexta.', 'info', false, (select valido_ate from avisos where id = a2), false, array[smoke, startbr]);
  perform testk.chk('salvar sem mudança relevante não muda a versão', (select versao = 1 from avisos where id = a2));
  perform publicar_aviso(a2, 'comunicado', 'Aviso Start e Smoke', 'Reunião MUDOU para sábado.', 'urgente', false, (select valido_ate from avisos where id = a2), false, array[smoke, startbr]);
  perform testk.chk('mudança relevante sobe a versão e guarda histórico', (select versao = 2 from avisos where id = a2) and (select count(*) from avisos_historico where aviso_id = a2) >= 3);
  perform testk.como(enzo);
  perform testk.chk('aviso já lido que mudou aparece como ATUALIZADO (não lido)', (select (e->>'atualizado')::boolean and not (e->>'lido')::boolean from jsonb_array_elements(listar_avisos(startbr)) e where e->>'titulo' = 'Aviso Start e Smoke'));
  perform testk.chk('gerente de outra loja não arquiva aviso da Smoke', testk.tenta(format('select arquivar_aviso(%L)', a1)) like '%não administra%' or testk.tenta(format('select arquivar_aviso(%L)', a1)) like '%Só%');
  perform testk.como(luiz);
  execute 'reset role'; update avisos set valido_ate = now() - interval '1 minute' where id = a2; perform testk.como(luiz);
  perform testk.chk('aviso com validade vencida some', not exists (select 1 from jsonb_array_elements(listar_avisos(smoke)) e where e->>'titulo' = 'Aviso Start e Smoke'));
  perform arquivar_aviso(a1);
  perform testk.chk('aviso arquivado some', not exists (select 1 from jsonb_array_elements(listar_avisos(smoke)) e where e->>'titulo' = 'Troca de turno'));

  -- ================= ALERTAS AUTOMÁTICOS =================
  j := listar_avisos(smoke);
  perform testk.chk('sem pendência: nenhum alerta de conta/comprovante/caixa antigo', not exists (select 1 from jsonb_array_elements(j) e where e->>'origem' = 'alerta' and e->>'chave' <> 'diferenca_fechamento'), j::text);
  insert into financeiro_lancamentos (loja_id, tipo, categoria, descricao, valor, status, vencimento) values (smoke, 'saida', 'aluguel', 'Aluguel atrasado', 800, 'pendente', hoje - 5);
  j := listar_avisos(smoke);
  perform testk.chk('conta vencida gera alerta URGENTE', exists (select 1 from jsonb_array_elements(j) e where e->>'chave' = 'contas_vencidas' and e->>'prioridade' = 'urgente' and e->>'titulo' like '1 conta%'));
  perform testk.chk('alerta urgente fica no topo', j->0->>'chave' = 'contas_vencidas');
  perform marcar_alerta_lido(smoke, 'contas_vencidas');
  perform testk.chk('alerta marcado como lido', (select (e->>'lido')::boolean from jsonb_array_elements(listar_avisos(smoke)) e where e->>'chave' = 'contas_vencidas'));
  perform testk.chk('marcar como lido NÃO resolve a pendência financeira', (select count(*) from financeiro_lancamentos where loja_id = smoke and status = 'pendente' and vencimento < hoje) = 1);
  insert into financeiro_lancamentos (loja_id, tipo, categoria, descricao, valor, status, vencimento) values (smoke, 'saida', 'frete', 'Frete atrasado', 50, 'pendente', hoje - 1);
  perform testk.chk('nova pendência reabre o alerta (atualizado)', (select (e->>'atualizado')::boolean and not (e->>'lido')::boolean from jsonb_array_elements(listar_avisos(smoke)) e where e->>'chave' = 'contas_vencidas'));
  insert into financeiro_lancamentos (loja_id, tipo, categoria, descricao, valor, status, exige_comprovante) values (smoke, 'saida', 'compra', 'Pods fornecedor', 300, 'pago', true) returning id into lanc;
  perform testk.chk('comprovante pendente gera alerta', exists (select 1 from jsonb_array_elements(listar_avisos(smoke)) e where e->>'chave' = 'comprovantes_pendentes'));
  perform marcar_comprovante_enviado(lanc);
  perform testk.chk('confirmar envio resolve o alerta de comprovante', not exists (select 1 from jsonb_array_elements(listar_avisos(smoke)) e where e->>'chave' = 'comprovantes_pendentes'));
  perform testk.chk('diferença de fechamento (+3 em 7 dias) gera alerta', exists (select 1 from jsonb_array_elements(listar_avisos(smoke)) e where e->>'chave' = 'diferenca_fechamento'));
  cx3 := abrir_caixa(smoke, 5);
  execute 'reset role'; alter table caixas disable trigger caixa_guard; update caixas set aberto_em = now() - interval '2 days' where id = cx3; alter table caixas enable trigger caixa_guard; perform testk.como(luiz);
  perform testk.chk('caixa aberto de dia anterior gera alerta URGENTE', exists (select 1 from jsonb_array_elements(listar_avisos(smoke)) e where e->>'chave' = 'caixa_dia_anterior' and e->>'prioridade' = 'urgente'));
  perform testk.como(enzo);
  perform testk.chk('alertas da Smoke não vazam para a Start BR01', not exists (select 1 from jsonb_array_elements(listar_avisos(startbr)) e where e->>'chave' in ('contas_vencidas','caixa_dia_anterior','diferenca_fechamento')));
  perform testk.como(operador);
  perform testk.chk('operador (com acesso à Smoke) não marca alerta de loja sem acesso', testk.tenta(format('select marcar_alerta_lido(%L, %L)', ez, 'contas_vencidas')) like '%permissão%');

  execute 'reset role';
  select jsonb_build_object('total', count(*), 'ok', count(*) filter (where x.ok), 'falhas', count(*) filter (where not x.ok),
         'detalhe_falhas', coalesce(jsonb_agg(jsonb_build_object('n', x.n, 'd', x.d)) filter (where not x.ok), '[]'::jsonb)) into r from testk.res x;
  raise exception 'RELATORIO_CAIXA: %', r::text;
end;
$teste$;

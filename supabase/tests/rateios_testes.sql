-- Testes de rateio de despesas e reembolsos entre lojas (007). Transação desfeita; relatório em "erro" RELATORIO_RATEIOS.
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
grant usage on schema testk to public; grant all on all tables in schema testk to public; grant execute on all functions in schema testk to public;

do $teste$
declare
  luiz uuid; victor uuid; enzo uuid; rafael uuid; operador uuid := gen_random_uuid(); dono uuid := gen_random_uuid(); estranho uuid := gen_random_uuid();
  smoke uuid; startbr uuid; ez uuid; streaks uuid; hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  itens3 jsonb; r jsonb; j jsonb; R1 uuid; R2 uuid; R3 uuid; R4 uuid; Rv uuid; pa uuid; pb uuid; pr1 uuid; pr2 uuid; rb1 uuid; rb2 uuid; est uuid; k uuid := gen_random_uuid();
  pth text; saldo_antes numeric; cx_antes int; msg text; v_old timestamptz;
begin
  select id into luiz from auth.users where email = 'luiz@painel.local';  select id into victor from auth.users where email = 'victor@painel.local';
  select id into enzo from auth.users where email = 'enzo@painel.local';  select id into rafael from auth.users where email = 'rafael@painel.local';
  select id into smoke from lojas where slug = 'smoke-club'; select id into startbr from lojas where slug = 'start-br01';
  select id into ez from lojas where slug = 'ez-store'; select id into streaks from lojas where slug = 'streaks-store';
  insert into auth.users (id, email) values (operador, 'op.rat@painel.local'), (dono, 'dono.rat@painel.local'), (estranho, 'est.rat@painel.local');
  insert into perfis (id, nome, papel) values (operador, 'Operador Rat', 'operador'), (dono, 'Dono Rat', 'dono'), (estranho, 'Estranho', 'operador');
  insert into perfis_lojas (perfil_id, loja_id) values (operador, smoke), (dono, startbr);
  itens3 := jsonb_build_array(jsonb_build_object('loja_id', smoke), jsonb_build_object('loja_id', startbr), jsonb_build_object('loja_id', ez));
  select count(*) into cx_antes from caixa_movimentos;

  -- ================= PRÉVIA E ARREDONDAMENTO =================
  perform testk.como(luiz);
  r := rateio_previa(900, 'igual', itens3);
  perform testk.chk('R$ 900 igual entre 3 lojas: 300 por loja, soma 900, nenhum ajuste', (select bool_and((e->>'valor')::numeric = 300 and (e->>'ajuste_centavos')::int = 0) from jsonb_array_elements(r->'parcelas') e) and (r->>'soma')::numeric = 900, r::text);
  r := rateio_previa(100, 'igual', itens3);
  perform testk.chk('R$ 100 entre 3 lojas fecha em 100,00: 33,34 + 33,33 + 33,33', (r->>'soma')::numeric = 100.00 and (r->>'ajustes')::int = 1
     and (select array_agg((e->>'valor')::numeric order by (e->>'loja_nome')) from jsonb_array_elements(r->'parcelas') e) = array[33.34, 33.33, 33.33]::numeric[], r::text);
  perform testk.chk('arredondamento determinístico: o centavo extra vai à 1ª loja por nome (EZ Store), em qualquer ordem de entrada', (r->'parcelas'->0->>'loja_nome') = 'EZ Store' and (r->'parcelas'->0->>'valor')::numeric = 33.34
     and rateio_previa(100, 'igual', jsonb_build_array(jsonb_build_object('loja_id', ez), jsonb_build_object('loja_id', startbr), jsonb_build_object('loja_id', smoke))) = r);
  perform testk.chk('mesma entrada → sempre o mesmo resultado (10 execuções)', (select count(distinct rateio_previa(100, 'igual', itens3)::text) from generate_series(1,10)) = 1);
  r := rateio_previa(1000.01, 'percentual', jsonb_build_array(jsonb_build_object('loja_id', smoke, 'percentual', 50), jsonb_build_object('loja_id', startbr, 'percentual', 30), jsonb_build_object('loja_id', ez, 'percentual', 20)));
  perform testk.chk('percentual 50/30/20 de 1000,01: maior resto recebe o centavo, soma exata', (r->>'soma')::numeric = 1000.01 and (select (e->>'valor')::numeric from jsonb_array_elements(r->'parcelas') e where e->>'loja_nome' = 'Smoke Club') = 500.01
     and (select (e->>'valor')::numeric from jsonb_array_elements(r->'parcelas') e where e->>'loja_nome' = 'Start BR01') = 300.00, r::text);
  r := rateio_previa(100, 'percentual', jsonb_build_array(jsonb_build_object('loja_id', smoke, 'percentual', 33.3333), jsonb_build_object('loja_id', startbr, 'percentual', 33.3333), jsonb_build_object('loja_id', ez, 'percentual', 33.3334)));
  perform testk.chk('percentual 33,3333/33,3333/33,3334 de 100: soma 100,00 exatos', (r->>'soma')::numeric = 100.00, r::text);
  r := rateio_previa(900, 'valores', jsonb_build_array(jsonb_build_object('loja_id', smoke, 'valor', 500), jsonb_build_object('loja_id', startbr, 'valor', 300), jsonb_build_object('loja_id', ez, 'valor', 100)));
  perform testk.chk('valores informados: aceitos quando somam o total', (r->>'soma')::numeric = 900);
  perform testk.chk('valores que não fecham em centavos são recusados', testk.tenta(format($q$select rateio_previa(900,'valores',%L::jsonb)$q$, jsonb_build_array(jsonb_build_object('loja_id', smoke, 'valor', 500), jsonb_build_object('loja_id', startbr, 'valor', 399.99)))) like '%difere do total%');
  perform testk.chk('percentuais que não somam 100 são recusados', testk.tenta(format($q$select rateio_previa(900,'percentual',%L::jsonb)$q$, jsonb_build_array(jsonb_build_object('loja_id', smoke, 'percentual', 50), jsonb_build_object('loja_id', startbr, 'percentual', 49.99)))) like '%precisam somar exatamente 100%');
  perform testk.chk('valor com 3 casas, loja repetida e loja única são recusados', testk.tenta(format($q$select rateio_previa(10.005,'igual',%L::jsonb)$q$, itens3)) like '%casas%'
     and testk.tenta(format($q$select rateio_previa(10,'igual',%L::jsonb)$q$, jsonb_build_array(jsonb_build_object('loja_id', smoke), jsonb_build_object('loja_id', smoke)))) like '%repetida%'
     and testk.tenta(format($q$select rateio_previa(10,'igual',%L::jsonb)$q$, jsonb_build_array(jsonb_build_object('loja_id', smoke)))) like '%pelo menos 2 lojas%');

  -- ================= CRIAÇÃO E PERMISSÕES =================
  R1 := criar_rateio('Reforma da fachada', 'manutenção', 900, hoje + 10, true, 'igual', itens3, k);
  perform testk.chk('rateio criado: 3 parcelas de 300, soma 900', testk.adm(format('select count(*) from rateio_parcelas where rateio_id=%L and valor=300 and ativa and versao=1', R1)) = 3);
  perform testk.chk('repetir a criação (mesma chave) não duplica', criar_rateio('Reforma da fachada', 'manutenção', 900, hoje + 10, true, 'igual', itens3, k) = R1 and testk.adm(format('select count(*) from rateios where chave_criacao=%L', k)) = 1);
  perform testk.chk('conta exclusiva continua sendo o padrão: rateio exige 2+ lojas e não mexe nas contas existentes', testk.adm('select count(*) from rateios') = 1);
  perform testk.como(victor);   -- gerente de Smoke e EZ (não de Start)
  perform testk.chk('gerente NÃO cria rateio com loja que não administra (Start BR01)', testk.tenta(format($q$select criar_rateio('Invasão','x',100,null,false,'igual',%L::jsonb,gen_random_uuid())$q$, itens3)) like '%lojas que administra%');
  R2 := criar_rateio('Internet Smoke+EZ', 'taxas', 1000, hoje - 2, false, 'igual', jsonb_build_array(jsonb_build_object('loja_id', smoke), jsonb_build_object('loja_id', ez)), gen_random_uuid());
  perform testk.chk('gerente cria rateio entre as lojas que administra', R2 is not null);
  perform testk.chk('prévia respeita a mesma regra de lojas', testk.tenta(format($q$select rateio_previa(100,'igual',%L::jsonb)$q$, itens3)) like '%administra%');
  perform testk.como(operador);
  perform testk.chk('operador não cria rateio', testk.tenta(format($q$select criar_rateio('Op','x',100,null,false,'igual',%L::jsonb,gen_random_uuid())$q$, jsonb_build_array(jsonb_build_object('loja_id', smoke), jsonb_build_object('loja_id', ez)))) like '%gerente ou dono%');
  perform testk.como(estranho);
  perform testk.chk('usuário sem loja não cria nem lista', testk.tenta(format($q$select criar_rateio('X','x',100,null,false,'igual',%L::jsonb,gen_random_uuid())$q$, itens3)) like '%gerente ou dono%' and testk.tenta('select listar_rateios()') like '%Sem permissão%');
  execute 'reset role'; execute 'set local role anon';
  perform testk.chk('anônimo não executa nem lê tabelas do rateio', testk.tenta(format($q$select criar_rateio('X','x',100,null,false,'igual',%L::jsonb,gen_random_uuid())$q$, itens3)) like '%permission denied%' and testk.tenta('select * from rateios') like '%permission denied%');
  perform testk.como(dono);
  R3 := criar_rateio('Contador (dono, 3 lojas)', 'serviços', 600, null, false, 'igual', itens3, gen_random_uuid());
  perform testk.chk('dono (vinculado só à Start) administra todas as lojas: cria rateio com 3', R3 is not null);
  perform testk.como(luiz);
  perform testk.chk('tabelas do rateio não são lidas nem escritas direto pelo painel', testk.tenta('select * from rateio_pagamentos') like '%permission denied%'
     and testk.tenta(format($q$insert into rateio_pagamentos(rateio_id,loja_id,valor,data_pagamento,forma_pagamento,chave,criado_por) values (%L,%L,1,%L,'Pix',gen_random_uuid(),%L)$q$, R1, smoke, hoje, luiz)) like '%permission denied%');

  -- ================= EXEMPLO OBRIGATÓRIO (A=Smoke, B=Start, C=EZ; despesa R$ 900) =================
  saldo_antes := (financeiro_resumo(smoke, null, null)->>'saldo_caixa')::numeric;
  j := registrar_pagamento_rateio(R1, smoke, 900, hoje, 'Transferência', 'paguei tudo', gen_random_uuid()); pr1 := (j->>'pagamento_id')::uuid;
  perform testk.chk('A paga tudo: externo quitado (saldo 0) e A tem R$ 600 a recuperar; B e C devem R$ 300', (j->>'saldo_externo')::numeric = 0
     and testk.adm(format($q$select posicao from rateio_posicoes(%L) where loja_uuid=%L$q$, R1, smoke)) = 600 and testk.adm(format($q$select posicao from rateio_posicoes(%L) where loja_uuid=%L$q$, R1, startbr)) = -300
     and testk.adm(format($q$select posicao from rateio_posicoes(%L) where loja_uuid=%L$q$, R1, ez)) = -300, j::text);
  perform testk.chk('depois de quitada, novo pagamento externo é recusado', testk.tenta(format($q$select registrar_pagamento_rateio(%L,%L,0.01,null,'Pix',null,gen_random_uuid())$q$, R1, startbr)) like '%já está quitada%');
  perform testk.como(enzo);   -- gerente só da Start BR01 (B)
  j := registrar_reembolso(R1, startbr, smoke, 100, hoje, 'devolução parcial', gen_random_uuid());
  rb1 := (j->>'reembolso_id')::uuid;
  perform testk.chk('B reembolsa R$ 100 a A: B deve R$ 200, A tem R$ 500 a recuperar, C continua devendo R$ 300', testk.adm(format($q$select posicao from rateio_posicoes(%L) where loja_uuid=%L$q$, R1, startbr)) = -200
     and testk.adm(format($q$select posicao from rateio_posicoes(%L) where loja_uuid=%L$q$, R1, smoke)) = 500 and testk.adm(format($q$select posicao from rateio_posicoes(%L) where loja_uuid=%L$q$, R1, ez)) = -300);
  perform testk.como(luiz);
  r := rateio_detalhe(R1);
  perform testk.chk('despesa consolidada permanece R$ 900; pago ao externo 900; reembolso NÃO quita de novo a conta externa', (r->'rateio'->>'despesa_consolidada')::numeric = 900 and (r->'rateio'->>'pago_externo')::numeric = 900 and (r->'rateio'->>'saldo_externo')::numeric = 0, (r->'rateio')::text);
  perform testk.chk('reembolso não cria receita nem despesa: o fluxo do rateio soma −900 (um único pagamento), reembolso fora', testk.adm(format($q$select coalesce(sum(efeito),0) from fluxo_pago_itens() where lancamento_id=%L$q$, R1)) = -900
     and testk.adm(format($q$select count(*) from fluxo_pago_itens() where lancamento_id=%L$q$, R1)) = 1);
  perform testk.chk('a despesa aparece só na loja que pagou: Smoke −900, Start e EZ sem efeito', (financeiro_resumo(smoke, null, null)->>'saldo_caixa')::numeric = saldo_antes - 900
     and testk.adm(format($q$select coalesce(sum(efeito),0) from fluxo_pago_itens() where lancamento_id=%L and loja_id in (%L,%L)$q$, R1, startbr, ez)) = 0);
  perform testk.chk('NÃO movimenta o caixa: nenhum movimento de caixa criado', testk.adm('select count(*) from caixa_movimentos') = cx_antes and testk.adm('select count(*) from caixas') = 0);
  perform testk.chk('reembolso acima do saldo devido pela origem (B deve 200; 200,01 recusado)', testk.tenta(format($q$select registrar_reembolso(%L,%L,%L,200.01,null,null,gen_random_uuid())$q$, R1, startbr, smoke)) like '%saldo devido pela loja de origem%');
  perform testk.chk('C não reembolsa mais do que deve (C deve 300; 300,01 recusado)', testk.tenta(format($q$select registrar_reembolso(%L,%L,%L,300.01,null,null,gen_random_uuid())$q$, R1, ez, smoke)) like '%saldo devido pela loja de origem%');
  perform testk.chk('destino que não tem a recuperar não recebe (B→C recusado) e quem tem a recuperar não reembolsa (A→B recusado)', testk.tenta(format($q$select registrar_reembolso(%L,%L,%L,10,null,null,gen_random_uuid())$q$, R1, startbr, ez)) like '%valor a recuperar da loja de destino%'
     and testk.tenta(format($q$select registrar_reembolso(%L,%L,%L,10,null,null,gen_random_uuid())$q$, R1, smoke, startbr)) like '%saldo devido pela loja de origem%');
  perform testk.chk('origem = destino, valor 0/3 casas e data futura recusados', testk.tenta(format($q$select registrar_reembolso(%L,%L,%L,10,null,null,gen_random_uuid())$q$, R1, smoke, smoke)) like '%diferentes%'
     and testk.tenta(format($q$select registrar_reembolso(%L,%L,%L,0.001,null,null,gen_random_uuid())$q$, R1, startbr, smoke)) like '%casas%' and testk.tenta(format($q$select registrar_reembolso(%L,%L,%L,10,%L,null,gen_random_uuid())$q$, R1, startbr, smoke, hoje + 1)) like '%futura%');
  k := gen_random_uuid();
  j := registrar_reembolso(R1, ez, smoke, 150, hoje, 'C paga parte', k); rb2 := (j->>'reembolso_id')::uuid;
  perform testk.chk('C reembolsa 150: C deve 150, A recupera 350', testk.adm(format($q$select posicao from rateio_posicoes(%L) where loja_uuid=%L$q$, R1, ez)) = -150 and testk.adm(format($q$select posicao from rateio_posicoes(%L) where loja_uuid=%L$q$, R1, smoke)) = 350);
  perform testk.chk('requisição repetida do reembolso (mesma chave) não duplica', (registrar_reembolso(R1, ez, smoke, 150, hoje, 'C paga parte', k)->>'repetido')::boolean and testk.adm(format('select count(*) from rateio_reembolsos where rateio_id=%L', R1)) = 2
     and testk.tenta(format($q$select registrar_reembolso(%L,%L,%L,100,null,null,%L)$q$, R1, ez, smoke, k)) like '%já foi usada%');

  -- ================= ESTORNOS APÓS REEMBOLSO =================
  perform testk.chk('estorno do pagamento externo é recusado enquanto houver reembolsos que dependem dele', testk.tenta(format($q$select estornar_pagamento_rateio(%L,'pagamento lançado errado')$q$, pr1)) like '%reembolsos registrados dependem%');
  perform testk.como(operador);
  perform testk.chk('operador não estorna reembolso nem pagamento', testk.tenta(format($q$select estornar_reembolso(%L,'motivo qualquer')$q$, rb1)) like '%gerente%' and testk.tenta(format($q$select estornar_pagamento_rateio(%L,'motivo qualquer')$q$, pr1)) like '%gerente%');
  perform testk.como(rafael);
  perform testk.chk('loja que não participa (Streaks) não estorna nem registra', testk.tenta(format($q$select estornar_reembolso(%L,'motivo qualquer')$q$, rb1)) like '%gerente%' and testk.tenta(format($q$select registrar_reembolso(%L,%L,%L,1,null,null,gen_random_uuid())$q$, R1, startbr, smoke)) like '%permiss%');
  perform testk.como(enzo);
  perform testk.chk('estorno sem motivo suficiente é recusado', testk.tenta(format($q$select estornar_reembolso(%L,'abc')$q$, rb1)) like '%motivo%');
  j := estornar_reembolso(rb1, 'valor devolvido errado');
  perform testk.chk('estorno do reembolso: B volta a dever 300, A recupera 500 (150 de C ainda valem); original preservado', testk.adm(format($q$select posicao from rateio_posicoes(%L) where loja_uuid=%L$q$, R1, startbr)) = -300
     and testk.adm(format($q$select posicao from rateio_posicoes(%L) where loja_uuid=%L$q$, R1, smoke)) = 450 and testk.adm(format($q$select count(*) from rateio_reembolsos where id=%L and tipo='reembolso' and valor=100$q$, rb1)) = 1
     and testk.adm(format($q$select count(*) from rateio_reembolsos where estorno_de=%L and motivo='valor devolvido errado' and criado_por=%L$q$, rb1, enzo)) = 1);
  perform testk.chk('estornar duas vezes / estorno de estorno recusados', testk.tenta(format($q$select estornar_reembolso(%L,'de novo por engano')$q$, rb1)) like '%já foi estornado%'
     and testk.tenta(format($q$select estornar_reembolso(%L,'estorno do estorno')$q$, (j->>'estorno_id')::uuid)) like '%não pode ser estornado%');
  perform testk.como(luiz);
  j := estornar_reembolso(rb2, 'estorno do reembolso da C');
  est := (estornar_pagamento_rateio(pr1, 'pagamento externo lançado errado')->>'estorno_id')::uuid;
  perform testk.chk('após estornar os reembolsos, o pagamento externo pode ser estornado: despesa consolidada volta a 0 e todos devem 300', (rateio_detalhe(R1)->'rateio'->>'despesa_consolidada')::numeric = 0 and (rateio_detalhe(R1)->'rateio'->>'saldo_externo')::numeric = 900
     and (select bool_and((e->>'posicao')::numeric = -300) from jsonb_array_elements(rateio_detalhe(R1)->'posicoes') e));
  perform testk.chk('fluxo: pagamento (−900) e estorno (+900) se anulam e ficam registrados', testk.adm(format($q$select coalesce(sum(efeito),0) from fluxo_pago_itens() where lancamento_id=%L$q$, R1)) = 0
     and testk.adm(format($q$select count(*) from fluxo_pago_itens() where lancamento_id=%L and origem='rateio_estorno'$q$, R1)) = 1);
  perform testk.chk('auditoria guarda criação, pagamento, reembolsos e estornos com motivo e responsável', testk.adm(format($q$select count(*) from rateio_auditoria where rateio_id=%L and acao in ('criado','pagamento_externo','reembolso','estorno_reembolso','estorno_pagamento')$q$, R1)) = 7
     and testk.adm(format($q$select count(*) from rateio_auditoria where rateio_id=%L and acao='estorno_reembolso' and motivo='valor devolvido errado' and por=%L$q$, R1, enzo)) = 1);

  -- ================= PAGAMENTOS EXTERNOS PARCIAIS (R2: 1000 entre Smoke e EZ; 500 cada) =================
  perform testk.como(victor);
  pa := (registrar_pagamento_rateio(R2, smoke, 100, hoje, 'Pix', 'Smoke paga parte', gen_random_uuid())->>'pagamento_id')::uuid;
  perform testk.chk('pagamento externo parcial: saldo externo 900 e situação parcial', (rateio_detalhe(R2)->'rateio'->>'saldo_externo')::numeric = 900 and rateio_detalhe(R2)->'rateio'->>'situacao' = 'parcial');
  k := gen_random_uuid(); j := registrar_pagamento_rateio(R2, ez, 250, hoje, 'Boleto', null, k);
  perform testk.chk('EZ paga 250 em seguida: externo pago 350, saldo 650', (j->>'saldo_externo')::numeric = 650 and (j->>'pago_externo')::numeric = 350);
  perform testk.chk('repetição da mesma requisição não registra de novo (1 pagamento, total igual)', (registrar_pagamento_rateio(R2, ez, 250, hoje, 'Boleto', null, k)->>'repetida')::boolean and testk.adm(format($q$select count(*) from rateio_pagamentos where rateio_id=%L and chave=%L$q$, R2, k)) = 1
     and testk.tenta(format($q$select registrar_pagamento_rateio(%L,%L,251,null,'Boleto',null,%L)$q$, R2, ez, k)) like '%já foi usada%');
  perform testk.chk('pagamento acima do saldo externo é recusado (650,01); exatamente 650 é aceito', testk.tenta(format($q$select registrar_pagamento_rateio(%L,%L,650.01,null,'Pix',null,gen_random_uuid())$q$, R2, smoke)) like '%maior que o saldo externo%');
  perform testk.chk('loja que não participa não paga; forma e data inválidas recusadas', testk.tenta(format($q$select registrar_pagamento_rateio(%L,%L,10,null,'Pix',null,gen_random_uuid())$q$, R2, startbr)) like '%permissão%'
     and testk.tenta(format($q$select registrar_pagamento_rateio(%L,%L,10,null,'Bitcoin',null,gen_random_uuid())$q$, R2, smoke)) like '%Forma%' and testk.tenta(format($q$select registrar_pagamento_rateio(%L,%L,10,%L,'Pix',null,gen_random_uuid())$q$, R2, smoke, hoje + 1)) like '%futura%');
  perform testk.chk('posições após pagamentos parciais: Smoke pagou 100 (deve 400); EZ pagou 250 (deve 250)', testk.adm(format($q$select posicao from rateio_posicoes(%L) where loja_uuid=%L$q$, R2, smoke)) = -400 and testk.adm(format($q$select posicao from rateio_posicoes(%L) where loja_uuid=%L$q$, R2, ez)) = -250);
  perform testk.chk('reembolso antes de haver quem tenha a recuperar é recusado', testk.tenta(format($q$select registrar_reembolso(%L,%L,%L,10,null,null,gen_random_uuid())$q$, R2, smoke, ez)) like '%valor a recuperar%');
  perform registrar_pagamento_rateio(R2, ez, 650, hoje, 'Pix', 'EZ quita o resto', gen_random_uuid());
  perform testk.chk('EZ paga o restante: externo quitado; Smoke deve 400 a EZ (que tem 400 a recuperar)', testk.adm(format($q$select posicao from rateio_posicoes(%L) where loja_uuid=%L$q$, R2, ez)) = 400 and testk.adm(format($q$select posicao from rateio_posicoes(%L) where loja_uuid=%L$q$, R2, smoke)) = -400
     and rateio_detalhe(R2)->'rateio'->>'situacao' = 'paga');
  perform registrar_reembolso(R2, smoke, ez, 400, hoje, 'acerto total', gen_random_uuid());
  perform testk.chk('reembolso integral quita o acerto entre lojas (todas as posições 0) sem alterar o total externo (1000)', (select bool_and((e->>'posicao')::numeric = 0) from jsonb_array_elements(rateio_detalhe(R2)->'posicoes') e) and (rateio_detalhe(R2)->'rateio'->>'pago_externo')::numeric = 1000);
  perform testk.chk('1000 em R2 aparecem UMA vez no consolidado (soma dos efeitos = −1000)', testk.adm(format($q$select sum(efeito) from fluxo_pago_itens() where lancamento_id=%L$q$, R2)) = -1000);
  j := estornar_pagamento_rateio(pa, 'pagamento do Smoke lançado em duplicidade');
  perform testk.chk('estorno do pagamento externo de 100 do Smoke (o reembolso de 400 ainda tem lastro): aceito, saldo externo volta a 100', (j->>'saldo_externo')::numeric = 100 and rateio_detalhe(R2)->'rateio'->>'situacao' = 'parcial');

  -- ================= REVISÃO / CANCELAMENTO =================
  perform testk.chk('rateio com movimentação não pode ser revisado nem cancelado', testk.tenta(format($q$select revisar_rateio(%L,'Novo nome',1000,null,'igual',%L::jsonb,'revisão com movimento')$q$, R2, jsonb_build_array(jsonb_build_object('loja_id', smoke), jsonb_build_object('loja_id', ez)))) like '%já tem movimentações%'
     and testk.tenta(format($q$select cancelar_rateio(%L,'cancelar com movimento')$q$, R2)) like '%já tem movimentações%');
  perform testk.como(luiz);
  perform testk.como(dono);
  perform testk.chk('revisão exige motivo e respeita lojas do gerente', testk.tenta(format($q$select revisar_rateio(%L,'Contador',600,null,'valores',%L::jsonb,'abc')$q$, R3, jsonb_build_array(jsonb_build_object('loja_id', smoke, 'valor', 400), jsonb_build_object('loja_id', startbr, 'valor', 200)))) like '%motivo%');
  j := to_jsonb(revisar_rateio(R3, 'Contador (revisado)', 600, null, 'valores', jsonb_build_array(jsonb_build_object('loja_id', smoke, 'valor', 400), jsonb_build_object('loja_id', startbr, 'valor', 200)), 'divisão combinada com o contador'));
  perform testk.chk('revisão cria versão 2 com 2 parcelas (400+200) e preserva as 3 parcelas da versão 1 como inativas', (j)::int = 2 and testk.adm(format('select count(*) from rateio_parcelas where rateio_id=%L and versao=1 and not ativa', R3)) = 3
     and testk.adm(format('select sum(valor) from rateio_parcelas where rateio_id=%L and versao=2 and ativa', R3)) = 600
     and testk.adm(format($q$select count(*) from rateio_auditoria where rateio_id=%L and acao='revisado' and motivo='divisão combinada com o contador' and por=%L$q$, R3, dono)) = 1);
  perform testk.como(victor);
  perform testk.chk('gerente não revisa rateio que envolve loja que não administra (Start BR01)', testk.tenta(format($q$select revisar_rateio(%L,'Invasão',600,null,'igual',%L::jsonb,'tentativa indevida')$q$, R3, jsonb_build_array(jsonb_build_object('loja_id', smoke), jsonb_build_object('loja_id', ez)))) like '%administra%');
  perform testk.como(dono);
  perform cancelar_rateio(R3, 'despesa lançada por engano');
  perform testk.chk('cancelar rateio sem movimento: status cancelado e não recebe pagamentos', testk.adm(format($q$select count(*) from rateios where id=%L and status='cancelado'$q$, R3)) = 1
     and testk.tenta(format($q$select registrar_pagamento_rateio(%L,%L,10,null,'Pix',null,gen_random_uuid())$q$, R3, startbr)) like '%cancelado%');
  execute 'reset role'; perform set_config('app.rateio_op', '', true);   -- (o teste é uma transação só: limpa a marca que as funções deixaram)
  perform testk.chk('rateio, parcelas e movimentações não mudam por UPDATE/DELETE direto (nem pelo dono do banco)', testk.tenta(format('update rateios set valor_total = 1 where id = %L', R1)) like '%só pode ser alterado pelas funções%'
     and testk.tenta(format('update rateio_parcelas set valor = 1 where rateio_id = %L', R1)) like '%só pode ser alterado pelas funções%' and testk.tenta('delete from rateio_pagamentos') like '%não pode ser alterado%'
     and testk.tenta('update rateio_reembolsos set valor = 1') like '%não pode ser alterado%' and testk.tenta('delete from rateio_auditoria') like '%não pode ser alterado%' and testk.tenta('delete from rateios') like '%não pode ser apagado%');

  -- ================= PRIVACIDADE: o que cada loja enxerga =================
  perform testk.como(enzo);   -- só Start BR01
  r := listar_rateios();
  perform testk.chk('enzo (Start) vê só rateios em que a Start participa (R1 e R3-cancelado), não o R2 entre Smoke e EZ', (select count(*) from jsonb_array_elements(r) e where (e->>'id')::uuid = R2) = 0 and (select count(*) from jsonb_array_elements(r) e where (e->>'id')::uuid = R1) = 1);
  perform testk.chk('na lista, enzo vê a posição só da própria loja', (select jsonb_array_length(e->'minhas') = 1 and e->'minhas'->0->>'loja_nome' = 'Start BR01' from jsonb_array_elements(r) e where (e->>'id')::uuid = R1));
  perform testk.chk('no detalhe, enzo vê todas as parcelas/pagamentos/reembolsos do rateio (para conferir), mas é só deste rateio', jsonb_array_length(rateio_detalhe(R1)->'posicoes') = 3 and jsonb_array_length(rateio_detalhe(R1)->'pagamentos') = 2);
  perform testk.chk('enzo não abre o rateio R2 nem ganha acesso ao financeiro das outras lojas', testk.tenta(format('select rateio_detalhe(%L)', R2)) like '%sem permissão%'
     and testk.tenta(format('select listar_contas(%L)', smoke)) like '%permissão%' and testk.tenta(format('select financeiro_resumo(%L,null,null)', smoke)) like '%permissão%' and testk.tenta(format('select listar_rateios(%L)', smoke)) like '%permissão%');
  perform testk.chk('enzo só pode pagar/registrar pela própria loja (pode_pagar_lojas = Start BR01)', jsonb_array_length(rateio_detalhe(R1)->'pode_pagar_lojas') = 1 and rateio_detalhe(R1)->'pode_pagar_lojas'->0->>'loja_nome' = 'Start BR01');
  perform testk.como(rafael);
  perform testk.chk('rafael (Streaks) não vê nenhum rateio', jsonb_array_length(listar_rateios()) = 0 and testk.tenta(format('select rateio_detalhe(%L)', R1)) like '%sem permissão%');
  perform testk.como(dono);
  perform testk.chk('dono vê todos os rateios (R1, R2, R3) e todas as lojas', jsonb_array_length(listar_rateios()) = 3 and jsonb_array_length(rateio_detalhe(R2)->'pode_pagar_lojas') = 2);
  perform testk.como(luiz);
  perform testk.chk('filtro de situação funciona (pendente / parcial / cancelado)', (select count(*) from jsonb_array_elements(listar_rateios(null, 'pendente')) e) = 1 and (select count(*) from jsonb_array_elements(listar_rateios(null, 'parcial')) e) = 1 and (select count(*) from jsonb_array_elements(listar_rateios(null, 'cancelado')) e) = 1
     and testk.tenta($q$select listar_rateios(null,'xyz')$q$) like '%Situação inválida%');

  -- ================= COMPROVANTES (Storage simulado só nas políticas) =================
  R4 := criar_rateio('Energia compartilhada', 'energia', 300, hoje - 1, true, 'igual', jsonb_build_array(jsonb_build_object('loja_id', smoke), jsonb_build_object('loja_id', ez)), gen_random_uuid());
  perform testk.chk('alerta "despesa compartilhada com saldo externo vencido" conta R2 e R4 (2)', exists (select 1 from jsonb_array_elements(listar_avisos(smoke)) e where e->>'chave' = 'rateios_vencidos' and e->>'titulo' like '2 despesa%'));
  pr1 := (registrar_pagamento_rateio(R4, smoke, 300, hoje, 'Pix', null, gen_random_uuid())->>'pagamento_id')::uuid;
  perform testk.chk('quitado o R4, o alerta passa a contar só o R2 (1) — e o R2 vencido segue alertando', exists (select 1 from jsonb_array_elements(listar_avisos(smoke)) e where e->>'chave' = 'rateios_vencidos' and e->>'titulo' like '1 despesa%'));
  pth := 'rateio/' || R4::text || '/' || pr1::text || '/' || gen_random_uuid()::text || '.pdf';
  perform testk.chk('upload do comprovante do pagamento externo permitido ao pagador (política do bucket)', testk.tenta(format($q$insert into storage.objects(bucket_id,name,metadata) values ('comprovantes',%L,'{"size":900,"mimetype":"application/pdf"}')$q$, pth)) = 'OK');
  perform testk.como(rafael);
  perform testk.chk('rafael não envia comprovante para pagamento de rateio', testk.tenta(format($q$insert into storage.objects(bucket_id,name,metadata) values ('comprovantes',%L,'{}')$q$, 'rateio/' || R4::text || '/' || pr1::text || '/' || gen_random_uuid()::text || '.pdf')) like '%row-level security%');
  perform testk.como(luiz);
  perform testk.chk('registrar comprovante: tipo/tamanho/caminho inválidos recusados', testk.tenta(format($q$select registrar_comprovante_rateio(%L,null,%L,'a.pdf','image/png',900)$q$, pr1, pth)) like '%extensão%'
     and testk.tenta(format($q$select registrar_comprovante_rateio(%L,null,%L,'a.pdf','application/pdf',999)$q$, pr1, pth)) like '%não confere%'
     and testk.tenta(format($q$select registrar_comprovante_rateio(%L,null,%L,'a.pdf','application/pdf',900)$q$, pr1, 'rateio/' || R4::text || '/' || gen_random_uuid()::text || '/' || gen_random_uuid()::text || '.pdf')) like '%inválido%');
  perform registrar_comprovante_rateio(pr1, null, pth, 'nf.pdf', 'application/pdf', 900);
  perform testk.chk('comprovante do pagamento externo registrado (idempotente)', registrar_comprovante_rateio(pr1, null, pth, 'nf.pdf', 'application/pdf', 900) is not null and testk.adm(format('select count(*) from comprovantes_rateio where pagamento_id=%L', pr1)) = 1);
  perform testk.como(victor);    -- Smoke+EZ: reembolso de EZ para Smoke? Smoke pagou 300 (parcela 150): Smoke +150, EZ −150
  rb1 := (registrar_reembolso(R4, ez, smoke, 150, hoje, 'EZ devolve', gen_random_uuid())->>'reembolso_id')::uuid;
  perform testk.chk('reembolso SEM comprovante é válido (comprovante opcional)', testk.adm(format('select count(*) from comprovantes_rateio where reembolso_id=%L', rb1)) = 0 and rb1 is not null);
  pth := 'rateio/' || R4::text || '/' || rb1::text || '/' || gen_random_uuid()::text || '.png';
  perform testk.chk('comprovante opcional do reembolso pode ser enviado e vinculado por quem participa', testk.tenta(format($q$insert into storage.objects(bucket_id,name,metadata) values ('comprovantes',%L,'{"size":500,"mimetype":"image/png"}')$q$, pth)) = 'OK'
     and testk.tenta(format($q$select registrar_comprovante_rateio(null,%L,%L,'pix.png','image/png',500)$q$, rb1, pth)) = 'OK');
  perform testk.chk('é preciso informar pagamento OU reembolso', testk.tenta(format($q$select registrar_comprovante_rateio(%L,%L,%L,'x.pdf','application/pdf',1)$q$, pr1, rb1, pth)) like '%OU%');
  perform testk.chk('leitura: pagador e reembolsante leem; quem não participa não lê', (select count(*) from storage.objects where name = pth) = 1);
  perform testk.como(rafael);
  perform testk.chk('rafael (não participa) NÃO lê comprovantes do rateio', (select count(*) from storage.objects where name like 'rateio/%') = 0);
  perform testk.como(enzo);
  perform testk.chk('enzo (Start, não participa de R4) também NÃO lê', (select count(*) from storage.objects where name like 'rateio/' || R4::text || '/%') = 0);
  perform testk.como(victor);
  perform estornar_reembolso(rb1, 'reembolso lançado em duplicidade');
  perform testk.chk('reembolso estornado não recebe novos comprovantes', testk.tenta(format($q$select registrar_comprovante_rateio(null,%L,%L,'x.png','image/png',500)$q$, rb1, 'rateio/' || R4::text || '/' || rb1::text || '/' || gen_random_uuid()::text || '.png')) like '%estornado%');
  perform testk.como(dono);
  perform testk.chk('dono lê comprovantes de qualquer rateio', (select count(*) from storage.objects where name like 'rateio/' || R4::text || '/%') = 2);
  execute 'reset role';
  update storage.objects set created_at = now() - interval '3 days' where bucket_id = 'comprovantes';
  insert into storage.objects(bucket_id, name, metadata, created_at) values ('comprovantes', 'rateio/' || R4::text || '/' || pr1::text || '/' || gen_random_uuid()::text || '.pdf', '{}', now() - interval '3 days');
  perform testk.chk('limpeza de órfãos preserva arquivos vinculados a comprovantes de rateio e lista só o não vinculado', (select count(*) from comprovantes_orfaos('24 hours')) = 1);

  execute 'reset role';
  select jsonb_build_object('total', count(*), 'ok', count(*) filter (where x.ok), 'falhas', count(*) filter (where not x.ok),
         'detalhe_falhas', coalesce(jsonb_agg(jsonb_build_object('n', x.n, 'd', x.d)) filter (where not x.ok), '[]'::jsonb)) into r from testk.res x;
  raise exception 'RELATORIO_RATEIOS: %', r::text;
end;
$teste$;

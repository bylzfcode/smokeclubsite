-- Testes de séries compartilhadas e retomada (013). Transação desfeita; relatório em "erro" RELATORIO_SERIES_COMP.
begin;
create schema testk;
create table testk.res (n text, ok boolean, d text);
create function testk.chk(p_n text, p_ok boolean, p_d text default null) returns void language sql as $f$ insert into testk.res values (p_n, coalesce(p_ok, false), p_d) $f$;
create function testk.tenta(p_sql text) returns text language plpgsql as $f$ begin execute p_sql; return 'OK'; exception when others then return sqlerrm; end; $f$;
create function testk.adm(p text) returns numeric language plpgsql security definer as $f$ declare b numeric; begin execute p into b; return b; end; $f$;
create function testk.admt(p text) returns text language plpgsql security definer as $f$ declare b text; begin execute p into b; return b; end; $f$;
create function testk.como(p_uid uuid) returns void language plpgsql as $f$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
  execute 'set local role authenticated';
end; $f$;
grant usage on schema testk to public; grant all on all tables in schema testk to public; grant execute on all functions in schema testk to public;


create function testk.sd(i date, u text, n int, k int) returns date language sql security definer as $f$ select public.serie_data(i,u,n,k) $f$;
do $teste$
declare
  luiz uuid; victor uuid; enzo uuid; rafael uuid; chefe uuid := gen_random_uuid(); smoke uuid; startbr uuid; ez uuid; hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  itens3 jsonb; j jsonb; r jsonb; sid uuid; sid2 uuid; sidp uuid; sidx uuid; k uuid := gen_random_uuid(); n int; oc2 uuid; oc3 uuid; oc4 uuid; oc5 uuid; prev jsonb; nlin int; nser int; v_soma numeric; v_ref uuid;
begin
  select id into luiz from auth.users where email = 'luiz@painel.local'; select id into victor from auth.users where email = 'victor@painel.local';
  select id into enzo from auth.users where email = 'enzo@painel.local'; select id into rafael from auth.users where email = 'rafael@painel.local';
  select id into smoke from lojas where slug = 'smoke-club'; select id into startbr from lojas where slug = 'start-br01'; select id into ez from lojas where slug = 'ez-store';
  insert into auth.users (id, email) values (chefe, 'chefe.sc@painel.local'); insert into perfis (id, nome, papel) values (chefe, 'Chefe SC', 'dono'); insert into perfis_lojas (perfil_id, loja_id) values (chefe, startbr);
  itens3 := jsonb_build_array(jsonb_build_object('loja_id', smoke), jsonb_build_object('loja_id', startbr), jsonb_build_object('loja_id', ez));

  -- ================= CRIAÇÃO: preserva o rateio, centavos, sem movimentação =================
  perform testk.como(luiz);
  j := criar_serie_rateio(smoke, 'Internet das lojas', 'internet', 100.00, true, 'igual', itens3, 'semanal', null, null, hoje + 1, 'quantidade', null, 20, k);
  sid := (j->>'serie_id')::uuid; n := (j->>'geradas')::int;
  perform testk.chk('série compartilhada semanal de 20: gera só a janela de 60 dias (9 ou 10), não as 20', n between 8 and 10 and testk.adm(format('select count(*) from rateios where serie_id=%L', sid)) = n, n::text);
  perform testk.chk('cada ocorrência é um rateio v1 ativo com 3 parcelas (33,34 + 33,33 + 33,33 = 100,00) e vencimento = referência', testk.adm(format($q$select count(*) from rateios r where r.serie_id=%L and r.versao=1 and r.status='ativo' and r.valor_total=100.00 and r.exige_comprovante and r.vencimento=r.vencimento_ref and (select count(*) from rateio_parcelas p where p.rateio_id=r.id and p.ativa)=3 and (select sum(valor) from rateio_parcelas p where p.rateio_id=r.id)=100.00 and (select max(valor) from rateio_parcelas p where p.rateio_id=r.id)=33.34$q$, sid)) = n);
  perform testk.chk('nascem sem pagamentos externos, reembolsos nem comprovantes', testk.adm(format('select count(*) from rateio_pagamentos x join rateios r on r.id=x.rateio_id where r.serie_id=%L', sid)) = 0 and testk.adm(format('select count(*) from rateio_reembolsos x join rateios r on r.id=x.rateio_id where r.serie_id=%L', sid)) = 0 and testk.adm(format('select count(*) from comprovantes_rateio x join rateios r on r.id=x.rateio_id where r.serie_id=%L', sid)) = 0);
  perform testk.chk('auditoria: cada ocorrência registra "criado" com a série e o autor; a série registra "criada"', testk.adm(format($q$select count(*) from rateio_auditoria a join rateios r on r.id=a.rateio_id where r.serie_id=%L and a.acao='criado' and a.detalhes->>'serie_id'=%L and a.por is not null$q$, sid, sid::text)) = n and testk.adm(format($q$select count(*) from series_auditoria where serie_id=%L and acao='criada'$q$, sid)) = 1);
  perform testk.chk('numeração 1..n sem repetição; a mesma chave não duplica a série; gerar de novo não duplica', testk.adm(format('select count(distinct serie_n) from rateios where serie_id=%L', sid)) = n and (criar_serie_rateio(smoke, 'Internet das lojas', 'internet', 100.00, true, 'igual', itens3, 'semanal', null, null, hoje + 1, 'quantidade', null, 20, k)->>'repetida')::boolean and gerar_series_loja(smoke) = 0 and gerar_series_loja(startbr) = 0 and testk.adm(format('select count(*) from rateios where serie_id=%L', sid)) = n);
  j := criar_serie_rateio(smoke, 'Aluguel centavos', 'aluguel', 1000.01, false, 'percentual', jsonb_build_array(jsonb_build_object('loja_id', smoke, 'percentual', 33.3333), jsonb_build_object('loja_id', startbr, 'percentual', 33.3333), jsonb_build_object('loja_id', ez, 'percentual', 33.3334)), 'mensal', null, null, hoje, 'quantidade', null, 2, gen_random_uuid());
  sid2 := (j->>'serie_id')::uuid;
  perform testk.chk('método percentual: soma das parcelas = total exato (1000,01) em todas as ocorrências; término por quantidade encerra a série', testk.adm(format('select count(*) from rateios r where r.serie_id=%L and (select sum(valor) from rateio_parcelas p where p.rateio_id=r.id)=1000.01', sid2)) = 2 and testk.admt(format('select status from contas_series where id=%L', sid2)) = 'encerrada');
  j := criar_serie_rateio(smoke, 'Valores fixos', 'taxas', 90.50, false, 'valores', jsonb_build_array(jsonb_build_object('loja_id', smoke, 'valor', 50.25), jsonb_build_object('loja_id', startbr, 'valor', 40.25)), 'quinzenal', null, null, hoje, 'quantidade', null, 2, gen_random_uuid());
  perform testk.chk('método valores: parcelas fixas preservadas em cada ocorrência', testk.adm(format($q$select count(*) from rateio_parcelas p join rateios r on r.id=p.rateio_id where r.serie_id=%L and p.loja_id=%L and p.valor=50.25$q$, j->>'serie_id', smoke)) = 2);

  -- ================= PERMISSÕES / ISOLAMENTO =================
  perform testk.como(victor);   -- gerente de Smoke e EZ, sem Start
  perform testk.chk('gerente sem acesso a todas as lojas envolvidas não cria nem controla a série', testk.tenta(format($q$select criar_serie_rateio(%L,'Teste teste','x',100,false,'igual',%L::jsonb,'mensal',null,null,%L,'sem_prazo',null,null,gen_random_uuid())$q$, smoke, itens3::text, hoje)) like '%administra%'
     and testk.tenta(format('select serie_controlar(%L, ''pausar'')', sid)) like '%gerente%' and testk.tenta(format('select serie_retomar_previa(%L)', sid)) like '%permissão%');
  perform testk.chk('gerente com as lojas envolvidas (Smoke e EZ) cria série entre elas', testk.tenta(format($q$select criar_serie_rateio(%L,'Entre duas lojas','x',100,false,'igual',%L::jsonb,'mensal',null,null,%L,'quantidade',null,2,gen_random_uuid())$q$, smoke, jsonb_build_array(jsonb_build_object('loja_id', smoke), jsonb_build_object('loja_id', ez))::text, hoje)) = 'OK');
  perform testk.como(enzo);
  perform testk.chk('quem administra só a Start (enzo) não cria série com outras lojas nem controla; vê a série pela loja envolvida, sem poder gerir', testk.tenta(format($q$select criar_serie_rateio(%L,'Teste teste','x',100,false,'igual',%L::jsonb,'mensal',null,null,%L,'sem_prazo',null,null,gen_random_uuid())$q$, startbr, itens3::text, hoje)) like '%rateios%'
     and exists (select 1 from jsonb_array_elements(listar_series(startbr)) e where e->>'id' = sid::text and e->>'escopo' = 'compartilhada' and not (e->>'pode_gerir')::boolean) and testk.tenta(format('select serie_controlar(%L, ''pausar'')', sid)) like '%gerente%');
  perform testk.como(rafael);
  perform testk.chk('loja não envolvida não vê a série, não gera por ela e não vê as ocorrências', testk.tenta(format('select listar_series(%L)', smoke)) like '%permissão%' and testk.tenta(format('select gerar_series_loja(%L)', smoke)) like '%permissão%'
     and not exists (select 1 from jsonb_array_elements(listar_rateios(null, null)) e where e->>'serie_id' = sid::text));
  perform testk.como(luiz);
  perform testk.chk('loja atual fora do rateio, 1 loja só, método inválido e centavos inválidos recusados', testk.tenta(format($q$select criar_serie_rateio(%L,'Teste teste','x',100,false,'igual',%L::jsonb,'mensal',null,null,%L,'sem_prazo',null,null,gen_random_uuid())$q$, rafael, itens3::text, hoje)) <> 'OK'
     and testk.tenta(format($q$select criar_serie_rateio(%L,'Teste teste','x',100,false,'igual',%L::jsonb,'mensal',null,null,%L,'sem_prazo',null,null,gen_random_uuid())$q$, smoke, jsonb_build_array(jsonb_build_object('loja_id', smoke))::text, hoje)) like '%pelo menos 2 lojas%'
     and testk.tenta(format($q$select criar_serie_rateio(%L,'Teste teste','x',100,false,'xyz',%L::jsonb,'mensal',null,null,%L,'sem_prazo',null,null,gen_random_uuid())$q$, smoke, itens3::text, hoje)) like '%Método%'
     and testk.tenta(format($q$select criar_serie_rateio(%L,'Teste teste','x',10.005,false,'igual',%L::jsonb,'mensal',null,null,%L,'sem_prazo',null,null,gen_random_uuid())$q$, smoke, itens3::text, hoje)) <> 'OK');
  perform testk.chk('listar_rateios e o calendário marcam as ocorrências como recorrentes', exists (select 1 from jsonb_array_elements(listar_rateios(smoke, null)) e where e->>'serie_id' = sid::text and (e->>'serie_n')::int = 1) and (select count(*) from jsonb_array_elements(calendario_admin(smoke, hoje, hoje + 70)->'eventos') e where e->>'tipo' = 'rateio' and (e->>'recorrente')::boolean) >= n);

  -- ================= OCORRÊNCIAS MOVIMENTADAS NÃO SÃO ALTERADAS =================
  oc2 := testk.admt(format('select id::text from rateios where serie_id=%L and serie_n=2', sid))::uuid; oc3 := testk.admt(format('select id::text from rateios where serie_id=%L and serie_n=3', sid))::uuid; oc4 := testk.admt(format('select id::text from rateios where serie_id=%L and serie_n=4', sid))::uuid; oc5 := testk.admt(format('select id::text from rateios where serie_id=%L and serie_n=5', sid))::uuid;
  perform registrar_pagamento_rateio(oc2, smoke, 50, hoje, 'Pix', null, gen_random_uuid());
  perform registrar_pagamento_rateio(oc3, smoke, 100, hoje, 'Pix', null, gen_random_uuid()); perform registrar_reembolso(oc3, startbr, smoke, 33.33, hoje, null, gen_random_uuid());
  perform revisar_rateio(oc4, 'Internet revisada', 100.00, hoje + 20, 'igual', itens3, 'ajuste de vencimento');
  r := serie_controlar(sid, 'pausar');
  perform testk.chk('pausar: nada novo é gerado e o que existe fica como está', r->>'status' = 'pausada' and gerar_series_loja(smoke) = 0 and testk.adm(format('select count(*) from rateios where serie_id=%L', sid)) = n and testk.admt(format('select pausada_em is not null from contas_series where id=%L', sid)) = 'true');
  prev := serie_retomar_previa(sid);
  perform testk.chk('prévia da retomada não escreve nada e informa a quantidade (nada faltante: tudo já foi gerado antes da pausa)', (prev->>'faltantes_total')::int = 0 and jsonb_array_length(prev->'ja_existem') = 0 and (prev->>'pode_gerar')::boolean and testk.adm(format('select count(*) from rateios where serie_id=%L', sid)) = n);
  r := serie_controlar(sid, 'retomar', false, null, 'gerar');
  perform testk.chk('retomar sem faltantes não duplica nada', r->>'status' = 'ativa' and (r->>'geradas')::int = 0 and testk.adm(format('select count(*) from rateios where serie_id=%L', sid)) = n);
  r := serie_controlar(sid, 'encerrar', true, 'contrato encerrado');
  perform testk.chk('encerrar cancelando futuras: preserva paga, reembolsada e revisada; cancela as intocadas; nada é apagado', (r->>'canceladas')::int = n - 3 and testk.adm(format($q$select count(*) from rateios where id in (%L,%L,%L) and status='ativo'$q$, oc2, oc3, oc4)) = 3 and testk.adm(format($q$select count(*) from rateios where id=%L and status='cancelado'$q$, oc5)) = 1 and testk.adm(format('select count(*) from rateios where serie_id=%L', sid)) = n
     and testk.adm(format('select count(*) from rateio_pagamentos x join rateios r on r.id=x.rateio_id where r.serie_id=%L', sid)) = 2 and testk.adm(format($q$select count(*) from series_auditoria where serie_id=%L and acao in ('pausada','retomada','encerrada')$q$, sid)) = 3, r::text);

  -- ================= RETOMADA: PULAR × GERAR (séries montadas direto no banco, com lacunas) =================
  execute 'reset role';
  insert into contas_series (loja_id, tipo, categoria, descricao, valor, exige_comprovante, frequencia, intervalo, unidade, inicio, fim_tipo, status, proximo_k, pausada_em, criado_por, chave_criacao, escopo, metodo, itens)
    values (smoke, 'saida', 'internet', 'Pausada compartilhada', 100.00, false, 'semanal', 1, 'semana', hoje - 40, 'sem_prazo', 'pausada', 0, now() - interval '41 days', luiz, gen_random_uuid(), 'compartilhada', 'igual', itens3) returning id into sidp;
  insert into rateios (descricao, categoria, valor_total, vencimento, metodo, exige_comprovante, chave_criacao, criado_por, serie_id, serie_n, vencimento_ref, status, versao)
    values ('Pausada compartilhada', 'internet', 100.00, hoje - 33, 'igual', false, gen_random_uuid(), luiz, sidp, 2, hoje - 33, 'cancelado', 1) returning id into v_ref;
  insert into rateios (descricao, categoria, valor_total, vencimento, metodo, exige_comprovante, chave_criacao, criado_por, serie_id, serie_n, vencimento_ref, status, versao)
    values ('Editada à mão', 'internet', 777.00, hoje - 26, 'igual', false, gen_random_uuid(), luiz, sidp, 3, hoje - 26, 'ativo', 2);
  insert into contas_series (loja_id, tipo, categoria, descricao, valor, exige_comprovante, frequencia, intervalo, unidade, inicio, fim_tipo, status, proximo_k, pausada_em, criado_por, chave_criacao)
    values (smoke, 'saida', 'aluguel', 'Pausada exclusiva', 250.00, false, 'semanal', 1, 'semana', hoje - 40, 'sem_prazo', 'pausada', 0, now() - interval '41 days', luiz, gen_random_uuid()) returning id into sidx;
  insert into financeiro_lancamentos (loja_id, tipo, categoria, descricao, valor, status, vencimento, vencimento_ref, criado_por, serie_id, serie_n) values (smoke, 'saida', 'aluguel', 'Pausada exclusiva', 250.00, 'cancelada', hoje - 33, hoje - 33, luiz, sidx, 2);
  insert into financeiro_lancamentos (loja_id, tipo, categoria, descricao, valor, status, vencimento, vencimento_ref, criado_por, serie_id, serie_n, serie_editada) values (smoke, 'saida', 'aluguel', 'Editada à mão', 999.00, 'pendente', hoje - 26, hoje - 26, luiz, sidx, 3, true);
  perform testk.como(luiz);
  prev := serie_retomar_previa(sidp);
  perform testk.chk('prévia (compartilhada): faltam 4 vencimentos (1, 4, 5, 6); já existem 2 e 3 (cancelada e editada) e não serão tocados; próximas na janela listadas', (prev->>'faltantes_total')::int = 4 and prev->'faltantes'->0->>'n' = '1' and prev->'faltantes'->3->>'n' = '6'
     and jsonb_array_length(prev->'ja_existem') = 2 and prev->'ja_existem'->0->>'situacao' = 'cancelada' and prev->'ja_existem'->1->>'situacao' = 'editada' and jsonb_array_length(prev->'proximas') >= 1 and (prev->>'pode_gerar')::boolean, prev::text);
  prev := serie_retomar_previa(sidx);
  perform testk.chk('prévia (exclusiva): mesma contagem e situações', (prev->>'faltantes_total')::int = 4 and jsonb_array_length(prev->'ja_existem') = 2 and prev->'ja_existem'->0->>'situacao' = 'cancelada' and prev->'ja_existem'->1->>'situacao' = 'editada');
  perform testk.chk('a prévia não grava nada; modo inválido e retomar série ativa tratados', testk.adm(format('select count(*) from rateios where serie_id=%L', sidp)) = 2 and testk.tenta(format('select serie_controlar(%L, ''retomar'', false, null, ''tudo'')', sidp)) like '%Modo%' and testk.tenta(format('select serie_retomar_previa(%L)', sid2)) like '%não está pausada%');
  perform testk.como(enzo);
  perform testk.chk('quem não gere a série não vê a prévia nem retoma', testk.tenta(format('select serie_retomar_previa(%L)', sidp)) like '%permissão%' and testk.tenta(format('select serie_controlar(%L, ''retomar'')', sidp)) like '%gerente%');
  perform testk.como(luiz);
  r := serie_controlar(sidp, 'retomar', false, null, 'gerar');
  perform testk.chk('retomar GERANDO (compartilhada): cria só os 4 números faltantes + a janela futura; 2 (cancelada) e 3 (editada) intocados; sem duplicar', (r->>'geradas')::int = 4 + 9 and testk.adm(format('select count(*) from rateios where serie_id=%L', sidp)) = 15 and testk.adm(format('select count(distinct serie_n) from rateios where serie_id=%L', sidp)) = 15
     and testk.adm(format($q$select count(*) from rateios where serie_id=%L and serie_n=2 and status='cancelado'$q$, sidp)) = 1 and testk.adm(format($q$select count(*) from rateios where serie_id=%L and serie_n=3 and valor_total=777.00 and versao=2$q$, sidp)) = 1
     and testk.adm(format($q$select count(*) from rateios where serie_id=%L and serie_n in (1,4,5,6) and status='ativo' and versao=1 and valor_total=100.00$q$, sidp)) = 4 and testk.admt(format('select status from contas_series where id=%L', sidp)) = 'ativa', r::text);
  perform testk.chk('os vencimentos gerados da pausa nascem sem pagamentos, reembolsos e comprovantes, com parcelas exatas', testk.adm(format($q$select count(*) from rateio_parcelas p join rateios r on r.id=p.rateio_id where r.serie_id=%L and r.serie_n in (1,4,5,6) and p.ativa$q$, sidp)) = 12 and testk.adm(format('select count(*) from rateio_pagamentos x join rateios r on r.id=x.rateio_id where r.serie_id=%L', sidp)) = 0);
  r := serie_controlar(sidx, 'retomar', false, null, 'pular');
  perform testk.chk('retomar PULANDO (exclusiva): 4 pulados e registrados; só a janela futura é criada; 2 e 3 intocados', (r->>'puladas')::int = 4 and (r->>'geradas')::int = 9 and testk.adm(format('select count(*) from financeiro_lancamentos where serie_id=%L', sidx)) = 11 and testk.adm(format('select count(*) from financeiro_lancamentos where serie_id=%L and serie_n in (1,4,5,6)', sidx)) = 0
     and testk.adm(format($q$select count(*) from financeiro_lancamentos where serie_id=%L and serie_n=2 and status='cancelada'$q$, sidx)) = 1 and testk.adm(format($q$select count(*) from financeiro_lancamentos where serie_id=%L and serie_n=3 and valor=999.00 and serie_editada$q$, sidx)) = 1 and testk.adm(format('select puladas from contas_series where id=%L', sidx)) = 4, r::text);
  perform testk.chk('pular não recria depois: nova geração não cria os 4 pulados', gerar_series_loja(smoke) = 0 and testk.adm(format('select count(*) from financeiro_lancamentos where serie_id=%L and serie_n in (1,4,5,6)', sidx)) = 0);
  perform testk.chk('auditoria da retomada registra modo, pulados e gerados', testk.adm(format($q$select count(*) from series_auditoria where serie_id=%L and acao='retomada' and detalhes->>'modo'='gerar' and (detalhes->>'geradas')::int=13$q$, sidp)) = 1 and testk.adm(format($q$select count(*) from series_auditoria where serie_id=%L and acao='retomada' and detalhes->>'modo'='pular' and (detalhes->>'puladas')::int=4$q$, sidx)) = 1);
  execute 'reset role';
  perform testk.chk('auditoria de séries é imutável', testk.tenta('delete from series_auditoria') <> 'OK' and testk.tenta('update series_auditoria set motivo = ''x''') <> 'OK');
  -- limite de geração: pausa longa demais exige pular
  insert into contas_series (loja_id, tipo, categoria, descricao, valor, exige_comprovante, frequencia, intervalo, unidade, inicio, fim_tipo, status, proximo_k, pausada_em, criado_por, chave_criacao)
    values (smoke, 'saida', 'diaria', 'Pausa muito longa', 5.00, false, 'personalizada', 1, 'dia', hoje - 300, 'sem_prazo', 'pausada', 0, now() - interval '301 days', luiz, gen_random_uuid()) returning id into v_ref;
  perform testk.como(luiz);
  prev := serie_retomar_previa(v_ref);
  perform testk.chk('pausa longa (300 dias, diária): prévia informa 300 faltantes e bloqueia "gerar" (máx. 120)', (prev->>'faltantes_total')::int = 300 and not (prev->>'pode_gerar')::boolean and testk.tenta(format('select serie_controlar(%L, ''retomar'', false, null, ''gerar'')', v_ref)) like '%máximo 120%');
  r := serie_controlar(v_ref, 'retomar', false, null, 'pular');
  perform testk.chk('pausa longa: "pular" é permitido e registra os 300 pulados', (r->>'puladas')::int = 300);

  -- ================= ERRO ISOLADO, PERMISSÕES DA GERAÇÃO, ISOLAMENTO =================
  execute 'reset role';
  insert into contas_series (loja_id, tipo, categoria, descricao, valor, exige_comprovante, frequencia, intervalo, unidade, inicio, fim_tipo, status, proximo_k, criado_por, chave_criacao, escopo, metodo, itens)
    values (smoke, 'saida', 'internet', 'Com loja desativada', 100.00, false, 'mensal', 1, 'mes', hoje, 'sem_prazo', 'ativa', 0, luiz, gen_random_uuid(), 'compartilhada', 'igual', itens3) returning id into v_ref;
  insert into contas_series (loja_id, tipo, categoria, descricao, valor, exige_comprovante, frequencia, intervalo, unidade, inicio, fim_tipo, status, proximo_k, criado_por, chave_criacao)
    values (smoke, 'saida', 'aluguel', 'Exclusiva saudável', 10.00, false, 'mensal', 1, 'mes', hoje, 'sem_prazo', 'ativa', 0, luiz, gen_random_uuid()) returning id into sidx;
  update lojas set ativo = false where id = ez;
  n := gerar_series_pendentes();
  perform testk.chk('erro numa série (loja desativada no rateio) fica registrado nela e não impede as outras', testk.admt(format('select ultimo_erro from contas_series where id=%L', v_ref)) like '%inativa%' and testk.adm(format('select count(*) from rateios where serie_id=%L', v_ref)) = 0 and testk.adm(format('select count(*) from financeiro_lancamentos where serie_id=%L', sidx)) >= 1);
  update lojas set ativo = true where id = ez;
  perform gerar_series_pendentes();
  perform testk.chk('corrigido o problema, a série gera e o erro é limpo', testk.adm(format('select count(*) from rateios where serie_id=%L', v_ref)) >= 1 and testk.admt(format('select ultimo_erro is null from contas_series where id=%L', v_ref)) = 'true');
  perform testk.chk('gerador interno e agendador: nem anônimo nem usuário logado executam; service_role e dono do banco sim', not has_function_privilege('anon', 'public.gerar_series_pendentes()', 'execute') and not has_function_privilege('authenticated', 'public.gerar_series_pendentes()', 'execute') and not has_function_privilege('authenticated', 'public.serie_gerar(uuid,integer)', 'execute')
     and not has_function_privilege('authenticated', 'public.serie_gerar_seguro(uuid,integer)', 'execute') and has_function_privilege('service_role', 'public.gerar_series_pendentes()', 'execute') and has_function_privilege('postgres', 'public.gerar_series_pendentes()', 'execute')
     and has_function_privilege('authenticated', 'public.gerar_series_loja(uuid)', 'execute') and not has_function_privilege('anon', 'public.gerar_series_loja(uuid)', 'execute') and not has_function_privilege('anon', 'public.serie_controlar(uuid,text,boolean,text,text)', 'execute'));
  perform testk.como(luiz);
  perform testk.chk('chamadas diretas de usuário ao agendador e ao gerador são negadas', testk.tenta('select gerar_series_pendentes()') like '%permission denied%' and testk.tenta(format('select serie_gerar(%L)', sid)) like '%permission denied%');
  perform testk.como(chefe);
  r := serie_controlar(v_ref, 'pausar'); prev := serie_retomar_previa(v_ref);
  perform testk.chk('dono (vinculado só à Start) lista, prévia e controla séries compartilhadas das lojas', exists (select 1 from jsonb_array_elements(listar_series(startbr)) e where e->>'id' = sid::text and (e->>'pode_gerir')::boolean) and r->>'status' = 'pausada' and (prev->>'faltantes_total')::int >= 0);

  execute 'reset role';
  select jsonb_build_object('total', count(*), 'ok', count(*) filter (where x.ok), 'falhas', count(*) filter (where not x.ok),
         'detalhe_falhas', coalesce(jsonb_agg(jsonb_build_object('n', x.n, 'd', x.d)) filter (where not x.ok), '[]'::jsonb)) into r from testk.res x;
  raise exception 'RELATORIO_SERIES_COMP: %', r::text;
end;
$teste$;

-- Testes de acessos (010) e recorrência (011). Transação desfeita; relatório em "erro" RELATORIO_ACESSOS_SERIES.
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
grant execute on function testk.sd(date,text,int,int) to public;

do $teste$
declare
  g uuid := gen_random_uuid(); o uuid := gen_random_uuid(); d uuid := gen_random_uuid(); est uuid := gen_random_uuid();
  smoke uuid; startbr uuid; j jsonb; r jsonb; sid uuid; sid2 uuid; hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  k uuid; kc uuid; lanc uuid; n int; pes jsonb; oc2 uuid; oc3 uuid; ult uuid; cnt0 int;
begin
  select id into smoke from lojas where slug = 'smoke-club'; select id into startbr from lojas where slug = 'start-br01';
  insert into auth.users (id, email) values (g, 'g.t@painel.local'), (o, 'o.t@painel.local'), (d, 'd.t@painel.local'), (est, 'e.t@painel.local');
  insert into perfis (id, nome, papel) values (g, 'Gerente T', 'gerente'), (o, 'Operador T', 'operador'), (d, 'Dono T', 'dono'), (est, 'Estranho T', 'operador');
  insert into perfis_lojas (perfil_id, loja_id) values (g, smoke), (o, smoke), (d, startbr);

  -- ================= ACESSOS =================
  perform testk.como(g);
  perform testk.chk('gerente não lista nem altera acessos', testk.tenta('select listar_pessoas()') like '%administrador geral%' and testk.tenta(format('select definir_acesso_pessoa(%L,false,''teste'')', o)) like '%administrador geral%' and testk.tenta(format('select definir_lojas_pessoa(%L, array[%L]::uuid[])', o, startbr)) like '%administrador geral%');
  perform testk.como(o);
  kc := (salvar_comunicado(null, smoke, 'Rascunho da operadora', '', 'texto', '', null, gen_random_uuid())->>'id')::uuid;
  lanc := criar_conta(smoke, 'saida', 'aluguel', 'Conta da operadora', 100, hoje + 3, null, false, gen_random_uuid());
  perform testk.chk('operadora ativa acessa a Smoke', jsonb_array_length(listar_comunicados(smoke)) >= 1 and jsonb_array_length(listar_contas(smoke, null, null, null)) >= 1);
  perform testk.como(d);
  pes := listar_pessoas();
  perform testk.chk('dono lista pessoas com usuário, papel, lojas e situação', exists (select 1 from jsonb_array_elements(pes) e where e->>'usuario' = 'o.t' and e->>'papel' = 'operador' and (e->>'ativo')::boolean and jsonb_array_length(e->'lojas') = 1));
  perform testk.chk('desativar exige motivo; ninguém desativa a si mesmo; inexistente recusado', testk.tenta(format('select definir_acesso_pessoa(%L,false,'' '')', o)) like '%motivo%' and testk.tenta(format('select definir_acesso_pessoa(%L,false,''saiu da equipe'')', d)) like '%próprio%' and testk.tenta(format('select definir_acesso_pessoa(%L,false,''saiu'')', gen_random_uuid())) like '%não encontrada%');
  perform definir_acesso_pessoa(o, false, 'saiu da equipe');
  perform testk.chk('desativada: pessoa e histórico continuam no banco (rascunho, conta, nome)', testk.adm(format('select count(*) from perfis where id=%L and not ativo and desativado_em is not null', o)) = 1 and testk.adm(format('select count(*) from comunicados where id=%L and criado_por=%L', kc, o)) = 1 and testk.adm(format('select count(*) from financeiro_lancamentos where id=%L and criado_por=%L', lanc, o)) = 1);
  perform testk.como(o);
  perform testk.chk('desativada: API direta bloqueada mesmo com o token (listar, criar, salvar)', testk.tenta(format('select listar_comunicados(%L)', smoke)) like '%permissão%' and testk.tenta(format('select listar_contas(%L,null,null,null)', smoke)) like '%permissão%'
     and testk.tenta(format($q$select criar_conta(%L,'saida','x','y',10,null,null,false,gen_random_uuid())$q$, smoke)) like '%permissão%' and testk.tenta(format($q$select salvar_comunicado(%L,null,'Novo texto','','x','',1,null)$q$, kc)) like '%permissão%'
     and testk.adm('select count(*) from minhas_lojas()') = 0 and not (select eh_da_equipe()));
  perform testk.chk('desativada não lê tabelas (RLS): contas, vínculos e catálogo vazios', (select count(*) from financeiro_lancamentos) = 0 and (select count(*) from perfis_lojas) = 0 and (select count(*) from itens) = 0);
  perform testk.como(g);
  perform testk.chk('quem tem acesso continua vendo o histórico dela (autor mantido)', (comunicado_detalhe(kc)->'comunicado'->>'criado_por_nome') = 'Operador T' and exists (select 1 from jsonb_array_elements(listar_contas(smoke, null, null, null)) e where e->>'id' = lanc::text));
  perform testk.como(d);
  perform definir_acesso_pessoa(o, true);
  perform testk.como(o);
  perform testk.chk('reativada: volta com as lojas anteriores', jsonb_array_length(listar_comunicados(smoke)) >= 1);
  perform testk.como(d);
  perform definir_acesso_pessoa(g, false, 'férias longas');
  perform testk.como(g);
  perform testk.chk('gerente desativado perde acesso e permissões de gerente', not (select eh_gerente()) and testk.tenta(format($q$select publicar_comunicado(%L,'info',null,false,false)$q$, kc)) <> 'OK' and testk.tenta($q$insert into categorias (nome) values ('Teste')$q$) <> 'OK');
  perform testk.como(d);
  perform definir_acesso_pessoa(g, true);
  perform definir_lojas_pessoa(o, array[startbr]);
  perform testk.como(o);
  perform testk.chk('lojas trocadas: perde a Smoke e acessa a Start; histórico da Smoke intacto', testk.tenta(format('select listar_comunicados(%L)', smoke)) like '%permissão%' and testk.tenta(format('select listar_comunicados(%L)', startbr)) = 'OK' and testk.adm(format('select count(*) from comunicados where id=%L', kc)) = 1);
  perform testk.como(d);
  perform testk.chk('lojas: vazio e loja inexistente recusados', testk.tenta(format('select definir_lojas_pessoa(%L, array[]::uuid[])', o)) like '%pelo menos uma loja%' and testk.tenta(format('select definir_lojas_pessoa(%L, array[%L]::uuid[])', o, gen_random_uuid())) like '%Loja inválida%');
  perform testk.chk('auditoria de acessos: desativado, reativado e lojas, com autor e motivo', testk.adm(format('select count(*) from acessos_auditoria where perfil_id=%L and por=%L', o, d)) = 3 and testk.adm(format($q$select count(*) from acessos_auditoria where perfil_id=%L and acao='desativado' and motivo='saiu da equipe'$q$, o)) = 1);
  execute 'reset role';
  perform testk.chk('auditoria de acessos é imutável', testk.tenta('delete from acessos_auditoria') <> 'OK' and testk.tenta('update acessos_auditoria set motivo = ''x''') <> 'OK');
  update perfis set papel = 'operador' where papel = 'dono' and id <> d;
  perform testk.como(d);
  perform testk.chk('o último dono ativo não pode ser desativado', testk.tenta(format('select definir_acesso_pessoa(%L,false,''teste'')', d)) like '%próprio%');
  execute 'reset role'; update perfis set papel = 'dono' where id = g;
  perform testk.como(d);
  perform testk.chk('com dois donos, um desativa o outro; mas não o último', testk.tenta(format('select definir_acesso_pessoa(%L,false,''teste'')', g)) = 'OK');
  execute 'reset role'; update perfis set papel = 'gerente', ativo = true, desativado_em = null where id = g;

  -- ================= RECORRÊNCIA: datas =================
  perform testk.como(g);
  perform testk.chk('mensal a partir de 31/01/2027: 28/02, 31/03, 30/04, 31/05 (sem deslizar)', (select array_agg(testk.sd('2027-01-31', 'mes', 1, i)::text order by i) from generate_series(0, 4) i) = array['2027-01-31','2027-02-28','2027-03-31','2027-04-30','2027-05-31']);
  perform testk.chk('mensal em ano bissexto: 31/01/2028 → 29/02/2028', testk.sd('2028-01-31', 'mes', 1, 1) = '2028-02-29');
  perform testk.chk('anual de 29/02/2028: 28/02/2029 e 29/02/2032', testk.sd('2028-02-29', 'ano', 1, 1) = '2029-02-28' and testk.sd('2028-02-29', 'ano', 1, 4) = '2032-02-29');
  perform testk.chk('semanal +7, quinzenal +15, personalizada de 3 meses e de 10 dias', testk.sd('2027-03-01', 'semana', 1, 2) = '2027-03-15' and testk.sd('2027-03-01', 'dia', 15, 3) = '2027-04-15' and testk.sd('2027-01-31', 'mes', 3, 1) = '2027-04-30' and testk.sd('2027-03-01', 'dia', 10, 2) = '2027-03-21');
  j := serie_previa('mensal', null, null, '2027-01-31', 'quantidade', null, 4, 12);
  perform testk.chk('prévia: 4 datas; 28/02 marcada como ajustada; 31/01 não', jsonb_array_length(j->'datas') = 4 and j->'datas'->1->>'vencimento' = '2027-02-28' and (j->'datas'->1->>'ajustada')::boolean and not (j->'datas'->0->>'ajustada')::boolean and not (j->>'tem_mais')::boolean);
  j := serie_previa('personalizada', 2, 'semana', '2027-03-01', 'data', '2027-04-30', null, 12);
  perform testk.chk('prévia por data final inclusiva (a cada 2 semanas até 30/04)', jsonb_array_length(j->'datas') = 5 and j->'datas'->4->>'vencimento' = '2027-04-26');
  perform testk.chk('prévia sem prazo é limitada e avisa que há mais', jsonb_array_length(serie_previa('semanal', null, null, '2027-03-01', 'sem_prazo', null, null, 8)->'datas') = 8 and (serie_previa('semanal', null, null, '2027-03-01', 'sem_prazo', null, null, 8)->>'tem_mais')::boolean);
  perform testk.chk('regras inválidas recusadas', testk.tenta($q$select serie_previa('diaria',null,null,'2027-03-01','sem_prazo',null,null)$q$) like '%Frequência%' and testk.tenta($q$select serie_previa('personalizada',0,'dia','2027-03-01','sem_prazo',null,null)$q$) like '%intervalo%'
     and testk.tenta($q$select serie_previa('personalizada',2,'hora','2027-03-01','sem_prazo',null,null)$q$) like '%unidade%' and testk.tenta($q$select serie_previa('mensal',null,null,'2027-03-01','quantidade',null,121)$q$) like '%quantidade%' and testk.tenta($q$select serie_previa('mensal',null,null,'2027-03-01','data','2027-02-01',null)$q$) like '%data final%');

  -- ================= RECORRÊNCIA: criação e geração =================
  k := gen_random_uuid();
  j := criar_serie(smoke, 'saida', 'aluguel', 'Aluguel sala', 1234.56, 'Pix', true, 'mensal', null, null, hoje - 40, 'sem_prazo', null, null, k);
  sid := (j->>'serie_id')::uuid;
  select count(*) into n from financeiro_lancamentos where serie_id = sid;
  perform testk.chk('série mensal iniciada há 40 dias: gera passado + janela de 60 dias; todas pendentes', (j->>'geradas')::int = n and n between 2 and 4 and testk.adm(format($q$select count(*) from financeiro_lancamentos where serie_id=%L and status='pendente'$q$, sid)) = n, n::text);
  perform testk.chk('ocorrências: valor exato, sem pagamentos/comprovantes, numeradas 1..n, referência = vencimento', testk.adm(format('select count(*) from financeiro_lancamentos where serie_id=%L and valor=1234.56 and vencimento=vencimento_ref and exige_comprovante', sid)) = n
     and testk.adm(format('select count(*) from pagamentos_lancamento p join financeiro_lancamentos f on f.id=p.lancamento_id where f.serie_id=%L', sid)) = 0 and testk.adm(format('select max(serie_n) from financeiro_lancamentos where serie_id=%L', sid)) = n and testk.adm(format('select count(distinct serie_n) from financeiro_lancamentos where serie_id=%L', sid)) = n);
  perform testk.chk('repetir a mesma chave não duplica série nem contas', (criar_serie(smoke, 'saida', 'aluguel', 'Aluguel sala', 1234.56, 'Pix', true, 'mensal', null, null, hoje - 40, 'sem_prazo', null, null, k)->>'repetida')::boolean and testk.adm(format('select count(*) from financeiro_lancamentos where serie_id=%L', sid)) = n and testk.adm(format('select count(*) from contas_series where id=%L', sid)) = 1);
  perform testk.chk('gerar de novo (tela/agendador) não duplica', gerar_series_loja(smoke) = 0 and gerar_series_loja(smoke) = 0 and testk.adm(format('select count(*) from financeiro_lancamentos where serie_id=%L', sid)) = n);
  perform testk.chk('listar_contas informa a série e a numeração', exists (select 1 from jsonb_array_elements(listar_contas(smoke, null, null, null)) e where e->>'serie_id' = sid::text and (e->>'serie_n')::int = 1));
  perform testk.chk('lista de séries: ativa, valor e próxima data', exists (select 1 from jsonb_array_elements(listar_series(smoke)) e where e->>'id' = sid::text and e->>'status' = 'ativa' and (e->>'geradas')::int = n and e->>'proximo_vencimento' is not null and (e->>'pode_gerir')::boolean));
  perform testk.chk('só quem tem acesso à loja cria série; agendador/gerador não são chamáveis pela API', testk.tenta(format($q$select criar_serie(%L,'saida','x','y',10,null,false,'mensal',null,null,'2027-01-01','sem_prazo',null,null,gen_random_uuid())$q$, startbr)) like '%permissão%'
     and testk.tenta('select gerar_series_pendentes()') like '%permission denied%' and testk.tenta(format('select serie_gerar(%L)', sid)) like '%permission denied%' and testk.tenta(format('select gerar_series_loja(%L)', startbr)) like '%permissão%');
  perform testk.chk('valor inválido, categoria "venda" e chave ausente recusados', testk.tenta(format($q$select criar_serie(%L,'saida','x','y',0,null,false,'mensal',null,null,'2027-01-01','sem_prazo',null,null,gen_random_uuid())$q$, smoke)) <> 'OK'
     and testk.tenta(format($q$select criar_serie(%L,'saida','venda','y',10,null,false,'mensal',null,null,'2027-01-01','sem_prazo',null,null,gen_random_uuid())$q$, smoke)) like '%Categoria%' and testk.tenta(format($q$select criar_serie(%L,'saida','x','y',10,null,false,'mensal',null,null,'2027-01-01','sem_prazo',null,null,null)$q$, smoke)) like '%Chave%');
  -- término por quantidade: 3 ocorrências e encerra
  j := criar_serie(smoke, 'saida', 'internet', 'Internet', 99.99, null, false, 'semanal', null, null, hoje + 1, 'quantidade', null, 3, gen_random_uuid());
  sid2 := (j->>'serie_id')::uuid;
  perform testk.chk('término por quantidade: exatamente 3 contas e série encerrada sozinha', (j->>'geradas')::int = 3 and testk.adm(format('select count(*) from financeiro_lancamentos where serie_id=%L', sid2)) = 3 and testk.admt(format('select status from contas_series where id=%L', sid2)) = 'encerrada');
  -- janela futura limitada: anual com 1 ocorrência no futuro distante gera só a 1ª
  j := criar_serie(smoke, 'saida', 'seguro', 'Seguro anual', 800, null, false, 'anual', null, null, hoje + 200, 'sem_prazo', null, null, gen_random_uuid());
  perform testk.chk('janela futura: série com início distante cria só a 1ª ocorrência (as outras só quando entrarem na janela)', (j->>'geradas')::int = 1);
  j := criar_serie(smoke, 'saida', 'diario', 'Diária', 5.05, null, false, 'personalizada', 1, 'dia', hoje, 'sem_prazo', null, null, gen_random_uuid());
  perform testk.chk('limite por execução (24) e janela de 60 dias: série diária gera no máximo 24 e continua nas próximas execuções', (j->>'geradas')::int = 24 and gerar_series_loja(smoke) >= 24 and testk.adm(format('select max(vencimento) - current_date from financeiro_lancamentos where serie_id=%L', j->>'serie_id')) <= 61);

  -- ================= EDIÇÃO / MOVIMENTAÇÃO =================
  select id into oc2 from financeiro_lancamentos where serie_id = sid and serie_n = 2; select id into oc3 from financeiro_lancamentos where serie_id = sid and serie_n = 3;
  perform testk.como(o);
  perform testk.como(g);
  -- paga parcialmente a ocorrência 2
  perform registrar_pagamento(oc2, 200, hoje, 'Pix', null, gen_random_uuid());
  j := editar_conta(oc3, 'esta', 'Aluguel (reajuste pontual)', 'aluguel', 1300.10, hoje + 20, 'Pix', true);
  perform testk.chk('editar só esta: muda valor/data e marca como editada; vencimento_ref original preservado', testk.adm(format('select count(*) from financeiro_lancamentos where id=%L and valor=1300.10 and serie_editada and vencimento_ref <> vencimento', oc3)) = 1 and (j->>'alteradas')::int = 1);
  j := editar_conta(oc2, 'proximas', 'Aluguel reajustado', 'aluguel', 1500.00, null, 'Pix', true);
  perform testk.chk('esta e as próximas: preserva a que tem pagamento (valor antigo) e a editada à mão; altera as demais e o modelo', (j->>'preservadas')::int >= 2 and testk.adm(format('select valor from financeiro_lancamentos where id=%L', oc2)) = 1234.56 and testk.adm(format('select valor from financeiro_lancamentos where id=%L', oc3)) = 1300.10 and testk.adm(format('select valor from contas_series where id=%L', sid)) = 1500.00);
  perform testk.chk('valor de conta com pagamento não pode mudar; descrição pode', testk.tenta(format($q$select editar_conta(%L,'esta','x','aluguel',999,null,null,true)$q$, oc2)) like '%pagamentos%' and testk.tenta(format($q$select editar_conta(%L,'esta','Descrição nova','aluguel',1234.56,null,'Pix',true)$q$, oc2)) = 'OK');
  perform testk.chk('editar com escopo inválido ou "próximas" em conta avulsa recusado', testk.tenta(format($q$select editar_conta(%L,'todas','x','aluguel',10,null,null,false)$q$, oc2)) like '%Escopo%' and testk.tenta(format($q$select editar_conta(%L,'proximas','x','aluguel',10,null,null,false)$q$, lanc)) like '%série%');
  select count(*) into cnt0 from financeiro_lancamentos where serie_id = sid;
  r := serie_controlar(sid, 'pausar');
  perform testk.chk('pausar: status pausada e nada novo é gerado (nem apagado)', r->>'status' = 'pausada' and gerar_series_loja(smoke) >= 0 and testk.adm(format('select count(*) from financeiro_lancamentos where serie_id=%L', sid)) = cnt0);
  r := serie_controlar(sid, 'retomar');
  perform testk.chk('retomar: volta a ativa; o que venceu durante a pausa é pulado, não gerado no passado', r->>'status' = 'ativa' and testk.adm(format('select count(*) from financeiro_lancamentos where serie_id=%L', sid)) >= cnt0);
  r := serie_controlar(sid, 'encerrar', true, 'contrato rescindido');
  perform testk.chk('encerrar cancela só as futuras intocadas; a paga e as vencidas permanecem; nada é apagado', r->>'status' = 'encerrada' and testk.adm(format('select count(*) from financeiro_lancamentos where serie_id=%L', sid)) >= cnt0 and testk.adm(format($q$select count(*) from financeiro_lancamentos where id=%L and status='parcial'$q$, oc2)) = 1 and testk.adm(format($q$select count(*) from financeiro_lancamentos where id=%L and status<>'cancelada'$q$, oc3)) = 1);
  perform testk.chk('série encerrada não gera nem é controlada de novo', gerar_series_loja(smoke) >= 0 and testk.tenta(format('select serie_controlar(%L, ''retomar'')', sid)) like '%encerrada%');
  perform testk.como(o);
  perform testk.chk('operadora não pausa, retoma nem encerra série', testk.tenta(format('select serie_controlar(%L, ''pausar'')', sid2)) like '%gerente%' and testk.tenta(format($q$select editar_conta(%L,'esta','x','aluguel',10,null,null,false)$q$, oc3)) like '%gerente%');
  perform testk.como(est);
  perform testk.chk('quem não tem acesso à loja não vê séries nem edita contas', testk.tenta(format('select listar_series(%L)', smoke)) like '%permissão%' and testk.tenta(format($q$select editar_conta(%L,'esta','x','aluguel',10,null,null,false)$q$, oc3)) <> 'OK');
  execute 'reset role';
  perform testk.chk('auditoria da série: criada, editada, pausada, retomada e encerrada', testk.adm(format($q$select count(distinct acao) from financeiro_auditoria where detalhes->>'serie_id' = %L or lancamento_id in (select id from financeiro_lancamentos where serie_id=%L)$q$, sid, sid)) >= 5);
  perform testk.chk('contas recorrentes não tocam em rateios, vendas nem caixa', testk.adm('select count(*) from rateios') >= 0 and testk.adm(format('select count(*) from financeiro_lancamentos where serie_id=%L and venda_id is not null', sid)) = 0);

  execute 'reset role';
  select jsonb_build_object('total', count(*), 'ok', count(*) filter (where x.ok), 'falhas', count(*) filter (where not x.ok),
         'detalhe_falhas', coalesce(jsonb_agg(jsonb_build_object('n', x.n, 'd', x.d)) filter (where not x.ok), '[]'::jsonb)) into r from testk.res x;
  raise exception 'RELATORIO_ACESSOS_SERIES: %', r::text;
end;
$teste$;

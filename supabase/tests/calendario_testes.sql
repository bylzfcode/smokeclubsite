-- Testes do calendário administrativo (012). Transação desfeita; relatório em "erro" RELATORIO_CALENDARIO.
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
  cp uuid; cv uuid; cq uuid; cc uuid; cs uuid; rid uuid; j jsonb; ev jsonb; comp uuid; k uuid := gen_random_uuid(); n0 int; n1 int; sid uuid; r jsonb;
begin
  select id into luiz from auth.users where email = 'luiz@painel.local'; select id into victor from auth.users where email = 'victor@painel.local';
  select id into enzo from auth.users where email = 'enzo@painel.local'; select id into rafael from auth.users where email = 'rafael@painel.local';
  select id into smoke from lojas where slug = 'smoke-club'; select id into startbr from lojas where slug = 'start-br01'; select id into ez from lojas where slug = 'ez-store';
  insert into auth.users (id, email) values (chefe, 'chefe.cal@painel.local'); insert into perfis (id, nome, papel) values (chefe, 'Chefe Cal', 'dono'); insert into perfis_lojas (perfil_id, loja_id) values (chefe, startbr);

  perform testk.como(luiz);
  -- contas exclusivas da Smoke em quatro situações
  cp := criar_conta(smoke, 'saida', 'aluguel', 'CAL pendente', 100, hoje + 3, null, false, gen_random_uuid());
  cv := criar_conta(smoke, 'saida', 'luz', 'CAL vencida', 250.50, hoje - 5, null, false, gen_random_uuid());
  cq := criar_conta(smoke, 'saida', 'agua', 'CAL quitada', 80, hoje + 1, null, false, gen_random_uuid()); perform registrar_pagamento(cq, 80, hoje, 'Pix', null, gen_random_uuid());
  cc := criar_conta(smoke, 'saida', 'outro', 'CAL cancelada', 60, hoje + 2, null, false, gen_random_uuid()); perform cancelar_conta(cc, 'duplicada por engano');
  cs := criar_conta(smoke, 'entrada', 'servico', 'CAL parcial', 400, hoje + 4, null, false, gen_random_uuid()); perform registrar_pagamento(cs, 150, hoje, 'Pix', null, gen_random_uuid());
  rid := criar_rateio('CAL rateio internet', 'internet', 900, hoje + 6, false, 'igual', jsonb_build_array(jsonb_build_object('loja_id', smoke), jsonb_build_object('loja_id', startbr), jsonb_build_object('loja_id', ez)), gen_random_uuid());
  n0 := testk.adm('select (select count(*) from financeiro_lancamentos) + (select count(*) from rateios)');
  j := calendario_admin(smoke, hoje - 10, hoje + 10); ev := j->'eventos';
  perform testk.chk('calendário traz as contas da loja nas 4 situações, sem duplicar', (select count(*) from jsonb_array_elements(ev) e where e->>'titulo' like 'CAL %' and e->>'tipo' = 'conta') = 5
     and (select e->>'situacao' from jsonb_array_elements(ev) e where e->>'id' = cp::text) = 'pendente' and (select e->>'situacao' from jsonb_array_elements(ev) e where e->>'id' = cv::text) = 'vencido'
     and (select e->>'situacao' from jsonb_array_elements(ev) e where e->>'id' = cq::text) = 'quitado' and (select e->>'situacao' from jsonb_array_elements(ev) e where e->>'id' = cc::text) = 'cancelado');
  perform testk.chk('pagamento parcial segue pendente com saldo e marca "parcial"; entrada/saída distinguidas', (select (e->>'saldo')::numeric = 250 and (e->>'parcial')::boolean and e->>'situacao' = 'pendente' and e->>'sentido' = 'entrada' from jsonb_array_elements(ev) e where e->>'id' = cs::text)
     and (select (e->>'saldo')::numeric = 250.50 from jsonb_array_elements(ev) e where e->>'id' = cv::text) and (select (e->>'saldo')::numeric = 0 from jsonb_array_elements(ev) e where e->>'id' = cc::text));
  perform testk.chk('rateio aparece UMA vez, com valor total e saldo externo, apontando para o rateio existente', (select count(*) from jsonb_array_elements(ev) e where e->>'tipo' = 'rateio' and e->>'id' = rid::text) = 1 and (select (e->>'valor')::numeric = 900 and (e->>'saldo')::numeric = 900 and e->>'situacao' = 'pendente' from jsonb_array_elements(ev) e where e->>'id' = rid::text));
  perform testk.chk('consultar o calendário não cria nem altera registros', testk.adm('select (select count(*) from financeiro_lancamentos) + (select count(*) from rateios)') = n0);
  perform testk.chk('eventos ordenados por data e dentro do período', (select bool_and((e->>'data')::date between hoje - 10 and hoje + 10) from jsonb_array_elements(ev) e) and (select array_agg(e->>'data' order by ord) = array_agg(e->>'data' order by e->>'data') from jsonb_array_elements(ev) with ordinality t(e, ord)));
  -- rateio pago por completo vira quitado
  perform registrar_pagamento_rateio(rid, smoke, 900, hoje, 'Pix', null, gen_random_uuid());
  perform testk.chk('rateio quitado no pagamento externo integral', (select e->>'situacao' = 'quitado' and (e->>'saldo')::numeric = 0 from jsonb_array_elements(calendario_admin(smoke, hoje, hoje + 10)->'eventos') e where e->>'id' = rid::text));
  -- série recorrente aparece com a marca
  sid := (criar_serie(smoke, 'saida', 'aluguel', 'CAL recorrente', 700, null, false, 'semanal', null, null, hoje + 1, 'quantidade', null, 3, gen_random_uuid())->>'serie_id')::uuid;
  perform testk.chk('ocorrências de série aparecem marcadas como recorrentes', (select count(*) from jsonb_array_elements(calendario_admin(smoke, hoje, hoje + 30)->'eventos') e where e->>'titulo' = 'CAL recorrente' and (e->>'recorrente')::boolean) = 3);

  -- ================= COMPROMISSOS =================
  j := salvar_compromisso(null, smoke, '  Reunião com contador ', hoje + 2, victor, 'levar notas', null, k); comp := (j->>'id')::uuid;
  perform testk.chk('criar compromisso: título aparado, responsável, autor e histórico', (j->>'versao')::int = 1 and compromisso_detalhe(comp)->>'titulo' = 'Reunião com contador' and compromisso_detalhe(comp)->>'responsavel_nome' = 'Victor' and compromisso_detalhe(comp)->>'criado_por_nome' = 'Luiz'
     and jsonb_array_length(compromisso_detalhe(comp)->'historico') = 1);
  perform testk.chk('repetir a mesma chave não duplica', (salvar_compromisso(null, smoke, 'Reunião com contador', hoje + 2, victor, 'levar notas', null, k)->>'repetida')::boolean and testk.adm(format('select count(*) from compromissos where id=%L', comp)) = 1);
  perform testk.chk('compromisso aparece no calendário com responsável e situação pendente', (select e->>'situacao' = 'pendente' and e->>'responsavel_nome' = 'Victor' and e->>'observacao' = 'levar notas' from jsonb_array_elements(calendario_admin(smoke, hoje, hoje + 10)->'eventos') e where e->>'id' = comp::text));
  j := salvar_compromisso(comp, null, 'Reunião com contador', hoje - 1, victor, 'levar notas', 1, null);
  perform testk.chk('editar: versão 2; passou da data sem concluir = vencido', (j->>'versao')::int = 2 and (select e->>'situacao' = 'vencido' from jsonb_array_elements(calendario_admin(smoke, hoje - 3, hoje + 10)->'eventos') e where e->>'id' = comp::text));
  perform testk.chk('base desatualizada é recusada', testk.tenta(format($q$select salvar_compromisso(%L,null,'Outro título',%L,null,null,1,null)$q$, comp, hoje)) like '%outra pessoa%');
  perform mudar_status_compromisso(comp, 'concluido', 2);
  perform testk.chk('concluir: situação concluído e histórico de 3 versões com autor', (select e->>'situacao' = 'concluido' from jsonb_array_elements(calendario_admin(smoke, hoje - 3, hoje + 10)->'eventos') e where e->>'id' = comp::text) and jsonb_array_length(compromisso_detalhe(comp)->'historico') = 3);
  perform mudar_status_compromisso(comp, 'cancelado', 3);
  perform testk.chk('cancelado não edita sem reabrir; reabrir volta a pendente', testk.tenta(format($q$select salvar_compromisso(%L,null,'Título novo',%L,null,null,4,null)$q$, comp, hoje)) like '%reabra%' and (mudar_status_compromisso(comp, 'pendente', 4)->>'versao')::int = 5);
  perform testk.chk('responsável sem acesso à loja ou inexistente recusado', testk.tenta(format($q$select salvar_compromisso(null,%L,'Teste responsável',%L,%L,null,null,gen_random_uuid())$q$, smoke, hoje, rafael)) like '%responsável%' and testk.tenta(format($q$select salvar_compromisso(null,%L,'Teste responsável',%L,%L,null,null,gen_random_uuid())$q$, smoke, hoje, gen_random_uuid())) like '%responsável%');
  perform testk.chk('título curto, observação > 1000 e data ausente recusados', testk.tenta(format($q$select salvar_compromisso(null,%L,'ab',%L,null,null,null,gen_random_uuid())$q$, smoke, hoje)) like '%título%' and testk.tenta(format($q$select salvar_compromisso(null,%L,'Título ok',%L,null,%L,null,gen_random_uuid())$q$, smoke, hoje, repeat('x', 1001))) like '%observação%' and testk.tenta(format($q$select salvar_compromisso(null,%L,'Título ok',null,null,null,null,gen_random_uuid())$q$, smoke)) like '%data%');

  -- ================= PERMISSÕES / ISOLAMENTO =================
  perform testk.como(enzo);   -- operador só da Start
  perform testk.chk('operador da Start não vê contas, rateio parcela-só-Smoke nem compromisso da Smoke; não consulta a Smoke', testk.tenta(format('select calendario_admin(%L,null,null)', smoke)) like '%permissão%' and testk.tenta(format('select compromisso_detalhe(%L)', comp)) like '%sem permissão%'
     and not exists (select 1 from jsonb_array_elements(calendario_admin(null, hoje - 20, hoje + 30)->'eventos') e where e->>'titulo' like 'CAL %' and e->>'tipo' <> 'rateio') and not exists (select 1 from jsonb_array_elements(calendario_admin(null, hoje - 20, hoje + 30)->'eventos') e where e->>'id' = comp::text));
  perform testk.chk('operador da Start vê o rateio compartilhado que o inclui, com o saldo, e não edita compromissos da Smoke', exists (select 1 from jsonb_array_elements(calendario_admin(null, hoje, hoje + 30)->'eventos') e where e->>'id' = rid::text)
     and testk.tenta(format($q$select salvar_compromisso(%L,null,'Invasão aqui',%L,null,null,5,null)$q$, comp, hoje)) like '%permissão%' and testk.tenta(format($q$select mudar_status_compromisso(%L,'cancelado',5)$q$, comp)) like '%permissão%');
  perform testk.como(rafael);
  perform testk.chk('gerente de outra loja (Streaks) não vê nada da Smoke', not exists (select 1 from jsonb_array_elements(calendario_admin(null, hoje - 20, hoje + 30)->'eventos') e where e->>'id' in (cp::text, cv::text, rid::text, comp::text)));
  perform testk.como(chefe);
  perform testk.chk('dono (vinculado só à Start) vê todas as lojas no consolidado e filtra por loja', (select count(distinct e->>'loja_nome') from jsonb_array_elements(calendario_admin(null, hoje - 20, hoje + 30)->'eventos') e where e->>'tipo' <> 'rateio') >= 1 and exists (select 1 from jsonb_array_elements(calendario_admin(null, hoje - 20, hoje + 30)->'eventos') e where e->>'id' = cv::text) and exists (select 1 from jsonb_array_elements(calendario_admin(smoke, hoje - 20, hoje + 30)->'eventos') e where e->>'id' = cv::text));
  perform testk.como(luiz);
  perform testk.chk('período inválido e acima de 400 dias recusados', testk.tenta(format('select calendario_admin(%L,%L,%L)', smoke, hoje, hoje - 1)) like '%inválido%' and testk.tenta(format('select calendario_admin(%L,%L,%L)', smoke, hoje, hoje + 401)) like '%400%');
  execute 'reset role'; execute 'set local role anon';
  perform testk.chk('anônimo não acessa nada', testk.tenta('select calendario_admin()') like '%permission denied%' and testk.tenta('select * from compromissos') like '%permission denied%');
  perform testk.como(luiz);
  perform testk.chk('tabelas fechadas para a API; compromisso não é apagado nem alterado direto', testk.tenta('select * from compromissos') like '%permission denied%' and testk.tenta(format('delete from compromissos where id=%L', comp)) like '%permission denied%');
  execute 'reset role'; perform set_config('app.compromisso_op', '', true);
  perform testk.chk('nem o dono do banco altera ou apaga compromisso fora das funções; histórico imutável', testk.tenta(format('update compromissos set titulo = ''x'' where id = %L', comp)) like '%só pode ser alterado%' and testk.tenta('delete from compromissos') like '%não pode ser apagado%' and testk.tenta('delete from compromissos_historico') <> 'OK');
  perform testk.como(luiz);
  execute 'reset role';
  update perfis set ativo = false where id = victor;
  perform testk.como(victor);
  perform testk.chk('pessoa desativada não consulta o calendário', testk.tenta('select calendario_admin()') like '%Sem permissão%');
  perform testk.como(luiz);
  perform testk.chk('responsáveis da loja listam só pessoas ativas com acesso', not exists (select 1 from jsonb_array_elements(responsaveis_loja(smoke)) e where e->>'nome' = 'Victor') and exists (select 1 from jsonb_array_elements(responsaveis_loja(smoke)) e where e->>'nome' = 'Luiz'));

  execute 'reset role';
  select jsonb_build_object('total', count(*), 'ok', count(*) filter (where x.ok), 'falhas', count(*) filter (where not x.ok),
         'detalhe_falhas', coalesce(jsonb_agg(jsonb_build_object('n', x.n, 'd', x.d)) filter (where not x.ok), '[]'::jsonb)) into r from testk.res x;
  raise exception 'RELATORIO_CALENDARIO: %', r::text;
end;
$teste$;

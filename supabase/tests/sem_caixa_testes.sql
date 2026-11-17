-- Testes de entradas_sem_caixa (004). Transação desfeita no final; relatório em "erro" RELATORIO_SEM_CAIXA.
begin;
create schema testk;
create table testk.res (n text, ok boolean, d text);
create function testk.chk(p_n text, p_ok boolean, p_d text default null) returns void language sql as $f$ insert into testk.res values (p_n, coalesce(p_ok, false), p_d) $f$;
create function testk.tenta(p_sql text) returns text language plpgsql as $f$ begin execute p_sql; return 'OK'; exception when others then return sqlerrm; end; $f$;
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
  luiz uuid; enzo uuid; smoke uuid; startbr uuid; item1 uuid; v_cat uuid; j jsonb; r jsonb; s1 uuid; s3 uuid; s5 uuid; sx uuid;
  s2 uuid; s4 uuid; s6 uuid; estranho uuid := gen_random_uuid(); dono uuid := gen_random_uuid(); operador uuid := gen_random_uuid(); hoje date; antes text; depois text; cxa uuid;
begin
  select id into luiz from auth.users where email = 'luiz@painel.local';
  select id into enzo from auth.users where email = 'enzo@painel.local';
  select id into smoke from lojas where slug = 'smoke-club';
  select id into startbr from lojas where slug = 'start-br01';
  hoje := (now() at time zone 'America/Sao_Paulo')::date;
  insert into auth.users (id, email) values (estranho, 'e@x.local'), (dono, 'd@x.local'), (operador, 'o@x.local');
  insert into perfis (id, nome, papel) values (estranho, 'Estranho', 'operador'), (dono, 'Dono', 'dono'), (operador, 'Op', 'operador');
  insert into perfis_lojas (perfil_id, loja_id) values (dono, startbr), (operador, startbr);

  perform testk.como(luiz);
  insert into categorias(nome) values ('CAT SC') returning id into v_cat;
  item1 := criar_item(smoke, 'produto', null, v_cat, 'Item SC', null, null, 100, 1);
  insert into precos_loja(loja_id, item_id, preco) values (smoke, item1, 25), (startbr, item1, 25);
  -- vendas (todas "agora" na transação; depois posicionamos os horários)
  s1 := (registrar_venda(smoke, jsonb_build_array(jsonb_build_object('item_id', item1, 'quantidade', 2)), null, 'Dinheiro', 0, gen_random_uuid())->>'id')::uuid;   -- 50, sem caixa
  s2 := (registrar_venda(smoke, jsonb_build_array(jsonb_build_object('item_id', item1, 'quantidade', 1)), null, 'Dinheiro', 0, gen_random_uuid())->>'id')::uuid; -- S2 dentro do caixa A
  s3 := (registrar_venda(smoke, jsonb_build_array(jsonb_build_object('item_id', item1, 'quantidade', 1)), null, 'Dinheiro', 0, gen_random_uuid())->>'id')::uuid;   -- 25, vão
  s4 := (registrar_venda(smoke, jsonb_build_array(jsonb_build_object('item_id', item1, 'quantidade', 1)), null, 'Pix', 0, gen_random_uuid())->>'id')::uuid;                    -- Pix
  s5 := (registrar_venda(smoke, jsonb_build_array(jsonb_build_object('item_id', item1, 'quantidade', 1)), null, 'Dinheiro', 0, gen_random_uuid())->>'id')::uuid;   -- será cancelada
  s6 := (registrar_venda(smoke, jsonb_build_array(jsonb_build_object('item_id', item1, 'quantidade', 1)), null, 'Dinheiro', 0, gen_random_uuid())->>'id')::uuid;               -- S6 dentro do caixa B (aberto)
  sx := (registrar_venda(startbr, jsonb_build_array(jsonb_build_object('item_id', item1, 'quantidade', 4)), null, 'Dinheiro', 0, gen_random_uuid())->>'id')::uuid;   -- Start BR01: 100, sem caixa
  perform cancelar_venda(s5, 'teste');

  execute 'reset role';
  -- horários: ordem pelo created: [S1,S2,S3,Pix,S5,S6] = -5h,-3.5h,-2h,-2h,-1h,-10min
  update vendas set criado_em = now() - interval '5 hours' where id = s1;
  update vendas set criado_em = now() - interval '3.5 hours' where id = s2;
  update vendas set criado_em = now() - interval '2 hours' where id in (s3, s4);
  update vendas set criado_em = now() - interval '1 hour' where id = s5;
  update vendas set criado_em = now() - interval '10 minutes' where id = s6;
  -- caixa A (fechado, -4h a -3h) e caixa B (aberto desde -30min) inseridos direto (histórico controlado)
  insert into caixas (loja_id, status, saldo_inicial, aberto_por, aberto_em, fechado_por, fechado_em, janela_fim, esperado_dinheiro, valor_conferido, diferenca)
  values (smoke, 'fechado', 10, luiz, now() - interval '4 hours', luiz, now() - interval '3 hours', now() - interval '3 hours', 10, 10, 0) returning id into cxa;
  insert into caixas (loja_id, status, saldo_inicial, aberto_por, aberto_em) values (smoke, 'aberto', 10, luiz, now() - interval '30 minutes');
  select md5(string_agg(x, '|' order by x)) into antes from (select v::text x from vendas v union all select c::text from caixas c union all select m::text from caixa_movimentos m union all select f::text from financeiro_lancamentos f) q;

  perform testk.como(luiz);
  j := entradas_sem_caixa(smoke, hoje - 1, hoje, null);
  perform testk.chk('só as 2 vendas em dinheiro fora de qualquer caixa (50 + 25)', (j->>'total')::numeric = 75 and (j->>'quantidade')::int = 2, j::text);
  perform testk.chk('itens trazem venda, data/hora, valor e responsável', (select bool_and(e->>'venda_id' is not null and e->>'criado_em' is not null and (e->>'valor')::numeric > 0 and e->>'responsavel' = 'Luiz') from jsonb_array_elements(j->'itens') e)
     and (j->'itens'->0->>'venda_id')::uuid = s3 and (j->'itens'->1->>'venda_id')::uuid = s1);
  perform testk.chk('agrupa por dia com total e quantidade', (select sum((e->>'total')::numeric) = 75 and sum((e->>'quantidade')::int) = 2 from jsonb_array_elements(j->'por_dia') e));
  perform testk.chk('NÃO inclui venda dentro de caixa fechado, Pix, cancelada nem venda no caixa aberto', not exists (select 1 from jsonb_array_elements(j->'itens') e where (e->>'valor')::numeric = 25 and (e->>'venda_id')::uuid <> s3));
  perform testk.chk('NÃO inclui venda da outra loja quando filtrado por loja', not exists (select 1 from jsonb_array_elements(j->'itens') e where (e->>'venda_id')::uuid = sx));
  j := entradas_sem_caixa(null, hoje - 1, hoje, null);
  perform testk.chk('sem filtro de loja: soma as lojas liberadas (75 + 100)', (j->>'total')::numeric = 175 and (j->>'quantidade')::int = 3, j::text);
  perform testk.chk('filtro por responsável', (entradas_sem_caixa(smoke, hoje - 1, hoje, luiz)->>'quantidade')::int = 2 and (entradas_sem_caixa(smoke, hoje - 1, hoje, enzo)->>'quantidade')::int = 0);
  perform testk.chk('período fora da data devolve vazio', (entradas_sem_caixa(smoke, hoje - 10, hoje - 5, null)->>'quantidade')::int = 0);
  perform testk.chk('período inválido e > 1 ano recusados', testk.tenta(format('select entradas_sem_caixa(%L, %L, %L)', smoke, hoje, hoje - 1)) like '%Período inválido%' and testk.tenta(format('select entradas_sem_caixa(%L, %L, %L)', smoke, hoje - 400, hoje)) like '%Período máximo%');

  -- permissões
  perform testk.como(enzo);
  perform testk.chk('enzo (Start BR01) não consulta a Smoke', testk.tenta(format('select entradas_sem_caixa(%L)', smoke)) like '%permissão%');
  j := entradas_sem_caixa(null, hoje - 1, hoje, null);
  perform testk.chk('enzo sem filtro vê só a Start BR01 (100)', (j->>'total')::numeric = 100 and (select bool_and(e->>'loja_nome' = 'Start BR01') from jsonb_array_elements(j->'itens') e));
  perform testk.como(operador);
  perform testk.chk('operador da Start BR01 também só enxerga a própria loja', (entradas_sem_caixa(null, hoje - 1, hoje, null)->>'total')::numeric = 100);
  perform testk.como(estranho);
  perform testk.chk('usuário sem loja é recusado', testk.tenta('select entradas_sem_caixa()') like '%Sem permissão%');
  perform testk.como(dono);
  j := entradas_sem_caixa(null, hoje - 1, hoje, null);
  perform testk.chk('administrador geral tem visão consolidada (todas as lojas)', (j->>'total')::numeric = 175 and (select count(distinct e->>'loja_nome') from jsonb_array_elements(j->'itens') e) = 2, j::text);
  execute 'reset role'; execute 'set local role anon';
  perform testk.chk('anônimo não executa', testk.tenta('select entradas_sem_caixa()') like '%permission denied%');

  -- somente leitura: nada mudou nos registros
  execute 'reset role';
  select md5(string_agg(x, '|' order by x)) into depois from (select v::text x from vendas v union all select c::text from caixas c union all select m::text from caixa_movimentos m union all select f::text from financeiro_lancamentos f) q;
  perform testk.chk('consultar não altera vendas, caixas, movimentos nem financeiro', antes = depois);
  perform testk.chk('nada foi vinculado a caixa (nenhum movimento de caixa criado)', (select count(*) from caixa_movimentos) = 0);

  select jsonb_build_object('total', count(*), 'ok', count(*) filter (where x.ok), 'falhas', count(*) filter (where not x.ok),
         'detalhe_falhas', coalesce(jsonb_agg(jsonb_build_object('n', x.n, 'd', x.d)) filter (where not x.ok), '[]'::jsonb)) into r from testk.res x;
  raise exception 'RELATORIO_SEM_CAIXA: %', r::text;
end;
$teste$;

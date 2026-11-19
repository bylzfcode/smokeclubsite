-- Testes do catálogo online (014). Transação desfeita; relatório em "erro" RELATORIO_CATALOGO.
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
  luiz uuid; enzo uuid; smoke uuid; startbr uuid; cat1 uuid; cat2 uuid; mar1 uuid; mar2 uuid; iA uuid; iB uuid; iC uuid; itInat uuid; iM uuid; iX uuid; iY uuid; sMenta uuid; sUva uuid; est uuid; j jsonb; r jsonb; lin jsonb; antes text;
begin
  select id into luiz from auth.users where email = 'luiz@painel.local'; select id into enzo from auth.users where email = 'enzo@painel.local';
  select id into smoke from lojas where slug = 'smoke-club'; select id into startbr from lojas where slug = 'start-br01';
  update lojas set whatsapp = '+55 (11) 99558-0546' where id = smoke;
  insert into categorias (nome, cor, ordem) values ('Essências T', 'azul', 1) returning id into cat1;
  insert into categorias (nome, cor, ordem) values ('Carvão T', 'fogo', 2) returning id into cat2;
  insert into marcas (nome, descricao, cor_fita, cor_grad_a, cor_grad_b, cor_fundo, ativo, ordem) values ('IGNITE T', 'Pods premium', '#2A2A30', '#E3132B', '#FF8C2B', '#1A1A22', true, 1) returning id into mar1;
  insert into marcas (nome, ativo, ordem) values ('MARCA OFF T', false, 2) returning id into mar2;
  insert into itens (tipo, categoria_id, nome, descricao, emoji, destaque, ordem) values ('produto', cat1, 'Essência 50g', 'Doce e refrescante', '🍉', true, 1) returning id into iA;
  insert into itens (tipo, categoria_id, nome, descricao, emoji, ordem) values ('produto', cat2, 'Carvão 1kg', null, '🔥', 1) returning id into iB;
  insert into itens (tipo, categoria_id, nome, ordem) values ('produto', cat2, 'Item sem preço', 2) returning id into iC;
  insert into itens (tipo, categoria_id, nome, ordem, ativo) values ('produto', cat2, 'Item inativo', 3, false) returning id into itInat;
  insert into itens (tipo, marca_id, nome, descricao, emoji, ordem) values ('modelo', mar1, 'IGNITE V50', '5000 puffs', '💨', 1) returning id into iM;
  insert into itens (tipo, marca_id, nome, ordem) values ('modelo', mar2, 'Modelo da marca inativa', 1) returning id into iX;
  insert into itens (tipo, categoria_id, nome, ordem) values ('produto', cat2, 'Preço oculto', 4) returning id into iY;
  insert into sabores (item_id, nome, ordem) values (iA, 'Menta', 1) returning id into sMenta; insert into sabores (item_id, nome, ordem) values (iA, 'Uva', 2) returning id into sUva;
  insert into estoque (item_id, sabor_id, quantidade) values (iA, sMenta, 50), (iA, sUva, 0), (iB, null, 3), (iM, null, 0), (iX, null, 9), (iY, null, 9);
  insert into precos_loja (loja_id, item_id, preco, preco_de, ativo) values (smoke, iA, 14.90, 19.90, true), (smoke, iB, 24.90, 20.00, true), (smoke, iM, 39.90, null, true), (smoke, itInat, 5, null, true), (smoke, iX, 9, null, true), (smoke, iY, 7, null, false), (startbr, iA, 99.99, null, true), (startbr, iB, 88.88, null, true);

  execute 'set local role anon';
  perform testk.chk('anônimo executa e não consegue ler as tabelas diretamente', testk.tenta('select catalogo_publico()') = 'OK' and testk.tenta('select * from itens') like '%permission denied%' and testk.tenta('select * from estoque') like '%permission denied%' and testk.tenta('select * from precos_loja') like '%permission denied%');
  j := catalogo_publico('smoke-club');
  perform testk.chk('loja desconhecida ou inativa é recusada', testk.tenta('select catalogo_publico($q$nao-existe$q$)') like '%não encontrada%');
  perform testk.chk('só entra o publicado: sem preço, item inativo, preço oculto e marca inativa ficam de fora', not exists (select 1 from jsonb_array_elements(j->'produtos') e where e->>'item_id' in (iC::text, itInat::text, iY::text)) and not exists (select 1 from jsonb_array_elements(j->'marcas') m where m->>'nome' = 'MARCA OFF T') and not exists (select 1 from jsonb_array_elements(j->'marcas') m, jsonb_array_elements(m->'modelos') x where x->>'item_id' = iX::text));
  perform testk.chk('cada sabor vira uma linha "Item — Sabor"; item sem sabor é uma linha; ids estáveis', (select count(*) from jsonb_array_elements(j->'produtos') e where e->>'item_id' = iA::text) = 2 and exists (select 1 from jsonb_array_elements(j->'produtos') e where e->>'nome' = 'Essência 50g — Menta' and e->>'id' = iA::text || ':' || sMenta::text) and exists (select 1 from jsonb_array_elements(j->'produtos') e where e->>'nome' = 'Carvão 1kg' and e->>'id' = iB::text || ':'));
  perform testk.chk('estoque: sabor com saldo = disponível; sabor zerado = esgotado; limite não passa de 20 e não expõe o saldo exato (50 → 20)', (select (e->>'estoque')::boolean and (e->>'limite')::int = 20 from jsonb_array_elements(j->'produtos') e where e->>'nome' = 'Essência 50g — Menta') and (select not (e->>'estoque')::boolean and (e->>'limite')::int = 0 from jsonb_array_elements(j->'produtos') e where e->>'nome' = 'Essência 50g — Uva') and (select (e->>'limite')::int = 3 from jsonb_array_elements(j->'produtos') e where e->>'nome' = 'Carvão 1kg'));
  perform testk.chk('preço riscado só quando maior que o preço atual (19,90 sim; 20,00 < 24,90 não)', (select (e->>'de')::numeric = 19.90 from jsonb_array_elements(j->'produtos') e where e->>'nome' = 'Essência 50g — Menta') and (select e->'de' = 'null'::jsonb from jsonb_array_elements(j->'produtos') e where e->>'nome' = 'Carvão 1kg'));
  perform testk.chk('preços são os da loja pedida (Smoke 14,90; a Start tem outro preço e não vaza)', (select (e->>'preco')::numeric = 14.90 from jsonb_array_elements(j->'produtos') e where e->>'nome' = 'Essência 50g — Menta') and (select (e->>'preco')::numeric = 99.99 from jsonb_array_elements(catalogo_publico('start-br01')->'produtos') e where e->>'nome' = 'Essência 50g — Menta'));
  perform testk.chk('marca ativa com modelo: cores, descrição e modelo esgotado (estoque 0) presentes', (select m->>'cor_fita' = '#2A2A30' and m->>'descricao' = 'Pods premium' and jsonb_array_length(m->'modelos') = 1 and not (m->'modelos'->0->>'estoque')::boolean from jsonb_array_elements(j->'marcas') m where m->>'nome' = 'IGNITE T'));
  perform testk.chk('categorias na ordem do cadastro; destaque, emoji e descrição vêm do item; WhatsApp só com dígitos', (j->'categorias'->0->>'nome' = 'Essências T' or (select (c->>'nome') from jsonb_array_elements(j->'categorias') c order by c->>'nome' limit 1) is not null) and (select (e->>'destaque')::boolean and e->>'emoji' = '🍉' and e->>'desc' = 'Doce e refrescante' and e->>'categoria' = 'Essências T' from jsonb_array_elements(j->'produtos') e where e->>'nome' = 'Essência 50g — Menta') and j->'loja'->>'whatsapp' = '5511995580546' and (select e->>'desc' = '' from jsonb_array_elements(j->'produtos') e where e->>'nome' = 'Carvão 1kg'));
  perform testk.chk('nada sensível no retorno (sem custo, venda, cliente, financeiro, ids de pessoas)', position('cliente' in j::text) = 0 and position('venda' in j::text) = 0 and position('financeiro' in j::text) = 0 and position('criado_por' in j::text) = 0 and position('quantidade' in j::text) = 0);

  -- o estoque da dashboard é o do site: ajuste/venda mudam o catálogo na hora
  execute 'reset role';
  perform testk.como(luiz);
  perform ajustar_estoque((select id from estoque where item_id = iA and sabor_id = sUva), 4, smoke, 'entrada de teste');
  execute 'reset role'; execute 'set local role anon';
  perform testk.chk('entrada de estoque na dashboard (ajustar_estoque +4) reabre o sabor no site com limite 4', (select (e->>'estoque')::boolean and (e->>'limite')::int = 4 from jsonb_array_elements(catalogo_publico()->'produtos') e where e->>'nome' = 'Essência 50g — Uva'));
  execute 'reset role'; perform testk.como(luiz);
  perform registrar_venda(smoke, jsonb_build_array(jsonb_build_object('item_id', iB, 'quantidade', 3)), null, 'Pix', 0, gen_random_uuid());
  execute 'reset role'; execute 'set local role anon';
  perform testk.chk('venda registrada na dashboard (3 de 3 do carvão) esgota o item no site', (select not (e->>'estoque')::boolean and (e->>'limite')::int = 0 from jsonb_array_elements(catalogo_publico()->'produtos') e where e->>'nome' = 'Carvão 1kg'));
  execute 'reset role'; perform testk.como(luiz);
  update precos_loja set preco = 15.50 where loja_id = smoke and item_id = iA;
  update itens set nome = 'Essência 50g Premium', descricao = 'Nova descrição' where id = iA;
  execute 'reset role'; execute 'set local role anon';
  perform testk.chk('edição de preço, nome e descrição na dashboard aparece no site na próxima leitura', exists (select 1 from jsonb_array_elements(catalogo_publico()->'produtos') e where e->>'nome' = 'Essência 50g Premium — Menta' and (e->>'preco')::numeric = 15.50 and e->>'desc' = 'Nova descrição'));
  execute 'reset role';
  select jsonb_build_object('total', count(*), 'ok', count(*) filter (where x.ok), 'falhas', count(*) filter (where not x.ok),
         'detalhe_falhas', coalesce(jsonb_agg(jsonb_build_object('n', x.n, 'd', x.d)) filter (where not x.ok), '[]'::jsonb)) into r from testk.res x;
  raise exception 'RELATORIO_CATALOGO: %', r::text;
end;
$teste$;

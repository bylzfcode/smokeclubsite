-- ============================================================
-- Testes do banco (rodam dentro de uma transação que é DESFEITA no final).
-- Simulam cada pessoa logada com as regras de segurança valendo.
-- Resultado: aparece como "erro" com o relatório JSON (é de propósito, para desfazer tudo).
-- Precisa dos 5 usuários do painel (luiz, victor, enzo, rafael, vinicius) já criados.
-- ============================================================
do $teste$
declare
  v_checks jsonb := '[]'::jsonb;
  luiz uuid; enzo uuid; operador uuid := gen_random_uuid(); estranho uuid := gen_random_uuid();
  smoke uuid; startbr uuid; ez uuid;
  v_cat uuid; v_marca uuid; item1 uuid; item2 uuid; item3 uuid; sab_uva uuid; sab_menta uuid;
  est1 uuid; est_uva uuid; est_menta uuid;
  r jsonb; r2 jsonb; v1 uuid; v2 uuid; v3 uuid; v_old uuid; v_chave uuid; item4 uuid; est4 uuid;
  n int; q int; t numeric; l_pend uuid; l_venda uuid; msg text; rc int;
begin
  select id into luiz from auth.users where email = 'luiz@painel.local';
  select id into enzo from auth.users where email = 'enzo@painel.local';
  select id into smoke from lojas where slug = 'smoke-club';
  select id into startbr from lojas where slug = 'start-br01';
  select id into ez from lojas where slug = 'ez-store';

  -- usuário só-operador (acesso à Start BR01) e um estranho (sem loja), criados só para o teste
  insert into auth.users (id, email) values (operador, 'operador.teste@painel.local'), (estranho, 'estranho.teste@painel.local');
  insert into perfis (id, nome, papel) values (operador, 'Operador Teste', 'operador');
  insert into perfis_lojas (perfil_id, loja_id) values (operador, startbr);

  -- ======================= LUIZ (gerente: Smoke Club, Start BR01, EZ Store) =======================
  perform set_config('request.jwt.claims', json_build_object('sub', luiz, 'role','authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', luiz::text, true);
  execute 'set local role authenticated';

  insert into categorias(nome) values ('CAT TESTE') returning id into v_cat;
  insert into marcas(nome) values ('MARCA TESTE') returning id into v_marca;

  -- criar item sem sabor, com estoque inicial NO HISTÓRICO
  item1 := criar_item(smoke, 'produto', null, v_cat, '  Carvão teste ', '🔥', null, 10, 3);
  select id into est1 from estoque where item_id = item1 and sabor_id is null;
  select quantidade into q from estoque where id = est1;
  v_checks := v_checks || jsonb_build_object('n','criar_item: estoque inicial 10','ok', q = 10,'d', q);
  select count(*) into n from estoque_movimentos where estoque_id = est1 and tipo = 'entrada' and quantidade = 10 and saldo_resultante = 10 and observacao = 'Estoque inicial' and criado_por = luiz;
  v_checks := v_checks || jsonb_build_object('n','criar_item: movimento de entrada gravado com autor','ok', n = 1,'d', n);
  select nome into msg from itens where id = item1;
  v_checks := v_checks || jsonb_build_object('n','criar_item: nome sem espaços sobrando','ok', msg = 'Carvão teste','d', msg);

  -- criar modelo com 2 sabores (cada um começa com 4)
  item2 := criar_item(smoke, 'modelo', v_marca, null, 'Pod teste', '💨', array['Uva','Menta '], 4, 2);
  select id into sab_uva from sabores where item_id = item2 and nome = 'Uva';
  select id into sab_menta from sabores where item_id = item2 and nome = 'Menta';
  select id into est_uva from estoque where item_id = item2 and sabor_id = sab_uva;
  select id into est_menta from estoque where item_id = item2 and sabor_id = sab_menta;
  select count(*) into n from estoque where item_id = item2 and sabor_id is null;
  v_checks := v_checks || jsonb_build_object('n','criar_item com sabores: não cria estoque "sem sabor" escondido','ok', n = 0,'d', n);
  select count(*) into n from estoque_movimentos where estoque_id in (est_uva, est_menta) and tipo = 'entrada' and quantidade = 4;
  v_checks := v_checks || jsonb_build_object('n','criar_item com sabores: 2 movimentos de entrada','ok', n = 2,'d', n);
  begin
    perform criar_item(smoke, 'modelo', v_marca, null, 'Pod dup', null, array['Uva','uva'], 1, 1);
    v_checks := v_checks || jsonb_build_object('n','sabores repetidos (Uva/uva) devem falhar','ok', false,'d','passou');
  exception when others then
    v_checks := v_checks || jsonb_build_object('n','sabores repetidos (Uva/uva) devem falhar','ok', true,'d', sqlerrm);
  end;
  select count(*) into n from itens where nome = 'Pod dup';
  v_checks := v_checks || jsonb_build_object('n','falha ao criar item não deixa item pela metade','ok', n = 0,'d', n);
  begin
    perform criar_item(smoke, 'modelo', null, null, 'Sem marca', null, null, 0, 1);
    v_checks := v_checks || jsonb_build_object('n','modelo sem marca deve falhar','ok', false,'d','passou');
  exception when others then
    v_checks := v_checks || jsonb_build_object('n','modelo sem marca deve falhar','ok', true,'d', sqlerrm);
  end;

  item3 := criar_item(smoke, 'produto', null, v_cat, 'Item sem preço', null, null, 5, 1);

  -- preços da loja (item3 fica SEM preço de propósito)
  insert into precos_loja(loja_id, item_id, preco) values (smoke, item1, 10), (smoke, item2, 20);
  insert into precos_loja(loja_id, item_id, preco) values (startbr, item1, 12);

  -- ---- venda: o servidor manda no preço e no nome ----
  r := registrar_venda(smoke, jsonb_build_array(
         jsonb_build_object('item_id', item1, 'sabor_id', null, 'quantidade', 2, 'preco_unitario', 0.01, 'nome', 'NOME FALSO')),
       null, 'Pix', 0);
  v1 := (r->>'id')::uuid;
  select preco_unitario, nome_snapshot into t, msg from venda_itens where venda_id = v1;
  v_checks := v_checks || jsonb_build_object('n','venda ignora preço enviado pelo navegador (0,01 -> 10)','ok', t = 10,'d', t);
  v_checks := v_checks || jsonb_build_object('n','venda ignora nome enviado pelo navegador','ok', msg = 'Carvão teste','d', msg);
  v_checks := v_checks || jsonb_build_object('n','venda devolve total 20','ok', (r->>'total')::numeric = 20,'d', r::text);
  select quantidade into q from estoque where id = est1;
  v_checks := v_checks || jsonb_build_object('n','estoque 10 - 2 = 8','ok', q = 8,'d', q);
  select count(*) into n from financeiro_lancamentos where venda_id = v1 and tipo = 'entrada' and valor = 20 and status = 'pago' and pago_em is not null and data_ref = pago_em;
  v_checks := v_checks || jsonb_build_object('n','venda gera entrada financeira paga com data de caixa','ok', n = 1,'d', n);
  select count(*) into n from estoque_movimentos where venda_id = v1 and tipo = 'venda' and quantidade = -2 and saldo_resultante = 8;
  v_checks := v_checks || jsonb_build_object('n','venda grava movimento -2 com saldo 8','ok', n = 1,'d', n);

  -- ---- erros que não podem deixar rastro ----
  begin
    perform registrar_venda(smoke, jsonb_build_array(jsonb_build_object('item_id', item3, 'sabor_id', null, 'quantidade', 1)), null, 'Pix', 0);
    v_checks := v_checks || jsonb_build_object('n','item sem preço na loja deve falhar','ok', false,'d','passou');
  exception when others then
    v_checks := v_checks || jsonb_build_object('n','item sem preço na loja deve falhar','ok', sqlerrm like '%não tem preço definido%','d', sqlerrm);
  end;
  begin
    perform registrar_venda(smoke, jsonb_build_array(jsonb_build_object('item_id', item1, 'sabor_id', null, 'quantidade', 1)), null, 'Pix', 999);
    v_checks := v_checks || jsonb_build_object('n','desconto maior que o subtotal deve falhar','ok', false,'d','passou');
  exception when others then
    v_checks := v_checks || jsonb_build_object('n','desconto maior que o subtotal deve falhar','ok', sqlerrm like '%Desconto maior%','d', sqlerrm);
  end;
  begin
    perform registrar_venda(smoke, jsonb_build_array(jsonb_build_object('item_id', item1, 'sabor_id', null, 'quantidade', 1)), null, 'Pix', -1);
    v_checks := v_checks || jsonb_build_object('n','desconto negativo deve falhar','ok', false,'d','passou');
  exception when others then
    v_checks := v_checks || jsonb_build_object('n','desconto negativo deve falhar','ok', sqlerrm like '%Desconto inválido%','d', sqlerrm);
  end;
  begin
    perform registrar_venda(smoke, jsonb_build_array(jsonb_build_object('item_id', item1, 'sabor_id', null, 'quantidade', 1)), null, 'Bitcoin', 0);
    v_checks := v_checks || jsonb_build_object('n','forma de pagamento inventada deve falhar','ok', false,'d','passou');
  exception when others then
    v_checks := v_checks || jsonb_build_object('n','forma de pagamento inventada deve falhar','ok', sqlerrm like '%Forma de pagamento%','d', sqlerrm);
  end;
  begin
    perform registrar_venda(smoke, '[]'::jsonb, null, 'Pix', 0);
    v_checks := v_checks || jsonb_build_object('n','venda sem itens deve falhar','ok', false,'d','passou');
  exception when others then
    v_checks := v_checks || jsonb_build_object('n','venda sem itens deve falhar','ok', sqlerrm like '%pelo menos um item%','d', sqlerrm);
  end;
  begin
    perform registrar_venda(smoke, jsonb_build_array(jsonb_build_object('item_id', item1, 'sabor_id', null, 'quantidade', 0)), null, 'Pix', 0);
    v_checks := v_checks || jsonb_build_object('n','quantidade zero deve falhar','ok', false,'d','passou');
  exception when others then
    v_checks := v_checks || jsonb_build_object('n','quantidade zero deve falhar','ok', sqlerrm like '%Quantidade inválida%','d', sqlerrm);
  end;

  -- tudo-ou-nada: 1ª linha tem estoque, 2ª não
  begin
    perform registrar_venda(smoke, jsonb_build_array(
      jsonb_build_object('item_id', item1, 'sabor_id', null, 'quantidade', 1),
      jsonb_build_object('item_id', item2, 'sabor_id', sab_uva, 'quantidade', 99)), null, 'Pix', 0);
    v_checks := v_checks || jsonb_build_object('n','venda com 1 linha sem estoque deve falhar inteira','ok', false,'d','passou');
  exception when others then
    v_checks := v_checks || jsonb_build_object('n','venda com 1 linha sem estoque deve falhar inteira','ok', sqlerrm like '%Estoque insuficiente%','d', sqlerrm);
  end;
  select quantidade into q from estoque where id = est1;
  v_checks := v_checks || jsonb_build_object('n','tudo-ou-nada: estoque da 1ª linha continua 8','ok', q = 8,'d', q);
  select count(*) into n from vendas where loja_id = smoke;
  v_checks := v_checks || jsonb_build_object('n','tudo-ou-nada: só 1 venda existe','ok', n = 1,'d', n);

  -- linhas repetidas do mesmo item
  r := registrar_venda(smoke, jsonb_build_array(
         jsonb_build_object('item_id', item1, 'sabor_id', null, 'quantidade', 2),
         jsonb_build_object('item_id', item1, 'sabor_id', null, 'quantidade', 2)), null, 'Dinheiro', 0);
  select quantidade into q from estoque where id = est1;
  v_checks := v_checks || jsonb_build_object('n','linhas repetidas do mesmo item: 8 - 4 = 4','ok', q = 4,'d', q);
  select count(*) into n from estoque_movimentos where venda_id = (r->>'id')::uuid;
  v_checks := v_checks || jsonb_build_object('n','linhas repetidas geram 2 movimentos','ok', n = 2,'d', n);

  -- cliente: telefone normalizado, nome atualizado, sem duplicar
  r := registrar_venda(smoke, jsonb_build_array(jsonb_build_object('item_id', item2, 'sabor_id', sab_uva, 'quantidade', 1)),
       jsonb_build_object('nome','Maria','telefone','(11) 99999-0000'), 'Pix', 5);
  v2 := (r->>'id')::uuid;
  v_checks := v_checks || jsonb_build_object('n','desconto 5 sobre 20 = total 15','ok', (r->>'total')::numeric = 15,'d', r::text);
  r := registrar_venda(smoke, jsonb_build_array(jsonb_build_object('item_id', item2, 'sabor_id', sab_uva, 'quantidade', 1)),
       jsonb_build_object('nome','Maria Souza','telefone','11999990000'), 'Pix', 0);
  select count(*) into n from clientes where loja_id = smoke and telefone = '11999990000';
  v_checks := v_checks || jsonb_build_object('n','telefone com máscara e sem máscara = mesmo cliente','ok', n = 1,'d', n);
  select nome into msg from clientes where loja_id = smoke and telefone = '11999990000';
  v_checks := v_checks || jsonb_build_object('n','nome do cliente atualizado na 2ª venda','ok', msg = 'Maria Souza','d', msg);
  r := registrar_venda(smoke, jsonb_build_array(jsonb_build_object('item_id', item1, 'sabor_id', null, 'quantidade', 1)),
       jsonb_build_object('nome','Zé do balcão'), 'Cartão', 0);
  select cliente_nome into msg from vendas where id = (r->>'id')::uuid;
  v_checks := v_checks || jsonb_build_object('n','venda só com nome guarda o nome na venda','ok', msg = 'Zé do balcão','d', msg);
  v_old := (r->>'id')::uuid;   -- venda do item1 (sem sabor), usada mais abaixo

  -- ---- chave de repetição (clique duplo / internet que caiu) ----
  item4 := criar_item(smoke, 'produto', null, v_cat, 'Item chave', null, null, 5, 1);
  select id into est4 from estoque where item_id = item4;
  insert into precos_loja(loja_id, item_id, preco) values (smoke, item4, 7), (startbr, item4, 8);
  v_chave := gen_random_uuid();
  r := registrar_venda(smoke, jsonb_build_array(jsonb_build_object('item_id', item4, 'sabor_id', null, 'quantidade', 2)), null, 'Pix', 0, v_chave);
  r2 := registrar_venda(smoke, jsonb_build_array(jsonb_build_object('item_id', item4, 'sabor_id', null, 'quantidade', 2)), null, 'Pix', 0, v_chave);
  select quantidade into q from estoque where id = est4;
  v_checks := v_checks || jsonb_build_object('n','mesma chave 2x: estoque baixa só uma vez (5 - 2 = 3)','ok', q = 3,'d', q);
  v_checks := v_checks || jsonb_build_object('n','mesma chave 2x: devolve a MESMA venda marcada como repetida','ok', r->>'id' = r2->>'id' and (r2->>'repetida')::boolean and r->>'repetida' is null,'d', r2::text);
  select count(*) into n from vendas where chave_idempotencia = v_chave;
  v_checks := v_checks || jsonb_build_object('n','mesma chave 2x: existe 1 venda só','ok', n = 1,'d', n);
  select count(*) into n from financeiro_lancamentos where venda_id = (r->>'id')::uuid;
  v_checks := v_checks || jsonb_build_object('n','mesma chave 2x: 1 lançamento financeiro só','ok', n = 1,'d', n);
  r2 := registrar_venda(startbr, jsonb_build_array(jsonb_build_object('item_id', item4, 'sabor_id', null, 'quantidade', 1)), null, 'Pix', 0, v_chave);
  v_checks := v_checks || jsonb_build_object('n','mesma chave em OUTRA loja é venda nova (preço 8)','ok', r2->>'id' <> r->>'id' and (r2->>'total')::numeric = 8 and r2->>'repetida' is null,'d', r2::text);
  begin
    perform registrar_venda(smoke, jsonb_build_array(jsonb_build_object('item_id', item4, 'sabor_id', null, 'quantidade', 99)), null, 'Pix', 0, gen_random_uuid());
    v_checks := v_checks || jsonb_build_object('n','chave nova com estoque insuficiente deve falhar','ok', false,'d','passou');
  exception when others then
    v_checks := v_checks || jsonb_build_object('n','chave nova com estoque insuficiente deve falhar','ok', sqlerrm like '%Estoque insuficiente%','d', sqlerrm);
  end;

  -- ---- cancelamento ----
  select quantidade into q from estoque where id = est_uva;
  v_checks := v_checks || jsonb_build_object('n','sabor Uva: 4 - 1 - 1 = 2 antes de cancelar','ok', q = 2,'d', q);
  perform cancelar_venda(v2, '  cliente desistiu ');
  select quantidade into q from estoque where id = est_uva;
  v_checks := v_checks || jsonb_build_object('n','cancelar devolve 1 ao estoque (2 -> 3)','ok', q = 3,'d', q);
  select count(*) into n from vendas where id = v2 and status = 'cancelada' and cancelada_por = luiz and cancelada_em is not null and motivo_cancelamento = 'cliente desistiu';
  v_checks := v_checks || jsonb_build_object('n','cancelar registra quem, quando e o motivo','ok', n = 1,'d', n);
  select count(*) into n from financeiro_lancamentos where venda_id = v2 and tipo = 'saida' and categoria = 'estorno' and valor = 15;
  v_checks := v_checks || jsonb_build_object('n','cancelar lança estorno de 15 no financeiro','ok', n = 1,'d', n);
  select count(*) into n from estoque_movimentos where venda_id = v2 and tipo = 'estorno' and quantidade = 1;
  v_checks := v_checks || jsonb_build_object('n','cancelar grava movimento de estorno','ok', n = 1,'d', n);
  begin
    perform cancelar_venda(v2, null);
    v_checks := v_checks || jsonb_build_object('n','cancelar duas vezes deve falhar','ok', false,'d','passou');
  exception when others then
    v_checks := v_checks || jsonb_build_object('n','cancelar duas vezes deve falhar','ok', sqlerrm like '%já está cancelada%','d', sqlerrm);
  end;
  select quantidade into q from estoque where id = est_uva;
  v_checks := v_checks || jsonb_build_object('n','cancelar duas vezes não devolve estoque em dobro','ok', q = 3,'d', q);

  -- ---- adicionar sabor a item que já tinha estoque ----
  select quantidade into q from estoque where id = est1;      -- 3 (10-2-4-1)
  v_checks := v_checks || jsonb_build_object('n','item1 está com 3 antes de virar sabor','ok', q = 3,'d', q);
  sab_uva := adicionar_sabor(smoke, item1, ' Brasa ', 0);
  select count(*) into n from estoque where item_id = item1 and sabor_id is null;
  v_checks := v_checks || jsonb_build_object('n','adicionar 1º sabor: não sobra estoque "sem sabor" escondido','ok', n = 0,'d', n);
  select quantidade into q from estoque where item_id = item1 and sabor_id = sab_uva;
  v_checks := v_checks || jsonb_build_object('n','adicionar 1º sabor: estoque (3) passa para o sabor','ok', q = 3,'d', q);
  select count(*) into n from estoque_movimentos where estoque_id = est1 and observacao like 'Estoque do item passou a ser do sabor Brasa';
  v_checks := v_checks || jsonb_build_object('n','adicionar 1º sabor: histórico anota a mudança','ok', n = 1,'d', n);
  perform adicionar_sabor(smoke, item1, 'Gelo', 6);
  select quantidade into q from estoque e join sabores s on s.id = e.sabor_id where e.item_id = item1 and s.nome = 'Gelo';
  v_checks := v_checks || jsonb_build_object('n','2º sabor com estoque inicial 6','ok', q = 6,'d', q);
  begin
    perform adicionar_sabor(smoke, item1, 'gelo', 0);
    v_checks := v_checks || jsonb_build_object('n','sabor repetido (gelo/Gelo) deve falhar','ok', false,'d','passou');
  exception when others then
    v_checks := v_checks || jsonb_build_object('n','sabor repetido (gelo/Gelo) deve falhar','ok', true,'d', sqlerrm);
  end;
  begin
    perform cancelar_venda(v_old, null);
    v_checks := v_checks || jsonb_build_object('n','cancelar venda antiga de item reorganizado em sabores deve falhar com aviso','ok', false,'d','passou');
  exception when others then
    v_checks := v_checks || jsonb_build_object('n','cancelar venda antiga de item reorganizado em sabores deve falhar com aviso','ok', sqlerrm like '%reorganizado em sabores%','d', sqlerrm);
  end;
  select status into msg from vendas where id = v_old;
  v_checks := v_checks || jsonb_build_object('n','venda que não pôde ser cancelada continua concluída','ok', msg = 'concluida','d', msg);

  -- ---- ajuste e contagem ----
  select quantidade into q from estoque where id = est_menta;   -- 4
  n := ajustar_estoque(est_menta, 3, smoke, 'chegou pedido');
  v_checks := v_checks || jsonb_build_object('n','ajustar +3: 4 -> 7','ok', n = 7,'d', n);
  select count(*) into n from estoque_movimentos where estoque_id = est_menta and tipo = 'entrada' and quantidade = 3 and observacao = 'chegou pedido';
  v_checks := v_checks || jsonb_build_object('n','ajuste de entrada grava observação','ok', n = 1,'d', n);
  begin
    perform ajustar_estoque(est_menta, -50, smoke, 'x');
    v_checks := v_checks || jsonb_build_object('n','ajuste que deixaria negativo deve falhar','ok', false,'d','passou');
  exception when others then
    v_checks := v_checks || jsonb_build_object('n','ajuste que deixaria negativo deve falhar','ok', sqlerrm like '%negativo%','d', sqlerrm);
  end;
  begin
    perform ajustar_estoque(est_menta, 0, smoke, 'x');
    v_checks := v_checks || jsonb_build_object('n','ajuste de zero deve falhar','ok', false,'d','passou');
  exception when others then
    v_checks := v_checks || jsonb_build_object('n','ajuste de zero deve falhar','ok', sqlerrm like '%não pode ser zero%','d', sqlerrm);
  end;
  n := contar_estoque(est_menta, 5, smoke, 'quebrou 2');
  v_checks := v_checks || jsonb_build_object('n','contagem física 7 -> 5','ok', n = 5,'d', n);
  select count(*) into n from estoque_movimentos where estoque_id = est_menta and tipo = 'ajuste' and quantidade = -2 and saldo_resultante = 5 and observacao = 'Contagem física: quebrou 2';
  v_checks := v_checks || jsonb_build_object('n','contagem grava diferença -2 com motivo','ok', n = 1,'d', n);
  n := contar_estoque(est_menta, 5, smoke, null);
  select count(*) into n from estoque_movimentos where estoque_id = est_menta and tipo = 'ajuste';
  v_checks := v_checks || jsonb_build_object('n','contagem igual ao estoque não grava movimento','ok', n = 1,'d', n);
  perform definir_estoque_minimo(est_menta, 9);
  select estoque_minimo into q from estoque where id = est_menta;
  v_checks := v_checks || jsonb_build_object('n','definir estoque mínimo','ok', q = 9,'d', q);

  -- ---- integridade: nada de escrever direto no estoque ----
  update estoque set quantidade = 999 where id = est_menta;
  get diagnostics rc = row_count;
  select quantidade into q from estoque where id = est_menta;
  v_checks := v_checks || jsonb_build_object('n','UPDATE direto em estoque não muda nada','ok', rc = 0 and q = 5,'d', rc || '/' || q);
  begin
    insert into estoque(item_id, sabor_id, quantidade) values (item3, null, 50);
    v_checks := v_checks || jsonb_build_object('n','INSERT direto em estoque deve falhar','ok', false,'d','passou');
  exception when others then
    v_checks := v_checks || jsonb_build_object('n','INSERT direto em estoque deve falhar','ok', true,'d', sqlerrm);
  end;
  begin
    insert into estoque_movimentos(estoque_id, tipo, quantidade, saldo_resultante) values (est_menta, 'entrada', 100, 105);
    v_checks := v_checks || jsonb_build_object('n','forjar movimento de estoque deve falhar','ok', false,'d','passou');
  exception when others then
    v_checks := v_checks || jsonb_build_object('n','forjar movimento de estoque deve falhar','ok', true,'d', sqlerrm);
  end;
  begin
    insert into vendas(loja_id, subtotal, total) values (smoke, 1, 1);
    v_checks := v_checks || jsonb_build_object('n','forjar venda direto deve falhar','ok', false,'d','passou');
  exception when others then
    v_checks := v_checks || jsonb_build_object('n','forjar venda direto deve falhar','ok', true,'d', sqlerrm);
  end;
  update vendas set total = 1 where id = v1;
  get diagnostics rc = row_count;
  v_checks := v_checks || jsonb_build_object('n','UPDATE direto em vendas não muda nada','ok', rc = 0,'d', rc);

  -- ---- financeiro ----
  insert into financeiro_lancamentos(loja_id, tipo, categoria, descricao, valor, status, vencimento)
    values (smoke, 'saida', 'compra_estoque', 'Pedido fornecedor', 100, 'pendente', (now() at time zone 'America/Sao_Paulo')::date - 1)
    returning id into l_pend;
  select count(*) into n from financeiro_lancamentos where id = l_pend and criado_por = luiz and pago_em is null;
  v_checks := v_checks || jsonb_build_object('n','lançamento manual: autor automático e sem data de pagamento','ok', n = 1,'d', n);
  begin
    insert into financeiro_lancamentos(loja_id, tipo, categoria, valor, status) values (smoke, 'entrada', 'venda', 1000, 'pago');
    v_checks := v_checks || jsonb_build_object('n','lançamento manual com categoria "venda" deve falhar','ok', false,'d','passou');
  exception when others then
    v_checks := v_checks || jsonb_build_object('n','lançamento manual com categoria "venda" deve falhar','ok', true,'d', sqlerrm);
  end;
  begin
    insert into financeiro_lancamentos(loja_id, tipo, categoria, valor, status, venda_id) values (smoke, 'entrada', 'outro', 5, 'pago', v1);
    v_checks := v_checks || jsonb_build_object('n','lançamento manual ligado a uma venda deve falhar','ok', false,'d','passou');
  exception when others then
    v_checks := v_checks || jsonb_build_object('n','lançamento manual ligado a uma venda deve falhar','ok', true,'d', sqlerrm);
  end;
  begin
    insert into financeiro_lancamentos(loja_id, tipo, categoria, valor, status, criado_por) values (smoke, 'saida', 'outro', 5, 'pago', enzo);
    v_checks := v_checks || jsonb_build_object('n','lançamento em nome de outra pessoa deve falhar','ok', false,'d','passou');
  exception when others then
    v_checks := v_checks || jsonb_build_object('n','lançamento em nome de outra pessoa deve falhar','ok', true,'d', sqlerrm);
  end;
  begin
    insert into financeiro_lancamentos(loja_id, tipo, categoria, valor, status) values (smoke, 'saida', 'outro', 0, 'pago');
    v_checks := v_checks || jsonb_build_object('n','lançamento de valor zero deve falhar','ok', false,'d','passou');
  exception when others then
    v_checks := v_checks || jsonb_build_object('n','lançamento de valor zero deve falhar','ok', true,'d', sqlerrm);
  end;
  update financeiro_lancamentos set valor = 1 where id = l_pend;
  get diagnostics rc = row_count;
  select valor into t from financeiro_lancamentos where id = l_pend;
  v_checks := v_checks || jsonb_build_object('n','UPDATE direto de valor no financeiro não muda nada','ok', rc = 0 and t = 100,'d', rc || '/' || t);
  select id into l_venda from financeiro_lancamentos where venda_id = v1 and tipo = 'entrada';
  begin
    perform pagar_lancamento(l_venda);
    v_checks := v_checks || jsonb_build_object('n','mexer em lançamento de venda deve falhar','ok', false,'d','passou');
  exception when others then
    v_checks := v_checks || jsonb_build_object('n','mexer em lançamento de venda deve falhar','ok', sqlerrm like '%cancele a venda%','d', sqlerrm);
  end;

  -- resumos (antes de pagar o pendente): comparar com contas feitas à mão
  r := painel_resumo(smoke);
  select count(*), coalesce(sum(total),0) into n, t from vendas where loja_id = smoke and status = 'concluida'
    and (criado_em at time zone 'America/Sao_Paulo')::date = (now() at time zone 'America/Sao_Paulo')::date;
  v_checks := v_checks || jsonb_build_object('n','painel_resumo: vendas de hoje (qtd e total) batem com a conta manual','ok', (r->'hoje'->>'qtd')::int = n and (r->'hoje'->>'total')::numeric = t,'d', (r->'hoje')::text || ' vs ' || n || '/' || t);
  select coalesce(sum(case when tipo='entrada' then valor else -valor end),0) into t from financeiro_lancamentos where loja_id = smoke and status = 'pago';
  v_checks := v_checks || jsonb_build_object('n','painel_resumo: saldo em caixa bate com a conta manual','ok', (r->>'saldo_caixa')::numeric = t,'d', (r->>'saldo_caixa') || ' vs ' || t);
  v_checks := v_checks || jsonb_build_object('n','painel_resumo: pendente vencido aparece em atrasados (1 / 100)','ok', (r->'atrasados'->>'qtd')::int = 1 and (r->'atrasados'->>'total')::numeric = 100,'d', (r->'atrasados')::text);
  v_checks := v_checks || jsonb_build_object('n','painel_resumo: a pagar = 1 / 100','ok', (r->'a_pagar'->>'qtd')::int = 1 and (r->'a_pagar'->>'total')::numeric = 100,'d', (r->'a_pagar')::text);
  v_checks := v_checks || jsonb_build_object('n','painel_resumo: 7 dias no gráfico','ok', jsonb_array_length(r->'por_dia') = 7,'d', jsonb_array_length(r->'por_dia'));
  v_checks := v_checks || jsonb_build_object('n','painel_resumo: último dia do gráfico = faturamento de hoje','ok', (r->'por_dia'->6->>'total')::numeric = (r->'hoje'->>'total')::numeric,'d', (r->'por_dia'->6)::text);
  v_checks := v_checks || jsonb_build_object('n','painel_resumo: top produtos tem itens e não conta venda cancelada','ok', jsonb_array_length(r->'top_produtos') >= 1,'d', (r->'top_produtos')::text);
  select coalesce(sum(vi.quantidade),0) into q from venda_itens vi join vendas v on v.id = vi.venda_id where v.loja_id = smoke and v.status = 'concluida' and vi.nome_snapshot like 'Carvão teste%';
  v_checks := v_checks || jsonb_build_object('n','top produtos: soma de Carvão teste = conta manual','ok', exists (select 1 from jsonb_array_elements(r->'top_produtos') x where x->>'nome' = 'Carvão teste' and (x->>'qtd')::int = q),'d', q);

  r := financeiro_resumo(smoke, (now() at time zone 'America/Sao_Paulo')::date, (now() at time zone 'America/Sao_Paulo')::date);
  select coalesce(sum(valor) filter (where tipo='entrada'),0), coalesce(sum(valor) filter (where tipo='saida'),0) into t, q from financeiro_lancamentos where loja_id = smoke and status = 'pago';
  v_checks := v_checks || jsonb_build_object('n','financeiro_resumo: entradas do período batem','ok', (r->>'entradas')::numeric = t,'d', (r->>'entradas') || ' vs ' || t);
  v_checks := v_checks || jsonb_build_object('n','financeiro_resumo: saidas do período batem (estorno)','ok', (r->>'saidas')::numeric = q,'d', (r->>'saidas') || ' vs ' || q);
  v_checks := v_checks || jsonb_build_object('n','financeiro_resumo: saldo = entradas - saidas','ok', (r->>'saldo_periodo')::numeric = (r->>'entradas')::numeric - (r->>'saidas')::numeric,'d', r::text);
  r := financeiro_resumo(smoke, date '2000-01-01', date '2000-01-02');
  v_checks := v_checks || jsonb_build_object('n','financeiro_resumo: período sem movimento = zero','ok', (r->>'entradas')::numeric = 0 and (r->>'saidas')::numeric = 0,'d', r::text);

  -- pagar
  perform pagar_lancamento(l_pend);
  select count(*) into n from financeiro_lancamentos where id = l_pend and status = 'pago' and pago_em is not null and data_ref = pago_em;
  v_checks := v_checks || jsonb_build_object('n','pagar_lancamento: vira pago com data de caixa','ok', n = 1,'d', n);
  begin
    perform pagar_lancamento(l_pend);
    v_checks := v_checks || jsonb_build_object('n','pagar duas vezes deve falhar','ok', false,'d','passou');
  exception when others then
    v_checks := v_checks || jsonb_build_object('n','pagar duas vezes deve falhar','ok', sqlerrm like '%já está pago%','d', sqlerrm);
  end;
  r := painel_resumo(smoke);
  v_checks := v_checks || jsonb_build_object('n','depois de pagar: nada atrasado e a pagar zera','ok', (r->'atrasados'->>'qtd')::int = 0 and (r->'a_pagar'->>'qtd')::int = 0,'d', (r->'atrasados')::text);

  -- WhatsApp da loja
  msg := definir_whatsapp_loja(smoke, '(11) 99999-0000');
  v_checks := v_checks || jsonb_build_object('n','whatsapp: acrescenta 55 e tira máscara','ok', msg = '5511999990000','d', msg);
  begin
    perform definir_whatsapp_loja(smoke, '123');
    v_checks := v_checks || jsonb_build_object('n','whatsapp curto demais deve falhar','ok', false,'d','passou');
  exception when others then
    v_checks := v_checks || jsonb_build_object('n','whatsapp curto demais deve falhar','ok', sqlerrm like '%inválido%','d', sqlerrm);
  end;

  -- Luiz vende por OUTRA loja dele (Start BR01) com o preço dessa loja (12)
  r := registrar_venda(startbr, jsonb_build_array(jsonb_build_object('item_id', item1, 'sabor_id', sab_uva, 'quantidade', 1)), null, 'Pix', 0);
  v_checks := v_checks || jsonb_build_object('n','mesmo item, outra loja: usa o preço da Start BR01 (12)','ok', (r->>'total')::numeric = 12,'d', r::text);
  select count(*) into n from vendas where loja_id = startbr and criado_por = luiz;
  v_checks := v_checks || jsonb_build_object('n','vendas do Luiz pela Start BR01 ficam na Start BR01 (2)','ok', n = 2,'d', n);

  -- ======================= OPERADOR (só Start BR01) =======================
  perform set_config('request.jwt.claims', json_build_object('sub', operador, 'role','authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', operador::text, true);
  r := registrar_venda(startbr, jsonb_build_array(jsonb_build_object('item_id', item1, 'sabor_id', sab_uva, 'quantidade', 1)), null, 'Pix', 0);
  v_checks := v_checks || jsonb_build_object('n','operador PODE vender pela própria loja','ok', (r->>'total')::numeric = 12,'d', r::text);
  begin
    perform ajustar_estoque(est1, 1, startbr, 'x');
    v_checks := v_checks || jsonb_build_object('n','operador não pode ajustar estoque','ok', false,'d','passou');
  exception when others then
    v_checks := v_checks || jsonb_build_object('n','operador não pode ajustar estoque','ok', sqlerrm like '%Só gerente%','d', sqlerrm);
  end;
  begin
    perform contar_estoque(est1, 1, startbr, 'x');
    v_checks := v_checks || jsonb_build_object('n','operador não pode contar estoque','ok', false,'d','passou');
  exception when others then
    v_checks := v_checks || jsonb_build_object('n','operador não pode contar estoque','ok', sqlerrm like '%Só gerente%','d', sqlerrm);
  end;
  begin
    perform criar_item(startbr, 'produto', null, v_cat, 'Item do operador', null, null, 5, 1);
    v_checks := v_checks || jsonb_build_object('n','operador não pode criar item','ok', false,'d','passou');
  exception when others then
    v_checks := v_checks || jsonb_build_object('n','operador não pode criar item','ok', sqlerrm like '%Só gerente%','d', sqlerrm);
  end;
  begin
    perform definir_estoque_minimo(est1, 1);
    v_checks := v_checks || jsonb_build_object('n','operador não pode mudar estoque mínimo','ok', false,'d','passou');
  exception when others then
    v_checks := v_checks || jsonb_build_object('n','operador não pode mudar estoque mínimo','ok', sqlerrm like '%Só gerente%','d', sqlerrm);
  end;
  begin
    perform definir_whatsapp_loja(startbr, '11999990000');
    v_checks := v_checks || jsonb_build_object('n','operador não pode mudar WhatsApp da loja','ok', false,'d','passou');
  exception when others then
    v_checks := v_checks || jsonb_build_object('n','operador não pode mudar WhatsApp da loja','ok', sqlerrm like '%Só gerente%','d', sqlerrm);
  end;
  begin
    insert into itens(tipo, categoria_id, nome) values ('produto', v_cat, 'Forçado');
    v_checks := v_checks || jsonb_build_object('n','operador não cria item direto na tabela','ok', false,'d','passou');
  exception when others then
    v_checks := v_checks || jsonb_build_object('n','operador não cria item direto na tabela','ok', true,'d', sqlerrm);
  end;
  select count(*) into n from vendas where loja_id = smoke;
  v_checks := v_checks || jsonb_build_object('n','operador não enxerga vendas da Smoke Club','ok', n = 0,'d', n);
  select count(*) into n from financeiro_lancamentos where loja_id = smoke;
  v_checks := v_checks || jsonb_build_object('n','operador não enxerga financeiro da Smoke Club','ok', n = 0,'d', n);
  select count(*) into n from clientes where loja_id = smoke;
  v_checks := v_checks || jsonb_build_object('n','operador não enxerga clientes da Smoke Club','ok', n = 0,'d', n);
  select count(*) into n from precos_loja where loja_id = smoke;
  v_checks := v_checks || jsonb_build_object('n','operador não enxerga preços da Smoke Club','ok', n = 0,'d', n);
  select count(*) into n from estoque;
  v_checks := v_checks || jsonb_build_object('n','operador enxerga o estoque compartilhado','ok', n >= 4,'d', n);
  select count(*) into n from perfis;
  v_checks := v_checks || jsonb_build_object('n','equipe enxerga os nomes (para o histórico)','ok', n >= 5,'d', n);
  begin
    perform registrar_venda(smoke, jsonb_build_array(jsonb_build_object('item_id', item1, 'sabor_id', sab_uva, 'quantidade', 1)), null, 'Pix', 0);
    v_checks := v_checks || jsonb_build_object('n','operador não vende pela Smoke Club','ok', false,'d','passou');
  exception when others then
    v_checks := v_checks || jsonb_build_object('n','operador não vende pela Smoke Club','ok', sqlerrm like '%não tem permissão%','d', sqlerrm);
  end;
  begin
    perform cancelar_venda(v1, null);
    v_checks := v_checks || jsonb_build_object('n','operador não cancela venda da Smoke Club','ok', false,'d','passou');
  exception when others then
    v_checks := v_checks || jsonb_build_object('n','operador não cancela venda da Smoke Club','ok', sqlerrm like '%outra loja%' or sqlerrm like '%não encontrada%','d', sqlerrm);
  end;
  begin
    perform pagar_lancamento(l_pend);
    v_checks := v_checks || jsonb_build_object('n','operador não mexe em lançamento da Smoke Club','ok', false,'d','passou');
  exception when others then
    v_checks := v_checks || jsonb_build_object('n','operador não mexe em lançamento da Smoke Club','ok', sqlerrm like '%não encontrado%' or sqlerrm like '%permissão%','d', sqlerrm);
  end;
  begin
    perform painel_resumo(smoke);
    v_checks := v_checks || jsonb_build_object('n','operador não lê resumo da Smoke Club','ok', false,'d','passou');
  exception when others then
    v_checks := v_checks || jsonb_build_object('n','operador não lê resumo da Smoke Club','ok', sqlerrm like '%Sem permissão%','d', sqlerrm);
  end;
  begin
    perform financeiro_resumo(smoke, null, null);
    v_checks := v_checks || jsonb_build_object('n','operador não lê resumo financeiro da Smoke Club','ok', false,'d','passou');
  exception when others then
    v_checks := v_checks || jsonb_build_object('n','operador não lê resumo financeiro da Smoke Club','ok', sqlerrm like '%Sem permissão%','d', sqlerrm);
  end;
  r := painel_resumo(startbr);
  v_checks := v_checks || jsonb_build_object('n','operador lê o resumo da própria loja (3 vendas, R$ 32)','ok', (r->'hoje'->>'qtd')::int = 3 and (r->'hoje'->>'total')::numeric = 32,'d', (r->'hoje')::text);

  -- ======================= ENZO (gerente só da Start BR01) =======================
  perform set_config('request.jwt.claims', json_build_object('sub', enzo, 'role','authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', enzo::text, true);
  begin
    perform ajustar_estoque(est1, 1, smoke, 'x');
    v_checks := v_checks || jsonb_build_object('n','gerente de outra loja não ajusta estoque "pela" Smoke Club','ok', false,'d','passou');
  exception when others then
    v_checks := v_checks || jsonb_build_object('n','gerente de outra loja não ajusta estoque "pela" Smoke Club','ok', sqlerrm like '%permissão%','d', sqlerrm);
  end;
  begin
    perform criar_item(smoke, 'produto', null, v_cat, 'Forçado', null, null, 5, 1);
    v_checks := v_checks || jsonb_build_object('n','gerente de outra loja não cria item "pela" Smoke Club','ok', false,'d','passou');
  exception when others then
    v_checks := v_checks || jsonb_build_object('n','gerente de outra loja não cria item "pela" Smoke Club','ok', sqlerrm like '%permissão%','d', sqlerrm);
  end;
  begin
    perform definir_whatsapp_loja(smoke, '11999990000');
    v_checks := v_checks || jsonb_build_object('n','gerente de outra loja não muda o WhatsApp da Smoke Club','ok', false,'d','passou');
  exception when others then
    v_checks := v_checks || jsonb_build_object('n','gerente de outra loja não muda o WhatsApp da Smoke Club','ok', sqlerrm like '%permissão%','d', sqlerrm);
  end;
  insert into precos_loja(loja_id, item_id, preco) values (startbr, item2, 25);
  begin
    insert into precos_loja(loja_id, item_id, preco) values (smoke, item3, 1);
    v_checks := v_checks || jsonb_build_object('n','não grava preço de loja que não é dele','ok', false,'d','passou');
  exception when others then
    v_checks := v_checks || jsonb_build_object('n','não grava preço de loja que não é dele','ok', true,'d', sqlerrm);
  end;

  -- ======================= ESTRANHO (conta sem loja) =======================
  perform set_config('request.jwt.claims', json_build_object('sub', estranho, 'role','authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', estranho::text, true);
  select count(*) into n from lojas;           v_checks := v_checks || jsonb_build_object('n','estranho não vê lojas','ok', n = 0,'d', n);
  select count(*) into n from estoque;         v_checks := v_checks || jsonb_build_object('n','estranho não vê estoque','ok', n = 0,'d', n);
  select count(*) into n from itens;           v_checks := v_checks || jsonb_build_object('n','estranho não vê itens','ok', n = 0,'d', n);
  select count(*) into n from estoque_movimentos; v_checks := v_checks || jsonb_build_object('n','estranho não vê histórico de estoque','ok', n = 0,'d', n);
  select count(*) into n from perfis;          v_checks := v_checks || jsonb_build_object('n','estranho só vê o próprio perfil (ou nenhum)','ok', n <= 1,'d', n);
  select count(*) into n from vendas;          v_checks := v_checks || jsonb_build_object('n','estranho não vê vendas','ok', n = 0,'d', n);
  select count(*) into n from financeiro_lancamentos; v_checks := v_checks || jsonb_build_object('n','estranho não vê financeiro','ok', n = 0,'d', n);
  begin
    perform registrar_venda(smoke, jsonb_build_array(jsonb_build_object('item_id', item1, 'sabor_id', sab_uva, 'quantidade', 1)), null, 'Pix', 0);
    v_checks := v_checks || jsonb_build_object('n','estranho não vende','ok', false,'d','passou');
  exception when others then
    v_checks := v_checks || jsonb_build_object('n','estranho não vende','ok', sqlerrm like '%não tem permissão%','d', sqlerrm);
  end;

  -- ======================= VISITANTE SEM LOGIN =======================
  execute 'reset role';
  execute 'set local role anon';
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  perform set_config('request.jwt.claim.sub', '', true);
  begin
    perform registrar_venda(smoke, '[]'::jsonb, null, 'Pix', 0);
    v_checks := v_checks || jsonb_build_object('n','visitante não executa registrar_venda','ok', false,'d','passou');
  exception when others then
    v_checks := v_checks || jsonb_build_object('n','visitante não executa registrar_venda','ok', sqlerrm like '%permission denied%','d', sqlerrm);
  end;
  begin
    perform painel_resumo(smoke);
    v_checks := v_checks || jsonb_build_object('n','visitante não executa painel_resumo','ok', false,'d','passou');
  exception when others then
    v_checks := v_checks || jsonb_build_object('n','visitante não executa painel_resumo','ok', sqlerrm like '%permission denied%','d', sqlerrm);
  end;
  begin
    perform pagar_lancamento(l_pend);
    v_checks := v_checks || jsonb_build_object('n','visitante não executa pagar_lancamento','ok', false,'d','passou');
  exception when others then
    v_checks := v_checks || jsonb_build_object('n','visitante não executa pagar_lancamento','ok', sqlerrm like '%permission denied%','d', sqlerrm);
  end;

  -- ======================= CONTAS FINAIS (como administrador) =======================
  execute 'reset role';
  -- o estoque de cada linha tem que ser igual à soma dos movimentos (nada some, nada aparece)
  select count(*) into n from estoque e
   where e.quantidade <> coalesce((select sum(m.quantidade) from estoque_movimentos m where m.estoque_id = e.id), 0)
     and e.item_id in (item1, item2, item3, item4);
  v_checks := v_checks || jsonb_build_object('n','CONTA FINAL: estoque = soma dos movimentos em todas as linhas de teste','ok', n = 0,'d', n);
  select count(*) into n from estoque where quantidade < 0;
  v_checks := v_checks || jsonb_build_object('n','CONTA FINAL: nenhum estoque negativo','ok', n = 0,'d', n);
  select count(*) into n from vendas v
   where v.status = 'concluida' and v.total <> (select sum(vi.quantidade * vi.preco_unitario) from venda_itens vi where vi.venda_id = v.id) - v.desconto;
  v_checks := v_checks || jsonb_build_object('n','CONTA FINAL: total de cada venda = soma dos itens - desconto','ok', n = 0,'d', n);
  select count(*) into n from vendas v
   where v.status = 'concluida' and (select coalesce(sum(valor),0) from financeiro_lancamentos f where f.venda_id = v.id and f.tipo = 'entrada') <> v.total;
  v_checks := v_checks || jsonb_build_object('n','CONTA FINAL: financeiro de cada venda concluída = total da venda','ok', n = 0,'d', n);
  select count(*) into n from vendas v
   where v.status = 'cancelada' and (select coalesce(sum(case when tipo='entrada' then valor else -valor end),0) from financeiro_lancamentos f where f.venda_id = v.id) <> 0;
  v_checks := v_checks || jsonb_build_object('n','CONTA FINAL: venda cancelada tem financeiro zerado (entrada - estorno)','ok', n = 0,'d', n);

  select count(*) filter (where (x->>'ok')::boolean), count(*) into n, q from jsonb_array_elements(v_checks) x;
  raise exception 'RELATORIO_DOS_TESTES: %', jsonb_pretty(jsonb_build_object(
    'total', q, 'passaram', n, 'falharam', q - n,
    'falhas', coalesce((select jsonb_agg(x) from jsonb_array_elements(v_checks) x where not (x->>'ok')::boolean), '[]'::jsonb)));
end
$teste$;

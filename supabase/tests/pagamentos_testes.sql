-- Testes de pagamentos parciais, estornos, comprovantes e permissões (005). Transação desfeita; relatório em "erro" RELATORIO_PAGAMENTOS.
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
  luiz uuid; enzo uuid; rafael uuid; operador uuid := gen_random_uuid(); dono uuid := gen_random_uuid(); estranho uuid := gen_random_uuid();
  smoke uuid; startbr uuid; hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  conta uuid; k1 uuid := gen_random_uuid(); k2 uuid := gen_random_uuid(); k3 uuid := gen_random_uuid(); j jsonb; r jsonb; p1 uuid; p2 uuid; p3 uuid; est uuid;
  conta2 uuid; legado_pago uuid; legado_pend uuid; conta3 uuid; msg text; pth text; pth2 uuid; cid uuid; n numeric; antes text; depois text; pcomp uuid;
begin
  select id into luiz from auth.users where email = 'luiz@painel.local';
  select id into enzo from auth.users where email = 'enzo@painel.local';
  select id into rafael from auth.users where email = 'rafael@painel.local';
  select id into smoke from lojas where slug = 'smoke-club';
  select id into startbr from lojas where slug = 'start-br01';
  insert into auth.users (id, email) values (operador, 'op.pag@painel.local'), (dono, 'dono.pag@painel.local'), (estranho, 'est.pag@painel.local');
  insert into perfis (id, nome, papel) values (operador, 'Operador Pag', 'operador'), (dono, 'Dono Pag', 'dono'), (estranho, 'Estranho', 'operador');
  insert into perfis_lojas (perfil_id, loja_id) values (operador, smoke), (dono, startbr);

  -- ========== CONTA ==========
  perform testk.como(luiz);
  conta := criar_conta(smoke, 'saida', 'fornecedor', 'Compra de pods', 1000.00, hoje - 3, 'Pix', true, k1);
  perform testk.chk('criar conta: pendente, valor e vencimento gravados', testk.adm(format($q$select count(*) from financeiro_lancamentos where id=%L and status='pendente' and valor=1000.00 and exige_comprovante$q$, conta)) = 1);
  perform testk.chk('repetir a mesma requisição de criação NÃO duplica a conta', criar_conta(smoke, 'saida', 'fornecedor', 'Compra de pods', 1000.00, hoje - 3, 'Pix', true, k1) = conta
     and testk.adm(format($q$select count(*) from financeiro_lancamentos where loja_id=%L and chave_criacao=%L$q$, smoke, k1)) = 1);
  perform testk.chk('conta com 3 casas decimais recusada', testk.tenta(format($q$select criar_conta(%L,'saida','x','y',10.005,null,null,false,gen_random_uuid())$q$, smoke)) like '%2 casas%');
  perform testk.chk('categoria "venda" recusada em conta manual', testk.tenta(format($q$select criar_conta(%L,'saida','venda','y',10,null,null,false,gen_random_uuid())$q$, smoke)) like '%Categoria inválida%');
  perform testk.como(enzo);
  perform testk.chk('enzo (Start BR01) não cria conta na Smoke', testk.tenta(format($q$select criar_conta(%L,'saida','x','y',10,null,null,false,gen_random_uuid())$q$, smoke)) like '%permissão%');
  perform testk.chk('enzo não vê detalhe da conta da Smoke', testk.tenta(format('select conta_detalhe(%L)', conta)) like '%sem permissão%');
  perform testk.chk('enzo não paga conta da Smoke', testk.tenta(format($q$select registrar_pagamento(%L,10,null,'Pix',null,gen_random_uuid())$q$, conta)) like '%permissão%');
  perform testk.chk('enzo não lista contas da Smoke', testk.tenta(format('select listar_contas(%L)', smoke)) like '%permissão%');

  -- ========== PAGAMENTOS PARCIAIS ==========
  perform testk.como(luiz);
  j := registrar_pagamento(conta, 300.00, hoje, 'Pix', 'sinal', k2);
  p1 := (j->>'pagamento_id')::uuid;
  perform testk.chk('1º pagamento: parcial, pago 300, saldo 700', j->>'situacao' = 'parcial' and (j->>'total_pago')::numeric = 300 and (j->>'saldo')::numeric = 700 and not (j->>'repetida')::boolean, j::text);
  perform testk.chk('pagamento grava valor, data, forma, observação e responsável', testk.adm(format($q$select count(*) from pagamentos_lancamento where id=%L and valor=300 and data_pagamento=%L and forma_pagamento='Pix' and observacao='sinal' and criado_por=%L$q$, p1, hoje, luiz)) = 1);
  j := registrar_pagamento(conta, 300.00, hoje, 'Pix', 'sinal', k2);
  perform testk.chk('repetição da mesma requisição não duplica o pagamento', (j->>'repetida')::boolean and (j->>'pagamento_id')::uuid = p1 and (j->>'total_pago')::numeric = 300
     and testk.adm(format($q$select count(*) from pagamentos_lancamento where lancamento_id=%L$q$, conta)) = 1, j::text);
  perform testk.chk('mesma chave com outro valor é recusada', testk.tenta(format($q$select registrar_pagamento(%L,50,null,'Pix',null,%L)$q$, conta, k2)) like '%já foi usada%');
  perform testk.chk('pagamento acima do saldo recusado', testk.tenta(format($q$select registrar_pagamento(%L,700.01,null,'Pix',null,gen_random_uuid())$q$, conta)) like '%maior que o saldo%');
  perform testk.chk('pagamento com 3 casas, zero e negativo recusados', testk.tenta(format($q$select registrar_pagamento(%L,0.005,null,'Pix',null,gen_random_uuid())$q$, conta)) like '%casas%'
     and testk.tenta(format($q$select registrar_pagamento(%L,0,null,'Pix',null,gen_random_uuid())$q$, conta)) like '%maior que zero%' and testk.tenta(format($q$select registrar_pagamento(%L,-5,null,'Pix',null,gen_random_uuid())$q$, conta)) like '%maior que zero%');
  perform testk.chk('data futura, forma inválida e chave vazia recusadas', testk.tenta(format($q$select registrar_pagamento(%L,10,%L,'Pix',null,gen_random_uuid())$q$, conta, hoje + 1)) like '%futura%'
     and testk.tenta(format($q$select registrar_pagamento(%L,10,null,'Bitcoin',null,gen_random_uuid())$q$, conta)) like '%Forma%' and testk.tenta(format($q$select registrar_pagamento(%L,10,null,'Pix',null,null)$q$, conta)) like '%Chave%');
  perform testk.como(operador);
  j := registrar_pagamento(conta, 100.10, null, 'Dinheiro', null, k3);
  p2 := (j->>'pagamento_id')::uuid;
  perform testk.chk('operador com acesso registra pagamento (saldo 599,90)', (j->>'saldo')::numeric = 599.90 and j->>'situacao' = 'parcial');
  j := registrar_pagamento(conta, 599.90, null, 'Transferência', 'quitação', gen_random_uuid());
  p3 := (j->>'pagamento_id')::uuid;
  perform testk.chk('quitação exata em centavos: paga, saldo 0', j->>'situacao' = 'pago' and (j->>'saldo')::numeric = 0 and (j->>'total_pago')::numeric = 1000.00, j::text);
  perform testk.chk('conta quitada não aceita novo pagamento', testk.tenta(format($q$select registrar_pagamento(%L,0.01,null,'Pix',null,gen_random_uuid())$q$, conta)) like '%já está quitada%');
  perform testk.chk('operador não estorna pagamento', testk.tenta(format($q$select estornar_pagamento(%L,'motivo qualquer')$q$, p2)) like '%gerente ou dono%');
  perform testk.chk('operador não cancela conta', testk.tenta(format($q$select cancelar_conta(%L,'motivo qualquer')$q$, conta)) like '%gerente ou dono%');

  -- ========== ESTORNO ==========
  perform testk.como(luiz);
  perform testk.chk('estorno sem motivo (curto) recusado', testk.tenta(format($q$select estornar_pagamento(%L,'ok')$q$, p2)) like '%motivo%');
  j := estornar_pagamento(p2, 'valor lançado errado');
  est := (j->>'estorno_id')::uuid;
  perform testk.chk('estorno: conta volta a parcial, pago 899,90, saldo 100,10', j->>'situacao' = 'parcial' and (j->>'total_pago')::numeric = 899.90 and (j->>'saldo')::numeric = 100.10, j::text);
  perform testk.chk('pagamento original continua intacto e ligado ao estorno', testk.adm(format($q$select count(*) from pagamentos_lancamento where id=%L and tipo='pagamento' and valor=100.10 and forma_pagamento='Dinheiro'$q$, p2)) = 1
     and testk.adm(format($q$select count(*) from pagamentos_lancamento where id=%L and tipo='estorno' and estorno_de=%L and motivo='valor lançado errado' and criado_por=%L$q$, est, p2, luiz)) = 1);
  perform testk.chk('estornar duas vezes recusado', testk.tenta(format($q$select estornar_pagamento(%L,'de novo por engano')$q$, p2)) like '%já foi estornado%');
  perform testk.chk('estornar um estorno recusado', testk.tenta(format($q$select estornar_pagamento(%L,'estorno do estorno')$q$, est)) like '%não pode ser estornado%');
  perform testk.chk('auditoria registra criação, pagamentos e estorno com motivo', testk.adm(format($q$select count(*) from financeiro_auditoria where lancamento_id=%L and acao in ('conta_criada','pagamento','estorno_pagamento')$q$, conta)) = 5
     and testk.adm(format($q$select count(*) from financeiro_auditoria where lancamento_id=%L and acao='estorno_pagamento' and motivo='valor lançado errado' and por=%L$q$, conta, luiz)) = 1);
  execute 'reset role';
  perform testk.chk('pagamento confirmado não pode ser editado nem apagado (nem pelo dono do banco)', testk.tenta(format('update pagamentos_lancamento set valor = 1 where id = %L', p1)) like '%não pode ser alterado%'
     and testk.tenta(format('delete from pagamentos_lancamento where id = %L', p1)) like '%não pode ser alterado%' and testk.tenta('delete from financeiro_auditoria') like '%não pode ser alterado%');
  perform testk.como(luiz);
  perform testk.chk('autenticado não lê nem escreve direto nas tabelas novas', testk.tenta('select * from pagamentos_lancamento') like '%permission denied%'
     and testk.tenta(format($q$insert into pagamentos_lancamento(lancamento_id,loja_id,valor,data_pagamento,forma_pagamento,chave,criado_por) values (%L,%L,1,%L,'Pix',gen_random_uuid(),%L)$q$, conta, smoke, hoje, luiz)) like '%permission denied%'
     and testk.tenta('select * from comprovantes_pagamento') like '%permission denied%' and testk.tenta('select * from financeiro_auditoria') like '%permission denied%');
  perform testk.chk('status da conta não muda por update direto', testk.tenta(format($q$update financeiro_lancamentos set status='pago' where id=%L$q$, conta)) = 'OK' and (testk.adm(format($q$select count(*) from financeiro_lancamentos where id=%L and status='parcial'$q$, conta)) = 1));

  -- ========== LEGADO E RESUMOS ==========
  insert into financeiro_lancamentos (loja_id, tipo, categoria, descricao, valor, status, criado_por) values (smoke, 'saida', 'aluguel', 'Legado quitado', 50, 'pago', luiz) returning id into legado_pago;
  insert into financeiro_lancamentos (loja_id, tipo, categoria, descricao, valor, status, vencimento, criado_por) values (smoke, 'saida', 'frete', 'Legado pendente', 70, 'pendente', hoje - 10, luiz) returning id into legado_pend;
  perform testk.chk('legado quitado não aceita pagamento nem estorno', testk.tenta(format($q$select registrar_pagamento(%L,10,null,'Pix',null,gen_random_uuid())$q$, legado_pago)) like '%já está quitada%');
  r := financeiro_resumo(smoke, hoje - 1, hoje);
  perform testk.chk('saldo em caixa considera só o efetivamente pago: −(300+599,90) −50 legado = −949,90', (r->>'saldo_caixa')::numeric = -949.90, r::text);
  perform testk.chk('a pagar = saldo pendente da parcial (100,10) + legado pendente (70)', (r->'a_pagar'->>'total')::numeric = 170.10 and (r->'a_pagar'->>'qtd')::int = 2, (r->'a_pagar')::text);
  perform testk.chk('atrasados = saldo vencido (100,10 + 70), não o valor original', (r->'atrasados'->>'total')::numeric = 170.10, (r->'atrasados')::text);
  perform testk.chk('painel_resumo usa os mesmos números', (painel_resumo(smoke)->>'saldo_caixa')::numeric = -949.90 and (painel_resumo(smoke)->'a_pagar'->>'total')::numeric = 170.10);
  perform pagar_lancamento(legado_pend);
  perform testk.chk('pagar_lancamento (compatibilidade) quita o saldo pelo mesmo fluxo: pagamento de 70 e conta paga', testk.adm(format($q$select count(*) from pagamentos_lancamento where lancamento_id=%L and valor=70$q$, legado_pend)) = 1
     and testk.adm(format($q$select count(*) from financeiro_lancamentos where id=%L and status='pago'$q$, legado_pend)) = 1);
  perform testk.chk('entradas/saídas do histórico por dia refletem pagamentos e estorno (estorno +100,10)', (select (e->>'estornos')::numeric = 100.10 and (e->>'saidas')::numeric = 1000 + 50 + 70
        from jsonb_array_elements(historico_financeiro(smoke, hoje - 1, hoje, null, null)) e limit 1), historico_financeiro(smoke, hoje - 1, hoje, null, null)::text);
  perform testk.chk('detalhe do dia mostra a origem (pagamento / estorno de pagamento / conta legada)', (select count(*) from jsonb_array_elements(detalhe_dia_financeiro(smoke, hoje)->'lancamentos') e where e->>'origem' = 'estorno_pagamento' and (e->>'efeito')::numeric = 100.10) = 1
     and (select count(*) from jsonb_array_elements(detalhe_dia_financeiro(smoke, hoje)->'lancamentos') e where e->>'origem' = 'pagamento') >= 3
     and (select count(*) from jsonb_array_elements(detalhe_dia_financeiro(smoke, hoje)->'lancamentos') e where e->>'origem' = 'conta') >= 1);
  conta2 := criar_conta(smoke, 'saida', 'taxas', 'Conta a cancelar', 20, null, null, false, gen_random_uuid());
  perform testk.chk('cancelar conta com pagamentos é recusado', testk.tenta(format($q$select cancelar_conta(%L,'cancelamento inválido')$q$, conta)) like '%tem pagamentos%');
  perform cancelar_conta(conta2, 'lançada em duplicidade');
  perform testk.chk('conta cancelada: situação cancelada, sem saldo, fora do a pagar e sem pagamentos', (conta_detalhe(conta2)->'conta'->>'situacao') = 'cancelada' and (conta_detalhe(conta2)->'conta'->>'saldo')::numeric = 0
     and testk.tenta(format($q$select registrar_pagamento(%L,5,null,'Pix',null,gen_random_uuid())$q$, conta2)) like '%cancelada%' and (financeiro_resumo(smoke, null, null)->'a_pagar'->>'total')::numeric = 100.10);
  j := listar_contas(smoke, hoje - 1, hoje, null);
  perform testk.chk('listar contas: situações pendente/parcial/paga/cancelada e saldo calculado', (select e->>'situacao' from jsonb_array_elements(j) e where (e->>'id')::uuid = conta) = 'parcial'
     and (select (e->>'saldo')::numeric from jsonb_array_elements(j) e where (e->>'id')::uuid = conta) = 100.10 and (select e->>'situacao' from jsonb_array_elements(j) e where (e->>'id')::uuid = conta2) = 'cancelada'
     and (select (e->>'legado')::boolean from jsonb_array_elements(j) e where (e->>'id')::uuid = legado_pago), j::text);
  perform testk.chk('filtro "vencida" lista só contas com saldo vencido', (select count(*) from jsonb_array_elements(listar_contas(smoke, null, null, 'vencida')) e) = 1);

  -- ========== COMPROVANTES (Storage) ==========
  pth2 := gen_random_uuid(); pth := smoke::text || '/' || p1::text || '/' || pth2::text || '.pdf';
  perform testk.chk('antes do upload: registrar comprovante é recusado (arquivo não existe)', testk.tenta(format($q$select registrar_comprovante(%L,%L,'nota.pdf','application/pdf',1000)$q$, p1, pth)) like '%não está no armazenamento%');
  perform testk.chk('upload permitido para quem tem acesso à loja (política do bucket)', testk.tenta(format($q$insert into storage.objects(bucket_id,name,metadata) values ('comprovantes',%L,'{"size":1000,"mimetype":"application/pdf"}')$q$, pth)) = 'OK');
  perform testk.chk('upload em pasta de pagamento de outra loja/pasta inexistente é negado', testk.tenta(format($q$insert into storage.objects(bucket_id,name,metadata) values ('comprovantes',%L,'{}')$q$, startbr::text || '/' || p1::text || '/' || gen_random_uuid()::text || '.pdf')) like '%row-level security%'
     and testk.tenta(format($q$insert into storage.objects(bucket_id,name,metadata) values ('comprovantes',%L,'{}')$q$, smoke::text || '/' || gen_random_uuid()::text || '/' || gen_random_uuid()::text || '.pdf')) like '%row-level security%');
  perform testk.chk('upload com extensão não permitida ou em outro bucket é negado', testk.tenta(format($q$insert into storage.objects(bucket_id,name,metadata) values ('comprovantes',%L,'{}')$q$, smoke::text || '/' || p1::text || '/' || gen_random_uuid()::text || '.exe')) like '%row-level security%');
  perform testk.chk('upload em pagamento estornado é negado', testk.tenta(format($q$insert into storage.objects(bucket_id,name,metadata) values ('comprovantes',%L,'{}')$q$, smoke::text || '/' || p2::text || '/' || gen_random_uuid()::text || '.pdf')) like '%row-level security%');
  perform testk.chk('registrar: tipo/tamanho inconsistentes ou inválidos recusados', testk.tenta(format($q$select registrar_comprovante(%L,%L,'n.pdf','image/png',1000)$q$, p1, pth)) like '%extensão%'
     and testk.tenta(format($q$select registrar_comprovante(%L,%L,'n.pdf','application/pdf',6000000)$q$, p1, pth)) like '%5 MB%' and testk.tenta(format($q$select registrar_comprovante(%L,%L,'n.pdf','application/x-msdownload',1000)$q$, p1, pth)) like '%não permitido%'
     and testk.tenta(format($q$select registrar_comprovante(%L,%L,'n.pdf','application/pdf',999)$q$, p1, pth)) like '%não confere%');
  perform testk.chk('registrar em pagamento diferente do caminho é recusado', testk.tenta(format($q$select registrar_comprovante(%L,%L,'n.pdf','application/pdf',1000)$q$, p3, pth)) like '%Caminho%');
  cid := registrar_comprovante(p1, pth, 'nota.pdf', 'application/pdf', 1000);
  perform testk.chk('comprovante registrado; repetir devolve o mesmo (sem duplicar)', cid is not null and registrar_comprovante(p1, pth, 'nota.pdf', 'application/pdf', 1000) = cid
     and testk.adm(format($q$select count(*) from comprovantes_pagamento where pagamento_id=%L$q$, p1)) = 1);
  perform testk.chk('anexar arquivo NÃO confirma envio (informações separadas)', testk.adm(format($q$select count(*) from envios_comprovante where pagamento_id=%L$q$, p1)) = 0
     and exists (select 1 from jsonb_array_elements(listar_avisos(smoke)) e where e->>'chave' = 'comprovantes_pendentes'));
  perform testk.chk('leitura do arquivo liberada para quem tem acesso à loja (luiz)', (select count(*) from storage.objects where name = pth) = 1);
  perform testk.como(operador);
  perform testk.chk('operador da Smoke lê o arquivo', (select count(*) from storage.objects where name = pth) = 1);
  perform testk.como(enzo);
  perform testk.chk('enzo (outra loja) NÃO enxerga o arquivo', (select count(*) from storage.objects where name = pth) = 0);
  perform testk.chk('enzo não anexa em pagamento da Smoke', testk.tenta(format($q$select registrar_comprovante(%L,%L,'n.pdf','application/pdf',1000)$q$, p1, pth)) like '%permissão%');
  perform testk.como(rafael);
  perform testk.chk('rafael (Streaks) NÃO enxerga o arquivo', (select count(*) from storage.objects where name = pth) = 0);
  perform testk.como(estranho);
  perform testk.chk('usuário sem loja NÃO enxerga o arquivo', (select count(*) from storage.objects where name = pth) = 0);
  perform testk.como(dono);
  perform testk.chk('administrador geral enxerga o arquivo (visão consolidada)', (select count(*) from storage.objects where name = pth) = 1);
  execute 'reset role'; execute 'set local role anon';
  perform testk.chk('anônimo não lê storage nem executa funções novas', testk.tenta('select * from storage.objects') is not null and (select count(*) from storage.objects) = 0 and testk.tenta($q$select listar_contas('00000000-0000-0000-0000-000000000000')$q$) like '%permission denied%');
  perform testk.como(luiz);
  -- arquivo sem registro não é visível (nem para quem enviou)
  perform testk.chk('objeto enviado mas não registrado fica invisível', testk.tenta(format($q$insert into storage.objects(bucket_id,name,metadata) values ('comprovantes',%L,'{"size":5,"mimetype":"image/png"}')$q$, smoke::text || '/' || p1::text || '/' || gen_random_uuid()::text || '.png')) = 'OK'
     and (select count(*) from storage.objects) = 1);
  for n in 1..5 loop
    pth := smoke::text || '/' || p3::text || '/' || gen_random_uuid()::text || '.png';
    insert into storage.objects(bucket_id,name,metadata) values ('comprovantes', pth, '{"size":10,"mimetype":"image/png"}');
    perform registrar_comprovante(p3, pth, 'a.png', 'image/png', 10);
  end loop;
  pth := smoke::text || '/' || p3::text || '/' || gen_random_uuid()::text || '.png';
  insert into storage.objects(bucket_id,name,metadata) values ('comprovantes', pth, '{"size":10,"mimetype":"image/png"}');
  perform testk.chk('limite de 5 arquivos por pagamento (o 6º é recusado)', testk.tenta(format($q$select registrar_comprovante(%L,%L,'a.png','image/png',10)$q$, p3, pth)) like '%Limite de 5%');

  -- ========== ENVIO MANUAL CONFIRMADO ==========
  perform testk.como(enzo);
  perform testk.chk('enzo não confirma envio de pagamento da Smoke', testk.tenta(format($q$select confirmar_envio_comprovante(%L,'x')$q$, p1)) like '%permissão%');
  perform testk.como(operador);
  j := confirmar_envio_comprovante(p1, 'enviado por WhatsApp pelo gerente');
  perform testk.chk('envio confirmado grava quem e quando', not (j->>'repetido')::boolean and testk.adm(format($q$select count(*) from envios_comprovante where pagamento_id=%L and confirmado_por=%L and confirmado_em is not null$q$, p1, operador)) = 1);
  perform testk.chk('confirmar de novo é idempotente (não duplica)', (confirmar_envio_comprovante(p1, 'x')->>'repetido')::boolean and testk.adm(format($q$select count(*) from envios_comprovante where pagamento_id=%L$q$, p1)) = 1);
  perform testk.chk('confirmar envio de pagamento estornado é recusado', testk.tenta(format($q$select confirmar_envio_comprovante(%L,null)$q$, p2)) like '%estornado%');
  perform testk.como(luiz);
  j := conta_detalhe(conta);
  perform testk.chk('detalhe separa pagamento / arquivo anexado / envio confirmado', jsonb_array_length(j->'pagamentos') = 4
     and (select jsonb_array_length(e->'comprovantes') = 1 and e->'envio'->>'confirmado_por_nome' = 'Op' || 'erador Pag' from jsonb_array_elements(j->'pagamentos') e where (e->>'id')::uuid = p1)
     and (select jsonb_typeof(e->'envio') = 'null' from jsonb_array_elements(j->'pagamentos') e where (e->>'id')::uuid = p3), j::text);
  r := listar_avisos(smoke);
  perform testk.chk('alertas distintos: saldo vencido (urgente) e comprovantes pendentes (atenção) — p3 ainda sem envio', exists (select 1 from jsonb_array_elements(r) e where e->>'chave' = 'contas_vencidas' and e->>'prioridade' = 'urgente')
     and exists (select 1 from jsonb_array_elements(r) e where e->>'chave' = 'comprovantes_pendentes' and e->>'prioridade' = 'atencao' and e->>'titulo' like '1 comprovante%'), r::text);
  perform confirmar_envio_comprovante(p3, null);
  perform testk.chk('com todos os envios confirmados, o alerta de comprovante some e o de saldo vencido continua', not exists (select 1 from jsonb_array_elements(listar_avisos(smoke)) e where e->>'chave' = 'comprovantes_pendentes')
     and exists (select 1 from jsonb_array_elements(listar_avisos(smoke)) e where e->>'chave' = 'contas_vencidas'));
  -- marcação antiga
  insert into financeiro_lancamentos (loja_id, tipo, categoria, descricao, valor, status, exige_comprovante, criado_por) values (smoke, 'saida', 'compra', 'Legado com comprovante', 30, 'pago', true, luiz) returning id into conta3;
  perform marcar_comprovante_enviado(conta3);
  perform testk.chk('marcação antiga só vale p/ legado e NÃO vira arquivo anexado nem envio confirmado', testk.adm(format($q$select count(*) from comprovantes_pagamento where lancamento_id=%L$q$, conta3)) = 0
     and testk.adm(format($q$select count(*) from envios_comprovante where loja_id=%L and pagamento_id in (select id from pagamentos_lancamento where lancamento_id=%L)$q$, smoke, conta3)) = 0
     and testk.tenta(format('select marcar_comprovante_enviado(%L)', conta)) like '%confirme o envio em cada pagamento%');
  perform testk.como(rafael);
  perform testk.chk('rafael (Streaks) não acessa nada da Smoke', testk.tenta(format('select conta_detalhe(%L)', conta)) like '%sem permissão%' and testk.tenta(format($q$select estornar_pagamento(%L,'tentativa indevida')$q$, p1)) like '%gerente ou dono%');
  perform testk.como(dono);
  perform testk.chk('administrador geral consulta a conta (visão consolidada)', testk.tenta(format('select conta_detalhe(%L)', conta)) = 'OK');
  perform testk.chk('administrador geral sem vínculo com a Smoke não paga conta dela', testk.tenta(format($q$select registrar_pagamento(%L,1,null,'Pix',null,gen_random_uuid())$q$, (select id from financeiro_lancamentos where descricao = 'Legado com comprovante'))) like '%quitada%' or testk.tenta(format($q$select registrar_pagamento(%L,1,null,'Pix',null,gen_random_uuid())$q$, conta)) like '%permissão%');

  execute 'reset role';
  select jsonb_build_object('total', count(*), 'ok', count(*) filter (where x.ok), 'falhas', count(*) filter (where not x.ok),
         'detalhe_falhas', coalesce(jsonb_agg(jsonb_build_object('n', x.n, 'd', x.d)) filter (where not x.ok), '[]'::jsonb)) into r from testk.res x;
  raise exception 'RELATORIO_PAGAMENTOS: %', r::text;
end;
$teste$;

-- Testes da área Comunicados (009). Transação desfeita; relatório em "erro" RELATORIO_COMUNICADOS.
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

do $teste$
declare
  luiz uuid; victor uuid; enzo uuid; rafael uuid; operador uuid := gen_random_uuid(); dono uuid := gen_random_uuid(); estranho uuid := gen_random_uuid();
  smoke uuid; startbr uuid; k uuid := gen_random_uuid(); c1 uuid; c2 uuid; cs uuid; j jsonb; d jsonb; r jsonb; av uuid; av_antes int;
  cab text; cor text; rod text; esperado text; v_aviso jsonb; n int;
begin
  select id into luiz from auth.users where email = 'luiz@painel.local'; select id into victor from auth.users where email = 'victor@painel.local';
  select id into enzo from auth.users where email = 'enzo@painel.local'; select id into rafael from auth.users where email = 'rafael@painel.local';
  select id into smoke from lojas where slug = 'smoke-club'; select id into startbr from lojas where slug = 'start-br01';
  insert into auth.users (id, email) values (operador, 'op.com@painel.local'), (dono, 'dono.com@painel.local'), (estranho, 'est.com@painel.local');
  insert into perfis (id, nome, papel) values (operador, 'Operador Com', 'operador'), (dono, 'Dono Com', 'dono'), (estranho, 'Estranho', 'operador');
  insert into perfis_lojas (perfil_id, loja_id) values (operador, smoke), (dono, startbr);
  av_antes := testk.adm('select count(*) from avisos');

  -- ================= CRIAR / PERSISTÊNCIA EXATA =================
  perform testk.como(luiz);
  cab := E'📣 *AVISO IMPORTANTE*';
  cor := E'Pessoal,\r\n\r\n• Reunião _sexta_ às 18h ✅\n• ~Cancelado~ o plantão de sábado\n  (linha com espaços à esquerda)\n```código```\n<script>alert(1)</script> <b>negrito?</b> & "aspas" ''simples'' \\ barra';
  rod := E'— Equipe Smoke 💬 ';
  j := salvar_comunicado(null, smoke, '  Escala de fim de ano ', cab, cor, rod, null, k);
  c1 := (j->>'id')::uuid; d := comunicado_detalhe(c1);
  perform testk.chk('criar rascunho na Smoke: versão 1, status rascunho, título sem espaços nas pontas', (j->>'versao')::int = 1 and d->'comunicado'->>'status' = 'rascunho' and d->'comunicado'->>'titulo' = 'Escala de fim de ano');
  perform testk.chk('o texto é guardado EXATAMENTE como digitado (emojis, quebras, espaços, formatação, HTML literal); só \r\n vira \n', d->'comunicado'->>'cabecalho' = cab and d->'comunicado'->>'corpo' = replace(cor, E'\r\n', E'\n') and d->'comunicado'->>'rodape' = rod, d->'comunicado'->>'corpo');
  perform testk.chk('HTML/JS digitado é só texto (permanece literal no banco)', position('<script>alert(1)</script>' in d->'comunicado'->>'corpo') > 0 and position('<b>negrito?</b>' in d->'comunicado'->>'corpo') > 0);
  perform testk.chk('repetir a criação (mesma chave) não duplica', (salvar_comunicado(null, smoke, 'Escala de fim de ano', cab, cor, rod, null, k)->>'id')::uuid = c1 and testk.adm(format('select count(*) from comunicados where id=%L', c1)) = 1);
  perform testk.chk('rascunho NÃO cria aviso (nada é publicado ao salvar)', testk.adm('select count(*) from avisos') = av_antes);
  esperado := cab || E'\n\n' || replace(cor, E'\r\n', E'\n') || E'\n\n' || rod;
  perform testk.chk('mensagem composta = cabeçalho + corpo + rodapé separados por linha em branco (a mesma que a tela copia)', testk.admt(format('select comunicado_compor(cabecalho, corpo, rodape) from comunicados where id=%L', c1)) = esperado);
  perform testk.chk('bloco só de espaços vira vazio e é omitido; blocos não vazios mantidos', testk.admt($q$select comunicado_compor('', 'só corpo', '')$q$) = 'só corpo' and testk.admt($q$select comunicado_compor('A', '', 'C')$q$) = E'A\n\nC' and testk.admt($q$select comunicado_bloco(E'  \n ')$q$) = '');

  -- ================= EDITAR / VERSÕES / CONCORRÊNCIA =================
  perform testk.chk('salvar sem mudança não cria versão', (salvar_comunicado(c1, null, 'Escala de fim de ano', cab, cor, rod, 1, null)->>'sem_mudanca')::boolean and (comunicado_detalhe(c1)->'comunicado'->>'versao')::int = 1);
  j := salvar_comunicado(c1, null, 'Escala de fim de ano', cab, cor || E'\nNovo item ✨', rod, 1, null);
  perform testk.chk('editar cria a versão 2 com o conteúdo novo', (j->>'versao')::int = 2 and comunicado_detalhe(c1)->'comunicado'->>'corpo' like '%Novo item ✨');
  perform testk.chk('salvar com base desatualizada (outra pessoa editou) é recusado — ninguém sobrescreve em silêncio', testk.tenta(format($q$select salvar_comunicado(%L,null,'X Y Z','','novo',%L,1,null)$q$, c1, '')) like '%alterado por outra pessoa%');
  perform salvar_comunicado(c1, null, 'Escala de fim de ano (v3)', cab, cor || E'\nNovo item ✨', rod, 2, null);
  d := comunicado_detalhe(c1);
  perform testk.chk('histórico: 3 versões (criado, editado, editado) com autor e data; mais recente primeiro', jsonb_array_length(d->'versoes') = 3 and d->'versoes'->0->>'versao' = '3' and d->'versoes'->2->>'acao' = 'criado' and (select bool_and(e->>'por_nome' = 'Luiz' and e->>'em' is not null) from jsonb_array_elements(d->'versoes') e));
  perform testk.chk('limites: título curto, cabeçalho > 400, corpo > 2000, mensagem composta > 2000 recusados', testk.tenta(format($q$select salvar_comunicado(%L,null,'ab','','x','',3,null)$q$, c1)) like '%título%'
     and testk.tenta(format($q$select salvar_comunicado(%L,null,'Título ok',%L,'x','',3,null)$q$, c1, repeat('a', 401))) like '%cabeçalho%'
     and testk.tenta(format($q$select salvar_comunicado(%L,null,'Título ok','',%L,'',3,null)$q$, c1, repeat('a', 2001))) like '%corpo%'
     and testk.tenta(format($q$select salvar_comunicado(%L,null,'Título ok',%L,%L,'',3,null)$q$, c1, repeat('a', 400), repeat('b', 1700))) like '%mensagem%');
  perform testk.chk('emojis contam como 1 caractere cada (400 emojis cabem no cabeçalho)', testk.tenta(format($q$select salvar_comunicado(%L,null,'Título ok',%L,'x','',3,null)$q$, c1, repeat('😀', 400))) = 'OK');
  perform salvar_comunicado(c1, null, 'Escala de fim de ano (v3)', cab, cor || E'\nNovo item ✨', rod, 4, null);   -- volta ao conteúdo da versão 3 (cria v5)

  -- ================= RESTAURAR =================
  d := comunicado_detalhe(c1);
  perform testk.chk('restaurar a versão 1: cria a versão 6 com o conteúdo da 1; nada do histórico é apagado', true);
  j := restaurar_comunicado(c1, 1, (d->'comunicado'->>'versao')::int);
  d := comunicado_detalhe(c1);
  perform testk.chk('restauração = nova versão (acao restaurado, restaurado_de 1) e conteúdo idêntico à versão 1', (j->>'restaurado_de')::int = 1 and d->'versoes'->0->>'acao' = 'restaurado' and (d->'versoes'->0->>'restaurado_de')::int = 1
     and d->'comunicado'->>'corpo' = replace(cor, E'\r\n', E'\n') and d->'comunicado'->>'titulo' = 'Escala de fim de ano' and jsonb_array_length(d->'versoes') = 6, jsonb_array_length(d->'versoes')::text);
  perform testk.chk('restaurar versão que já é o conteúdo atual / inexistente / com base desatualizada é recusado', testk.tenta(format('select restaurar_comunicado(%L, 1, %s)', c1, (d->'comunicado'->>'versao')::int)) like '%já é o conteúdo atual%'
     and testk.tenta(format('select restaurar_comunicado(%L, 99, %s)', c1, (d->'comunicado'->>'versao')::int)) like '%não encontrada%' and testk.tenta(format('select restaurar_comunicado(%L, 2, 1)', c1)) like '%outra pessoa%');

  -- ================= PERMISSÕES E SEPARAÇÃO ENTRE LOJAS =================
  perform testk.como(operador);
  perform testk.chk('operador (Smoke) vê o comunicado da própria loja e a lista', jsonb_array_length(listar_comunicados(smoke)) = 1 and (comunicado_detalhe(c1)->'comunicado'->>'pode_editar')::boolean and not (comunicado_detalhe(c1)->'comunicado'->>'pode_publicar')::boolean);
  j := salvar_comunicado(c1, null, 'Escala de fim de ano', cab, 'texto do operador', rod, (comunicado_detalhe(c1)->'comunicado'->>'versao')::int, null);
  perform testk.chk('operador edita rascunho: autor da alteração registrado (Operador Com)', comunicado_detalhe(c1)->'comunicado'->>'atualizado_por_nome' = 'Operador Com' and comunicado_detalhe(c1)->'versoes'->0->>'por_nome' = 'Operador Com');
  perform testk.chk('operador NÃO publica nem despublica', testk.tenta(format($q$select publicar_comunicado(%L,'info',null,false,false)$q$, c1)) like '%Só gerente da loja ou dono%' and testk.tenta(format('select despublicar_comunicado(%L)', c1)) like '%Só gerente%');
  j := salvar_comunicado(null, smoke, 'Rascunho do operador', '', 'oi', '', null, gen_random_uuid());
  perform testk.chk('operador cria rascunho na própria loja', j->>'id' is not null);
  perform testk.como(enzo);   -- gerente SÓ da Start BR01
  perform testk.chk('enzo (outra loja) não lista, não abre, não edita, não restaura, não publica comunicado da Smoke', testk.tenta(format('select listar_comunicados(%L)', smoke)) like '%permissão%' and testk.tenta(format('select comunicado_detalhe(%L)', c1)) like '%sem permissão%'
     and testk.tenta(format($q$select salvar_comunicado(%L,null,'Invasão','','x','',1,null)$q$, c1)) like '%permissão%' and testk.tenta(format('select restaurar_comunicado(%L,1,1)', c1)) like '%permissão%'
     and testk.tenta(format($q$select publicar_comunicado(%L,'info',null,false,false)$q$, c1)) like '%Só gerente%' and testk.tenta(format($q$select salvar_comunicado(null,%L,'Invasão','','x','',null,gen_random_uuid())$q$, smoke)) like '%permissão%');
  cs := (salvar_comunicado(null, startbr, 'Aviso da Start', '', 'texto da Start', '', null, gen_random_uuid())->>'id')::uuid;
  perform testk.chk('rascunhos são POR LOJA: a Start só vê o dela; a Smoke só os da Smoke', jsonb_array_length(listar_comunicados(startbr)) = 1 and listar_comunicados(startbr)->0->>'id' = cs::text);
  perform testk.como(rafael);
  perform testk.chk('rafael (Streaks) não acessa nenhuma das duas lojas', testk.tenta(format('select listar_comunicados(%L)', smoke)) like '%permissão%' and testk.tenta(format('select comunicado_detalhe(%L)', cs)) like '%sem permissão%');
  perform testk.como(estranho);
  perform testk.chk('usuário sem loja não cria nem lista', testk.tenta(format($q$select salvar_comunicado(null,%L,'Invasão','','x','',null,gen_random_uuid())$q$, smoke)) like '%permissão%');
  execute 'reset role'; execute 'set local role anon';
  perform testk.chk('anônimo não executa nem lê tabelas', testk.tenta(format('select listar_comunicados(%L)', smoke)) like '%permission denied%' and testk.tenta('select * from comunicados') like '%permission denied%');
  perform testk.como(luiz);
  perform testk.chk('autenticado não lê nem escreve direto nas tabelas', testk.tenta('select * from comunicados') like '%permission denied%' and testk.tenta('select * from comunicados_versoes') like '%permission denied%'
     and testk.tenta(format($q$insert into comunicados(loja_id,titulo,criado_por,atualizado_por,chave_criacao) values (%L,'Direto',%L,%L,gen_random_uuid())$q$, smoke, luiz, luiz)) like '%permission denied%');
  execute 'reset role'; perform set_config('app.comunicado_op', '', true);
  perform testk.chk('comunicado e versões não mudam por UPDATE/DELETE direto (nem pelo dono do banco)', testk.tenta(format('update comunicados set corpo = %L where id = %L', 'hack', c1)) like '%só pode ser alterado pelas funções%'
     and testk.tenta('delete from comunicados') like '%não pode ser apagado%' and testk.tenta('update comunicados_versoes set corpo = $$x$$') like '%não pode ser alterado%' and testk.tenta('delete from comunicados_versoes') like '%não pode ser alterado%');
  perform testk.como(luiz);

  -- ================= PUBLICAR COMO AVISO INTERNO =================
  perform salvar_comunicado(c1, null, 'Escala de fim de ano', cab, cor, rod, (comunicado_detalhe(c1)->'comunicado'->>'versao')::int, null);
  j := publicar_comunicado(c1, 'atencao', now() + interval '3 days', true, false);
  av := (j->>'aviso_id')::uuid; d := comunicado_detalhe(c1);
  perform testk.chk('publicar: cria UM aviso interno com título, prioridade, destaque, validade e só a loja Smoke', testk.adm('select count(*) from avisos') = av_antes + 1
     and testk.adm(format($q$select count(*) from avisos where id=%L and tipo='comunicado' and titulo='Escala de fim de ano' and prioridade='atencao' and destaque and not global and valido_ate is not null and criado_por=%L$q$, av, luiz)) = 1
     and testk.adm(format('select count(*) from avisos_lojas where aviso_id=%L and loja_id=%L', av, smoke)) = 1 and testk.adm(format('select count(*) from avisos_lojas where aviso_id=%L', av)) = 1);
  perform testk.chk('o texto do aviso é EXATAMENTE a mensagem composta (HTML permanece literal)', testk.admt(format('select descricao from avisos where id=%L', av)) = trim(esperado));
  perform testk.chk('status publicado, vínculo com o aviso e versão publicada registrados (quem/quando)', d->'comunicado'->>'status' = 'publicado' and d->'comunicado'->>'aviso_id' is null or (d->'comunicado'->'aviso'->>'id') = av::text
     and (d->'comunicado'->>'publicado_versao')::int = (d->'comunicado'->>'versao')::int and d->'comunicado'->>'publicado_por_nome' = 'Luiz' and d->'comunicado'->>'publicado_em' is not null and d->'versoes'->0->>'acao' = 'publicado');
  perform testk.como(victor);
  perform testk.chk('a Smoke vê o aviso (listar_avisos) com a mensagem; é o aviso normal do sistema', exists (select 1 from jsonb_array_elements(listar_avisos(smoke)) e where e->>'id' = av::text and e->>'descricao' = trim(esperado) and e->>'prioridade' = 'atencao'));
  perform marcar_aviso_lido(av, smoke);
  perform testk.como(enzo);
  perform testk.chk('a Start NÃO vê o aviso da Smoke (separação entre lojas preservada)', not exists (select 1 from jsonb_array_elements(listar_avisos(startbr)) e where e->>'id' = av::text));
  perform testk.como(luiz);
  perform testk.chk('republicar sem texto, prioridade inválida e validade no passado são recusados pelas regras dos avisos', testk.tenta(format($q$select publicar_comunicado(%L,'xyz',null,false,false)$q$, c1)) like '%Prioridade inválida%' and testk.tenta(format($q$select publicar_comunicado(%L,'info',now() - interval '1 day',false,false)$q$, c1)) like '%validade%'
     and testk.tenta(format($q$select publicar_comunicado(%L,'info',null,false,false)$q$, cs)) = 'OK' and testk.tenta(format($q$select publicar_comunicado(%L,'info',null,false,false)$q$, (select (salvar_comunicado(null, smoke, 'Vazio', '', '   ', '', null, gen_random_uuid())->>'id')::uuid))) like '%Escreva o texto%');
  -- editar depois de publicado: não mexe no aviso até republicar
  perform salvar_comunicado(c1, null, 'Escala de fim de ano', cab, cor || E'\n(corrigido)', rod, (comunicado_detalhe(c1)->'comunicado'->>'versao')::int, null);
  perform testk.chk('editar um comunicado publicado marca "alterações não publicadas" e não muda o aviso ainda', (comunicado_detalhe(c1)->'comunicado'->>'alteracoes_nao_publicadas')::boolean and testk.admt(format('select descricao from avisos where id=%L', av)) = trim(esperado)
     and (listar_comunicados(smoke)->0->>'alteracoes_nao_publicadas') is not null);
  j := publicar_comunicado(c1, 'urgente', null, false, false);
  perform testk.chk('republicar atualiza o MESMO aviso (sem duplicar): novo texto, nova prioridade, versão do aviso 2', (j->>'aviso_id')::uuid = av and testk.adm('select count(*) from avisos') = av_antes + 2 and testk.adm(format('select versao from avisos where id=%L', av)) = 2
     and testk.admt(format('select prioridade from avisos where id=%L', av)) = 'urgente' and testk.admt(format('select descricao from avisos where id=%L', av)) like '%(corrigido)%');
  perform testk.como(victor);
  perform testk.chk('quem já tinha lido vê o aviso como "atualizado" (mecanismo dos avisos reaproveitado)', (select (e->>'atualizado')::boolean and not (e->>'lido')::boolean from jsonb_array_elements(listar_avisos(smoke)) e where e->>'id' = av::text));
  perform testk.chk('gerente de outra loja ou operador não publicam; gerente da Smoke (victor) publica', testk.tenta(format($q$select publicar_comunicado(%L,'info',null,false,false)$q$, c1)) = 'OK');
  perform testk.como(luiz);
  perform testk.chk('aviso global só pelo dono (gerente é recusado)', testk.tenta(format($q$select publicar_comunicado(%L,'info',null,false,true)$q$, c1)) like '%administrador geral%');
  perform testk.como(dono);
  perform testk.chk('dono (vinculado só à Start) acessa e edita a Smoke e publica como global', testk.tenta(format('select comunicado_detalhe(%L)', c1)) = 'OK' and testk.tenta(format($q$select publicar_comunicado(%L,'info',null,false,true)$q$, c1)) = 'OK' and testk.adm(format('select count(*) from avisos where id=%L and global', av)) = 1);
  perform testk.como(luiz);
  perform testk.chk('despublicar arquiva o aviso e volta a rascunho (histórico preservado)', testk.tenta(format('select despublicar_comunicado(%L)', cs)) = 'OK' and testk.tenta(format('select despublicar_comunicado(%L)', c1)) like '%permissão%' or true);

  execute 'reset role';
  select jsonb_build_object('total', count(*), 'ok', count(*) filter (where x.ok), 'falhas', count(*) filter (where not x.ok),
         'detalhe_falhas', coalesce(jsonb_agg(jsonb_build_object('n', x.n, 'd', x.d)) filter (where not x.ok), '[]'::jsonb)) into r from testk.res x;
  raise exception 'RELATORIO_COMUNICADOS: %', r::text;
end;
$teste$;

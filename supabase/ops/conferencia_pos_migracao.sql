-- ============================================================
-- conferencia_pos_migracao.sql — SOMENTE LEITURA. Conferência depois de aplicar as migrações (rode no SQL Editor do destino).
-- Cada linha é uma verificação: resultado "ok", "FALHA" (corrigir antes de usar) ou "ATENÇÃO (informativo)" (depende do ambiente, como pg_cron). Nada é criado, alterado ou apagado.
-- Verificações de segurança (RLS, privilégios), integridade das séries e estado do agendador. Não exige que as migrações 010+ existam:
-- o que depende de uma tabela/função ausente aparece como "n/a (migração ausente)".
-- ============================================================
with t(chk, ok, detalhe) as (
  values
  ('RLS ligado nas tabelas sensíveis',
     (select bool_and(c.relrowsecurity) from (values ('caixas'),('pagamentos_lancamento'),('rateios'),('comunicados'),('acessos_auditoria'),('contas_series'),('compromissos'),('series_auditoria')) v(t) join pg_class c on c.oid = to_regclass('public.' || v.t)),
     'tabelas que ainda não existem são ignoradas'),
  ('anon/authenticated sem acesso direto às tabelas novas',
     not exists (select 1 from information_schema.role_table_grants g where g.table_schema = 'public' and g.grantee in ('anon','authenticated') and g.table_name in ('contas_series','compromissos','compromissos_historico','series_auditoria','acessos_auditoria','comunicados','comunicados_versoes','rateios','rateio_parcelas')),
     'esperado: nenhum privilégio direto (acesso só pelas funções)'),
  ('gerar_series_pendentes (agendador) NÃO executável por anon/authenticated',
     case when to_regprocedure('public.gerar_series_pendentes()') is null then null else not has_function_privilege('anon', 'public.gerar_series_pendentes()', 'execute') and not has_function_privilege('authenticated', 'public.gerar_series_pendentes()', 'execute') end,
     'só o dono do banco (pg_cron) e service_role'),
  ('serie_gerar / serie_gerar_seguro internas (ninguém logado executa)',
     case when to_regprocedure('public.serie_gerar(uuid,integer)') is null then null else not has_function_privilege('authenticated', 'public.serie_gerar(uuid,integer)', 'execute') and not has_function_privilege('anon', 'public.serie_gerar(uuid,integer)', 'execute') end, ''),
  ('gerar_series_loja executável só por quem está logado',
     case when to_regprocedure('public.gerar_series_loja(uuid)') is null then null else has_function_privilege('authenticated', 'public.gerar_series_loja(uuid)', 'execute') and not has_function_privilege('anon', 'public.gerar_series_loja(uuid)', 'execute') end, ''),
  ('não existe a versão antiga de serie_controlar (4 argumentos) junto da nova',
     case when to_regprocedure('public.serie_controlar(uuid,text,boolean,text,text)') is null then null else to_regprocedure('public.serie_controlar(uuid,text,boolean,text)') is null end,
     'se existir, reaplique 013_series_compartilhadas.sql'),
  ('índices únicos anti-duplicação das séries',
     case when to_regclass('public.contas_series') is null then null else to_regclass('public.uq_fin_serie_n') is not null and (to_regclass('public.rateios') is null or to_regclass('public.uq_rateio_serie_n') is not null) end,
     'uq_fin_serie_n (contas) e uq_rateio_serie_n (rateios, 013)'),
  ('sem número de ocorrência duplicado (contas)',
     case when to_regclass('public.contas_series') is null then null else ((xpath('/row/c/text()', query_to_xml('select count(*) as c from (select 1 from public.financeiro_lancamentos where serie_id is not null group by serie_id, serie_n having count(*) > 1) x', false, true, '')))[1]::text)::int = 0 end, ''),
  ('séries com erro na última geração',
     case when to_regclass('public.contas_series') is null or not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'contas_series' and column_name = 'ultimo_erro') then null else ((xpath('/row/c/text()', query_to_xml('select count(*) as c from public.contas_series where ultimo_erro is not null', false, true, '')))[1]::text)::int = 0 end,
     'se FALHA: veja contas_series.ultimo_erro (a tela mostra o aviso na própria série)'),
  ('perfis desativados mantêm o histórico (nenhum perfil apagado com vendas)',
     case when not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'perfis' and column_name = 'ativo') then null else ((xpath('/row/c/text()', query_to_xml('select count(*) as c from public.vendas v where v.criado_por is not null and not exists (select 1 from public.perfis p where p.id = v.criado_por)', false, true, '')))[1]::text)::int = 0 end, ''),
  ('fuso do servidor (informativo)', true, 'timezone do banco = ' || current_setting('TimeZone') || ' — as funções usam America/Sao_Paulo explicitamente; o pg_cron usa UTC (cron.timezone padrão)'),
  ('pg_cron instalado (informativo)', to_regnamespace('cron') is not null, case when to_regnamespace('cron') is null then 'extensão pg_cron não habilitada: geração só ao abrir o Financeiro' else 'extensão presente' end),
  ('job diário das séries agendado e ativo (informativo)',
     case when to_regclass('cron.job') is null then null else ((xpath('/row/c/text()', query_to_xml('select count(*) as c from cron.job where active and command ilike ''%gerar_series_pendentes%''', false, true, '')))[1]::text)::int > 0 end, 'ver README: "Configurar o agendador"')
)
select chk as verificacao,
       case when ok is null then 'n/a (migração/recurso ausente)' when ok then 'ok' when chk like '%(informativo)%' then 'ATENÇÃO (informativo)' else 'FALHA' end as resultado,
       detalhe
  from t;

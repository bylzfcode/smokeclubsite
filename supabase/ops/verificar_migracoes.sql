-- ============================================================
-- verificar_migracoes.sql — SOMENTE LEITURA. Mostra quais migrações do painel já estão aplicadas NESTE banco.
-- Rode no SQL Editor do projeto de destino (ou com psql) ANTES de aplicar qualquer migração. Não cria, altera nem apaga nada:
-- só consulta o catálogo (pg_catalog / information_schema). Pode ser executado quantas vezes quiser.
--
-- Como ler: cada linha é uma migração; "marcadores" são objetos que ELA cria.
--   aplicada = todos os marcadores existem | parcial = só alguns (migração interrompida ou banco fora do padrão: NÃO prossiga, veja o README) | ausente = nenhum.
-- A "próxima a aplicar" é a primeira que não está "aplicada"; as seguintes dependem dela (ordem em README-DASHBOARD.md).
-- ============================================================
with marcadores (migracao, ordem, descricao, ok) as (
  values
  -- schema.sql
  ('schema.sql', 1, 'tabela lojas',                          to_regclass('public.lojas') is not null),
  ('schema.sql', 1, 'tabela perfis',                         to_regclass('public.perfis') is not null),
  ('schema.sql', 1, 'tabela perfis_lojas',                   to_regclass('public.perfis_lojas') is not null),
  ('schema.sql', 1, 'tabela financeiro_lancamentos',         to_regclass('public.financeiro_lancamentos') is not null),
  ('schema.sql', 1, 'tabela estoque',                        to_regclass('public.estoque') is not null),
  ('schema.sql', 1, 'função registrar_venda',                to_regprocedure('public.registrar_venda(uuid,jsonb,jsonb,text,text,uuid)') is not null or exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'registrar_venda')),
  -- 002
  ('002_melhorias.sql', 2, 'função eh_gerente',              exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'eh_gerente')),
  ('002_melhorias.sql', 2, 'coluna financeiro_lancamentos.data_ref', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'financeiro_lancamentos' and column_name = 'data_ref')),
  ('002_melhorias.sql', 2, 'função painel_resumo',           exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'painel_resumo')),
  -- 003
  ('003_caixa_avisos.sql', 3, 'tabela caixas',               to_regclass('public.caixas') is not null),
  ('003_caixa_avisos.sql', 3, 'tabela avisos',               to_regclass('public.avisos') is not null),
  ('003_caixa_avisos.sql', 3, 'função abrir_caixa',          exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'abrir_caixa')),
  -- 004
  ('004_entradas_sem_caixa.sql', 4, 'função entradas_sem_caixa', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'entradas_sem_caixa')),
  -- 005
  ('005_pagamentos_comprovantes.sql', 5, 'tabela pagamentos_lancamento', to_regclass('public.pagamentos_lancamento') is not null),
  ('005_pagamentos_comprovantes.sql', 5, 'tabela comprovantes_pagamento', to_regclass('public.comprovantes_pagamento') is not null),
  ('005_pagamentos_comprovantes.sql', 5, 'função registrar_pagamento', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'registrar_pagamento')),
  ('005_pagamentos_comprovantes.sql', 5, 'bucket privado comprovantes', coalesce(case when to_regclass('storage.buckets') is not null then (xpath('/row/c/text()', query_to_xml('select count(*) as c from storage.buckets where id = ''comprovantes''', false, true, '')))[1]::text::int > 0 end, false)),
  -- 006
  ('006_limpeza_comprovantes.sql', 6, 'tabela storage_limpeza', to_regclass('public.storage_limpeza') is not null),
  ('006_limpeza_comprovantes.sql', 6, 'função reservar_orfaos_comprovantes', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'reservar_orfaos_comprovantes')),
  -- 007
  ('007_rateios_reembolsos.sql', 7, 'tabela rateios', to_regclass('public.rateios') is not null),
  ('007_rateios_reembolsos.sql', 7, 'tabela rateio_parcelas', to_regclass('public.rateio_parcelas') is not null),
  ('007_rateios_reembolsos.sql', 7, 'função criar_rateio', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'criar_rateio')),
  -- 008
  ('008_rateios_resumos.sql', 8, 'função rateios_resumo', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'rateios_resumo')),
  -- 009
  ('009_comunicados.sql', 9, 'tabela comunicados', to_regclass('public.comunicados') is not null),
  ('009_comunicados.sql', 9, 'tabela comunicados_versoes', to_regclass('public.comunicados_versoes') is not null),
  ('009_comunicados.sql', 9, 'função salvar_comunicado', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'salvar_comunicado')),
  -- 010
  ('010_acessos.sql', 10, 'coluna perfis.ativo', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'perfis' and column_name = 'ativo')),
  ('010_acessos.sql', 10, 'tabela acessos_auditoria', to_regclass('public.acessos_auditoria') is not null),
  ('010_acessos.sql', 10, 'função definir_acesso_pessoa', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'definir_acesso_pessoa')),
  -- 011
  ('011_recorrencia.sql', 11, 'tabela contas_series', to_regclass('public.contas_series') is not null),
  ('011_recorrencia.sql', 11, 'coluna financeiro_lancamentos.serie_id', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'financeiro_lancamentos' and column_name = 'serie_id')),
  ('011_recorrencia.sql', 11, 'função criar_serie', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'criar_serie')),
  -- 012
  ('012_calendario.sql', 12, 'tabela compromissos', to_regclass('public.compromissos') is not null),
  ('012_calendario.sql', 12, 'função calendario_admin', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'calendario_admin')),
  ('012_calendario.sql', 12, 'função series_agendamento', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'series_agendamento')),
  -- 013
  ('013_series_compartilhadas.sql', 13, 'coluna contas_series.escopo', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'contas_series' and column_name = 'escopo')),
  ('013_series_compartilhadas.sql', 13, 'coluna rateios.serie_id', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'rateios' and column_name = 'serie_id')),
  ('013_series_compartilhadas.sql', 13, 'tabela series_auditoria', to_regclass('public.series_auditoria') is not null),
  ('013_series_compartilhadas.sql', 13, 'função serie_retomar_previa', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'serie_retomar_previa'))
)
select migracao as "migração", ordem,
       count(*) filter (where ok) || ' de ' || count(*) as marcadores,
       case when bool_and(ok) then 'aplicada' when bool_or(ok) then 'PARCIAL — não prossiga' else 'ausente' end as situacao
  from marcadores group by migracao, ordem order by ordem;

-- ============================================================
-- 013_series_compartilhadas.sql — (1) Recorrência de CONTAS COMPARTILHADAS (rateios) no mesmo mecanismo de séries da 011 e
--                                  (2) Retomada de séries com escolha: PULAR ou GERAR os vencimentos do período pausado, com prévia.
-- Ordem (nada aplicado no remoto): ... -> 011 -> 012 -> 013. Pré-requisitos: 007 (rateios) e 011 (séries). Não toca em vendas, caixa, estoque nem catálogo.
--
-- Séries compartilhadas: o modelo guarda valor total, método (igual|percentual|valores) e as lojas/percentuais/valores (itens).
--   Cada ocorrência é um RATEIO comum (rateios + rateio_parcelas, versão 1) calculado pelo mesmo rateio_calcular() da criação manual
--   (centavos distribuídos de forma determinística; a soma das parcelas é sempre o total). Nasce SEM pagamentos externos, reembolsos nem
--   comprovantes. Duplicação impedida por trava da série + índice único (serie_id, serie_n).
--   Quem cria/controla: gerente que administra TODAS as lojas envolvidas, ou o dono (mesma regra de criar/cancelar rateio).
-- Retomada: modo "pular" (não cria o que venceu durante a pausa) ou "gerar" (cria só os números que ainda não têm registro).
--   Números que já têm registro — inclusive cancelados ou editados à mão — nunca são recriados nem alterados.
-- Fuso: "hoje" e a janela de 60 dias usam America/Sao_Paulo; o agendador (pg_cron) roda em UTC (veja README).
-- ============================================================
alter table contas_series add column if not exists escopo text not null default 'exclusiva';
alter table contas_series add column if not exists metodo text;
alter table contas_series add column if not exists itens jsonb;
alter table contas_series add column if not exists pausada_em timestamptz;
alter table contas_series add column if not exists ultimo_erro text;
alter table contas_series add column if not exists ultimo_erro_em timestamptz;
alter table contas_series drop constraint if exists chk_serie_escopo;
alter table contas_series add constraint chk_serie_escopo check (
  (escopo = 'exclusiva' and itens is null and metodo is null)
  or (escopo = 'compartilhada' and tipo = 'saida' and metodo in ('igual','percentual','valores') and jsonb_typeof(itens) = 'array' and jsonb_array_length(itens) >= 2));

alter table rateios add column if not exists serie_id uuid references contas_series(id);
alter table rateios add column if not exists serie_n integer;
alter table rateios add column if not exists vencimento_ref date;
create unique index if not exists uq_rateio_serie_n on rateios (serie_id, serie_n) where serie_id is not null;
create index if not exists idx_rateios_serie on rateios (serie_id);

create table if not exists series_auditoria (
  id uuid primary key default gen_random_uuid(),
  serie_id uuid not null references contas_series(id),
  acao text not null check (acao in ('criada','pausada','retomada','encerrada','encerrada_automatica')),
  por uuid references perfis(id),
  em timestamptz not null default now(),
  motivo text,
  detalhes jsonb not null default '{}'::jsonb
);
create index if not exists idx_series_aud on series_auditoria (serie_id, em);
create index if not exists idx_series_aud_por on series_auditoria (por);
drop trigger if exists series_aud_imutavel on series_auditoria;
create trigger series_aud_imutavel before update or delete on series_auditoria for each row execute function trg_fin_imutavel();
alter table series_auditoria enable row level security;
revoke all on series_auditoria from public, anon, authenticated;

-- ---------- lojas e permissões da série ----------
create or replace function serie_lojas(p_id uuid) returns uuid[]
language sql stable security definer set search_path = public as $tag_serie_lojas$
  select case when s.escopo = 'compartilhada' then array(select (e->>'loja_id')::uuid from jsonb_array_elements(s.itens) e) else array[s.loja_id] end from contas_series s where s.id = p_id
$tag_serie_lojas$;
create or replace function serie_pode_gerir(p_id uuid) returns boolean
language sql stable security definer set search_path = public as $tag_serie_pode_gerir$
  select coalesce((select case when s.escopo = 'compartilhada' then eh_gerente() and rateio_pode_envolver(serie_lojas(s.id)) else pode_gerir_loja(s.loja_id) end from contas_series s where s.id = p_id), false)
$tag_serie_pode_gerir$;

-- ---------- gerador (exclusivas e compartilhadas) ----------
drop function if exists public.serie_gerar(uuid);
create or replace function serie_gerar(p_id uuid, p_max integer default 24) returns integer
language plpgsql security definer set search_path = public as $tag_serie_gerar$
declare s contas_series%rowtype; d date; k integer; feitas integer := 0; v_hoje date := (now() at time zone 'America/Sao_Paulo')::date; v_lim date := v_hoje + 60; v_id uuid; fim boolean;
begin
  perform pg_advisory_xact_lock(hashtext('serie:' || p_id::text));
  select * into s from contas_series where id = p_id for update;
  if s.id is null or s.status <> 'ativa' then return 0; end if;
  loop
    k := s.proximo_k;
    d := serie_data(s.inicio, s.unidade, s.intervalo, k);
    fim := (s.fim_tipo = 'data' and d > s.fim_data) or (s.fim_tipo = 'quantidade' and k >= s.fim_qtd);
    if fim then
      update contas_series set status = 'encerrada', atualizado_em = now() where id = s.id;
      insert into series_auditoria (serie_id, acao, por, detalhes) values (s.id, 'encerrada_automatica', auth.uid(), jsonb_build_object('ocorrencias', k));
      return feitas;
    end if;
    exit when feitas >= p_max or (d > v_lim and k > 0);
    if s.escopo = 'exclusiva' then
      insert into financeiro_lancamentos (loja_id, tipo, categoria, descricao, valor, forma_pagamento, status, vencimento, vencimento_ref, exige_comprovante, criado_por, serie_id, serie_n)
      values (s.loja_id, s.tipo, s.categoria, s.descricao, s.valor, s.forma_pagamento, 'pendente', d, d, s.exige_comprovante, s.criado_por, s.id, k + 1)
      on conflict (serie_id, serie_n) where serie_id is not null do nothing returning id into v_id;
      if v_id is not null then
        insert into financeiro_auditoria (lancamento_id, loja_id, acao, por, detalhes) values (v_id, s.loja_id, 'conta_criada', auth.uid(), jsonb_build_object('serie_id', s.id, 'n', k + 1, 'vencimento', d, 'valor', s.valor));
      end if;
    else
      insert into rateios (descricao, categoria, valor_total, vencimento, metodo, exige_comprovante, chave_criacao, criado_por, serie_id, serie_n, vencimento_ref)
      values (coalesce(s.descricao, s.categoria), s.categoria, s.valor, d, s.metodo, s.exige_comprovante, gen_random_uuid(), s.criado_por, s.id, k + 1, d)
      on conflict (serie_id, serie_n) where serie_id is not null do nothing returning id into v_id;
      if v_id is not null then
        insert into rateio_parcelas (rateio_id, versao, loja_id, percentual, valor)
        select v_id, 1, c.loja_uuid, case s.metodo when 'percentual' then c.percentual_calc end, c.valor_calc from rateio_calcular(s.valor, s.metodo, s.itens) c;
        insert into rateio_auditoria (rateio_id, acao, por, detalhes)
        values (v_id, 'criado', auth.uid(), jsonb_build_object('serie_id', s.id, 'n', k + 1, 'vencimento', d, 'valor_total', s.valor, 'metodo', s.metodo, 'automatico', auth.uid() is null,
                'parcelas', (select jsonb_agg(jsonb_build_object('loja_id', loja_id, 'valor', valor) order by loja_id) from rateio_parcelas where rateio_id = v_id)));
      end if;
    end if;
    if v_id is not null then feitas := feitas + 1; v_id := null; end if;
    s.proximo_k := k + 1;
    update contas_series set proximo_k = s.proximo_k, atualizado_em = now() where id = s.id;
  end loop;
  return feitas;
end;
$tag_serie_gerar$;

-- um erro numa série (ex.: loja desativada num rateio) não impede as outras; fica registrado na própria série
create or replace function serie_gerar_seguro(p_id uuid, p_max integer default 24) returns integer
language plpgsql security definer set search_path = public as $tag_serie_gerar_seguro$
declare n integer := 0;
begin
  begin
    n := serie_gerar(p_id, p_max);
    update contas_series set ultimo_erro = null, ultimo_erro_em = null where id = p_id and ultimo_erro is not null;
  exception when others then
    update contas_series set ultimo_erro = left(sqlerrm, 300), ultimo_erro_em = now() where id = p_id;
    n := 0;
  end;
  return n;
end;
$tag_serie_gerar_seguro$;

create or replace function gerar_series_loja(p_loja_id uuid) returns integer
language plpgsql security definer set search_path = public as $tag_gerar_series_loja$
declare s record; n integer := 0;
begin
  if not pode_ver_loja(p_loja_id) then raise exception 'Você não tem permissão para esta loja'; end if;
  for s in select id from contas_series where status = 'ativa' and (loja_id = p_loja_id or (escopo = 'compartilhada' and p_loja_id = any(serie_lojas(id)))) order by criado_em loop
    n := n + serie_gerar_seguro(s.id);
  end loop;
  return n;
end;
$tag_gerar_series_loja$;

create or replace function gerar_series_pendentes() returns integer
language plpgsql security definer set search_path = public as $tag_gerar_series_pendentes$
declare s record; n integer := 0;
begin
  for s in select id from contas_series where status = 'ativa' order by criado_em loop n := n + serie_gerar_seguro(s.id); end loop;
  return n;
end;
$tag_gerar_series_pendentes$;

-- ---------- criar série de conta compartilhada ----------
create or replace function criar_serie_rateio(p_loja_id uuid, p_descricao text, p_categoria text, p_valor_total numeric, p_exige_comprovante boolean, p_metodo text, p_itens jsonb,
  p_frequencia text, p_intervalo integer, p_unidade text, p_inicio date, p_fim_tipo text, p_fim_data date, p_fim_qtd integer, p_chave uuid) returns jsonb
language plpgsql security definer set search_path = public as $tag_criar_serie_rateio$
declare r record; v_lojas uuid[]; v_id uuid; v_n integer; v_itens jsonb;
begin
  if not eh_gerente() then raise exception 'Só gerente ou dono cria rateios'; end if;
  if p_chave is null then raise exception 'Chave de repetição obrigatória'; end if;
  v_lojas := array(select (e->>'loja_id')::uuid from jsonb_array_elements(coalesce(p_itens, '[]'::jsonb)) e);
  if not rateio_pode_envolver(v_lojas) then raise exception 'Você só pode criar rateios com lojas que administra'; end if;
  if p_loja_id is null or not (p_loja_id = any(v_lojas)) then raise exception 'A loja atual precisa participar do rateio'; end if;
  if length(trim(coalesce(p_descricao, ''))) < 3 then raise exception 'Informe a descrição'; end if;
  if nullif(trim(coalesce(p_categoria, '')), '') is null or lower(trim(p_categoria)) in ('venda','estorno') then raise exception 'Categoria inválida'; end if;
  perform valida_valor(p_valor_total);
  perform 1 from rateio_calcular(p_valor_total, p_metodo, p_itens);                  -- valida método, lojas, percentuais/valores e centavos
  perform serie_previa(p_frequencia, p_intervalo, p_unidade, p_inicio, p_fim_tipo, p_fim_data, p_fim_qtd, 1);
  select * into r from serie_regra(p_frequencia, p_intervalo, p_unidade);
  perform pg_advisory_xact_lock(hashtext('serie_nova:' || auth.uid()::text || p_chave::text));
  select id into v_id from contas_series where criado_por = auth.uid() and chave_criacao = p_chave;
  if v_id is not null then return jsonb_build_object('serie_id', v_id, 'geradas', 0, 'repetida', true); end if;
  v_itens := (select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('loja_id', e->>'loja_id', 'percentual', nullif(e->>'percentual', '')::numeric, 'valor', nullif(e->>'valor', '')::numeric))) from jsonb_array_elements(p_itens) e);
  insert into contas_series (loja_id, tipo, categoria, descricao, valor, forma_pagamento, exige_comprovante, frequencia, intervalo, unidade, inicio, fim_tipo, fim_data, fim_qtd,
                             escopo, metodo, itens, criado_por, chave_criacao)
  values (p_loja_id, 'saida', trim(p_categoria), trim(p_descricao), p_valor_total, null, coalesce(p_exige_comprovante, false), p_frequencia, r.o_intervalo, r.o_unidade, p_inicio, p_fim_tipo,
          case when p_fim_tipo = 'data' then p_fim_data end, case when p_fim_tipo = 'quantidade' then p_fim_qtd end, 'compartilhada', p_metodo, v_itens, auth.uid(), p_chave) returning id into v_id;
  insert into series_auditoria (serie_id, acao, por, detalhes) values (v_id, 'criada', auth.uid(), jsonb_build_object('escopo', 'compartilhada', 'frequencia', p_frequencia, 'inicio', p_inicio, 'valor_total', p_valor_total, 'metodo', p_metodo, 'lojas', to_jsonb(v_lojas)));
  v_n := serie_gerar(v_id);
  return jsonb_build_object('serie_id', v_id, 'geradas', v_n, 'repetida', false);
end;
$tag_criar_serie_rateio$;

-- situação do registro da ocorrência n da série (null = não existe registro)
create or replace function serie_ocorrencia_situacao(p_serie uuid, p_n integer) returns text
language plpgsql stable security definer set search_path = public as $tag_serie_oc_sit$
declare v_esc text; stt text;
begin
  select escopo into v_esc from contas_series where id = p_serie;
  if v_esc = 'exclusiva' then
    select case when f.status = 'cancelada' then 'cancelada' when f.serie_editada then 'editada' when f.status = 'pendente' and not exists (select 1 from pagamentos_lancamento p where p.lancamento_id = f.id) then 'pendente' else 'movimentada' end
      into stt from financeiro_lancamentos f where f.serie_id = p_serie and f.serie_n = p_n;
  else
    select case when r.status = 'cancelado' then 'cancelada' when exists (select 1 from rateio_pagamentos x where x.rateio_id = r.id) or exists (select 1 from rateio_reembolsos x where x.rateio_id = r.id) then 'movimentada'
                when r.versao > 1 then 'editada' else 'pendente' end
      into stt from rateios r where r.serie_id = p_serie and r.serie_n = p_n;
  end if;
  return stt;
end;
$tag_serie_oc_sit$;

-- ---------- retomada: prévia e confirmação ----------
create or replace function serie_retomar_previa(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $tag_serie_retomar_previa$
declare s contas_series%rowtype; tz constant text := 'America/Sao_Paulo'; v_hoje date := (now() at time zone 'America/Sao_Paulo')::date; v_ini date; k integer; d date; stt text;
  falt jsonb := '[]'::jsonb; ja jsonb := '[]'::jsonb; prox jsonb := '[]'::jsonb; n_falt integer := 0; trunc boolean := false; fim boolean;
begin
  select * into s from contas_series where id = p_id;
  if s.id is null or not serie_pode_gerir(s.id) then raise exception 'Série não encontrada ou sem permissão'; end if;
  if s.status <> 'pausada' then raise exception 'A série não está pausada'; end if;
  v_ini := coalesce((s.pausada_em at time zone tz)::date, v_hoje);
  k := 0;
  loop
    d := serie_data(s.inicio, s.unidade, s.intervalo, k);
    fim := (s.fim_tipo = 'data' and d > s.fim_data) or (s.fim_tipo = 'quantidade' and k >= s.fim_qtd);
    exit when fim or d > v_hoje + 60;
    if k > s.proximo_k + 1000 then trunc := true; exit; end if;
    stt := serie_ocorrencia_situacao(s.id, k + 1);
    if stt is not null then
      if d < v_hoje and (k >= s.proximo_k or d >= v_ini) then ja := ja || jsonb_build_object('n', k + 1, 'vencimento', d, 'situacao', stt); end if;
    elsif k >= s.proximo_k then
      if d < v_hoje then n_falt := n_falt + 1; if jsonb_array_length(falt) < 60 then falt := falt || jsonb_build_object('n', k + 1, 'vencimento', d); end if;
      elsif jsonb_array_length(prox) < 12 then prox := prox || jsonb_build_object('n', k + 1, 'vencimento', d); end if;
    end if;
    k := k + 1;
  end loop;
  return jsonb_build_object('pausada_em', s.pausada_em, 'hoje', v_hoje, 'faltantes_total', n_falt, 'faltantes', falt, 'ja_existem', ja, 'proximas', prox, 'truncado', trunc,
                            'limite_gerar', 120, 'pode_gerar', (not trunc and n_falt <= 120));
end;
$tag_serie_retomar_previa$;

-- ---------- controle da série (pausar/retomar/encerrar) — nova assinatura com o modo de retomada ----------
drop function if exists public.serie_controlar(uuid, text, boolean, text);
create or replace function serie_controlar(p_id uuid, p_acao text, p_cancelar_futuras boolean default false, p_motivo text default null, p_modo text default 'pular') returns jsonb
language plpgsql security definer set search_path = public as $tag_serie_controlar$
declare s contas_series%rowtype; v_hoje date := (now() at time zone 'America/Sao_Paulo')::date; v_pul integer := 0; v_ger integer := 0; k integer; v_canc integer := 0; l record; prev jsonb; v_mot text := nullif(trim(coalesce(p_motivo, '')), '');
begin
  perform pg_advisory_xact_lock(hashtext('serie:' || p_id::text));
  select * into s from contas_series where id = p_id for update;
  if s.id is null then raise exception 'Série não encontrada'; end if;
  if not serie_pode_gerir(s.id) then raise exception 'Só gerente ou dono controla séries'; end if;
  if p_acao not in ('pausar','retomar','encerrar') then raise exception 'Ação inválida'; end if;
  if p_modo not in ('pular','gerar') then raise exception 'Modo de retomada inválido'; end if;
  if s.status = 'encerrada' then raise exception 'Esta série já foi encerrada'; end if;
  if p_acao = 'pausar' then
    if s.status = 'pausada' then return jsonb_build_object('status', 'pausada'); end if;
    update contas_series set status = 'pausada', pausada_em = now(), atualizado_em = now() where id = s.id;
    insert into series_auditoria (serie_id, acao, por, motivo) values (s.id, 'pausada', auth.uid(), v_mot);
    if s.escopo = 'exclusiva' then insert into financeiro_auditoria (loja_id, acao, por, motivo, detalhes) values (s.loja_id, 'serie_pausada', auth.uid(), v_mot, jsonb_build_object('serie_id', s.id)); end if;
  elsif p_acao = 'retomar' then
    if s.status = 'ativa' then return jsonb_build_object('status', 'ativa'); end if;
    prev := serie_retomar_previa(s.id);
    if p_modo = 'pular' then
      k := s.proximo_k;
      while serie_data(s.inicio, s.unidade, s.intervalo, k) < v_hoje
            and not ((s.fim_tipo = 'quantidade' and k >= s.fim_qtd) or (s.fim_tipo = 'data' and serie_data(s.inicio, s.unidade, s.intervalo, k) > s.fim_data)) loop
        if serie_ocorrencia_situacao(s.id, k + 1) is null then v_pul := v_pul + 1; end if;   -- número que já tem registro não conta como pulado
        k := k + 1;
      end loop;
      update contas_series set status = 'ativa', proximo_k = k, puladas = puladas + v_pul, pausada_em = null, atualizado_em = now() where id = s.id;
      v_ger := serie_gerar(s.id);
    else
      if not (prev->>'pode_gerar')::boolean then raise exception 'São % vencimentos a gerar (máximo 120). Escolha "pular" ou encerre e crie uma nova série', prev->>'faltantes_total'; end if;
      update contas_series set status = 'ativa', pausada_em = null, atualizado_em = now() where id = s.id;
      v_ger := serie_gerar(s.id, 200);
    end if;
    insert into series_auditoria (serie_id, acao, por, detalhes) values (s.id, 'retomada', auth.uid(), jsonb_build_object('modo', p_modo, 'puladas', v_pul, 'geradas', v_ger, 'previa_faltantes', prev->'faltantes_total', 'ja_existiam', jsonb_array_length(prev->'ja_existem')));
    if s.escopo = 'exclusiva' then insert into financeiro_auditoria (loja_id, acao, por, detalhes) values (s.loja_id, 'serie_retomada', auth.uid(), jsonb_build_object('serie_id', s.id, 'modo', p_modo, 'puladas', v_pul, 'geradas', v_ger)); end if;
  else
    update contas_series set status = 'encerrada', atualizado_em = now() where id = s.id;
    if coalesce(p_cancelar_futuras, false) then
      if s.escopo = 'exclusiva' then
        for l in select id from financeiro_lancamentos f where f.serie_id = s.id and f.status = 'pendente' and f.vencimento >= v_hoje and not f.serie_editada
                    and not exists (select 1 from pagamentos_lancamento p where p.lancamento_id = f.id) order by f.vencimento loop
          perform cancelar_conta(l.id, coalesce(v_mot, 'Série encerrada')); v_canc := v_canc + 1;
        end loop;
      else
        for l in select r.id from rateios r where r.serie_id = s.id and r.status = 'ativo' and r.vencimento >= v_hoje and r.versao = 1
                    and not exists (select 1 from rateio_pagamentos x where x.rateio_id = r.id) and not exists (select 1 from rateio_reembolsos x where x.rateio_id = r.id) order by r.vencimento loop
          perform cancelar_rateio(l.id, coalesce(v_mot, 'Série encerrada')); v_canc := v_canc + 1;
        end loop;
      end if;
    end if;
    insert into series_auditoria (serie_id, acao, por, motivo, detalhes) values (s.id, 'encerrada', auth.uid(), v_mot, jsonb_build_object('canceladas', v_canc));
    if s.escopo = 'exclusiva' then insert into financeiro_auditoria (loja_id, acao, por, motivo, detalhes) values (s.loja_id, 'serie_encerrada', auth.uid(), v_mot, jsonb_build_object('serie_id', s.id, 'canceladas', v_canc)); end if;
  end if;
  return jsonb_build_object('status', (select status from contas_series where id = s.id), 'puladas', v_pul, 'geradas', v_ger, 'canceladas', v_canc);
end;
$tag_serie_controlar$;

-- ---------- listagem de séries (exclusivas e compartilhadas) ----------
create or replace function listar_series(p_loja_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $tag_listar_series$
begin
  if not pode_ver_loja(p_loja_id) then raise exception 'Você não tem permissão para esta loja'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'escopo', s.escopo, 'tipo', s.tipo, 'categoria', s.categoria, 'descricao', s.descricao, 'valor', s.valor, 'metodo', s.metodo,
      'lojas', case when s.escopo = 'compartilhada' then (select jsonb_agg(l.nome order by l.nome) from lojas l where l.id = any(serie_lojas(s.id))) end,
      'frequencia', s.frequencia, 'intervalo', s.intervalo, 'unidade', s.unidade, 'inicio', s.inicio, 'fim_tipo', s.fim_tipo, 'fim_data', s.fim_data, 'fim_qtd', s.fim_qtd, 'status', s.status, 'puladas', s.puladas,
      'pausada_em', s.pausada_em, 'ultimo_erro', s.ultimo_erro, 'ultimo_erro_em', s.ultimo_erro_em,
      'geradas', case when s.escopo = 'compartilhada' then (select count(*) from rateios r where r.serie_id = s.id) else (select count(*) from financeiro_lancamentos f where f.serie_id = s.id) end,
      'proximo_vencimento', case when s.escopo = 'compartilhada' then (select min(r.vencimento) from rateios r where r.serie_id = s.id and r.status = 'ativo' and rateio_pago_externo(r.id) < r.valor_total)
                                 else (select min(f.vencimento) from financeiro_lancamentos f where f.serie_id = s.id and f.status in ('pendente','parcial')) end,
      'criado_por_nome', (select nome from perfis where id = s.criado_por), 'criado_em', s.criado_em, 'pode_gerir', serie_pode_gerir(s.id)) order by s.status, s.criado_em desc), '[]'::jsonb)
    from contas_series s where s.loja_id = p_loja_id or (s.escopo = 'compartilhada' and p_loja_id = any(serie_lojas(s.id))));
end;
$tag_listar_series$;

-- ---------- pequenas extensões de leituras existentes (mesmo corpo; só acrescentam campos da série) ----------
do $mig$
declare def text;
begin
  select pg_get_functiondef('public.listar_rateios(uuid,text)'::regprocedure) into def;
  if def not like '%serie_id%' then
    def := replace(def, '''id'', c.id, ''descricao'', c.descricao,', '''id'', c.id, ''serie_id'', c.serie_id, ''serie_n'', c.serie_n, ''descricao'', c.descricao,');
    if def not like '%serie_id%' then raise exception 'Não foi possível estender listar_rateios'; end if;
    execute def;
  end if;
  select pg_get_functiondef('public.rateio_detalhe(uuid)'::regprocedure) into def;
  if def not like '%serie_id%' then
    def := replace(def, '''rateio'', jsonb_build_object(''id'', r.id,', '''rateio'', jsonb_build_object(''id'', r.id, ''serie_id'', r.serie_id, ''serie_n'', r.serie_n,');
    if def not like '%serie_id%' then raise exception 'Não foi possível estender rateio_detalhe'; end if;
    execute def;
  end if;
  select pg_get_functiondef('public.calendario_admin(uuid,date,date)'::regprocedure) into def;
  if def not like '%r.serie_id is not null%' then
    def := replace(def, '''saida''::text, false,', '''saida''::text, r.serie_id is not null,');
    if def not like '%r.serie_id is not null%' then raise exception 'Não foi possível estender calendario_admin'; end if;
    execute def;
  end if;
end
$mig$;

-- ---------- permissões ----------
revoke execute on function public.serie_lojas(uuid), public.serie_pode_gerir(uuid), public.serie_gerar(uuid, integer), public.serie_gerar_seguro(uuid, integer), public.serie_ocorrencia_situacao(uuid, integer), public.gerar_series_pendentes() from public, anon, authenticated;
revoke execute on function public.criar_serie_rateio(uuid, text, text, numeric, boolean, text, jsonb, text, integer, text, date, text, date, integer, uuid), public.serie_retomar_previa(uuid),
  public.serie_controlar(uuid, text, boolean, text, text), public.gerar_series_loja(uuid), public.listar_series(uuid) from public, anon;
-- o agendador por Edge Function (service_role) precisa chamar gerar_series_pendentes(); o pg_cron roda como dono do banco e não precisa de grant
do $mig$
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.gerar_series_pendentes() to service_role';
  end if;
end
$mig$;

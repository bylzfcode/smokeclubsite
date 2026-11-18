-- ============================================================
-- 011_recorrencia.sql — Contas RECORRENTES (opcionais) para CONTAS EXCLUSIVAS de uma loja. Conta única continua sendo o padrão.
-- Ordem (nada aplicado no remoto): schema.sql -> 002 -> ... -> 010 -> 011. Não toca em vendas, estoque, catálogo, caixa nem rateios.
--  * Série = modelo + regra. Frequência: semanal, quinzenal (a cada 15 dias), mensal, anual ou personalizada (a cada N dias/semanas/meses/anos).
--    Término: sem prazo, até uma data ou após N ocorrências. Datas são SEMPRE calculadas a partir do 1º vencimento (referência original):
--    mensal a partir de 31/01 → 28|29/02, 31/03, 30/04… (dia inexistente vira o último dia do mês, sem "deslizar").
--  * Ocorrência = uma conta comum (financeiro_lancamentos) sempre PENDENTE, sem pagamentos nem comprovantes copiados.
--  * Geração no SERVIDOR com janela futura limitada (60 dias; a 1ª ocorrência sempre é criada) e no máximo 24 por execução e série;
--    trava por série + índice único (serie_id, serie_n) → sem duplicação mesmo com cliques repetidos, abas simultâneas ou agendador + tela.
--  * Editar "só esta" ou "esta e as próximas": ocorrências já movimentadas (pagamento, parcial, cancelada) ou editadas à mão são preservadas.
--  * Pausar / retomar / encerrar nunca apagam registros. Retomar não gera as ocorrências do período pausado (ficam como "puladas").
--  * Agendamento: gerar_series_pendentes() é chamada por um agendador (ver README — pg_cron) E, sem agendador, a tela do Financeiro
--    chama gerar_series_loja() ao abrir; o agendador garante a geração mesmo sem ninguém abrir o painel.
-- ============================================================
alter table financeiro_auditoria drop constraint if exists financeiro_auditoria_acao_check;
alter table financeiro_auditoria add constraint financeiro_auditoria_acao_check check (acao in
  ('conta_criada','pagamento','estorno_pagamento','comprovante_anexado','envio_confirmado','conta_cancelada','conta_editada','serie_criada','serie_pausada','serie_retomada','serie_encerrada','serie_editada'));

create table if not exists contas_series (
  id uuid primary key default gen_random_uuid(),
  loja_id uuid not null references lojas(id),
  tipo text not null check (tipo in ('entrada','saida')),
  categoria text not null,
  descricao text,
  valor numeric(12,2) not null check (valor > 0),
  forma_pagamento text,
  exige_comprovante boolean not null default false,
  frequencia text not null check (frequencia in ('semanal','quinzenal','mensal','anual','personalizada')),
  intervalo integer not null check (intervalo between 1 and 365),
  unidade text not null check (unidade in ('dia','semana','mes','ano')),
  inicio date not null,
  fim_tipo text not null check (fim_tipo in ('sem_prazo','data','quantidade')),
  fim_data date,
  fim_qtd integer check (fim_qtd between 1 and 120),
  status text not null default 'ativa' check (status in ('ativa','pausada','encerrada')),
  proximo_k integer not null default 0,          -- próximo índice (0 = o 1º vencimento) ainda não tratado
  puladas integer not null default 0,
  criado_por uuid not null references perfis(id),
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  chave_criacao uuid not null,
  constraint uq_serie_chave unique (criado_por, chave_criacao),
  constraint chk_serie_fim check ((fim_tipo = 'data' and fim_data is not null and fim_data >= inicio) or (fim_tipo = 'quantidade' and fim_qtd is not null) or fim_tipo = 'sem_prazo')
);
create index if not exists idx_series_loja on contas_series (loja_id, status);
create index if not exists idx_series_criado_por on contas_series (criado_por);
alter table contas_series enable row level security;
revoke all on contas_series from public, anon, authenticated;

alter table financeiro_lancamentos add column if not exists serie_id uuid references contas_series(id);
alter table financeiro_lancamentos add column if not exists serie_n integer;               -- 1, 2, 3…
alter table financeiro_lancamentos add column if not exists vencimento_ref date;           -- data pela regra da série (não muda se a ocorrência for adiada)
alter table financeiro_lancamentos add column if not exists serie_editada boolean not null default false;
create unique index if not exists uq_fin_serie_n on financeiro_lancamentos (serie_id, serie_n) where serie_id is not null;
create index if not exists idx_fin_serie on financeiro_lancamentos (serie_id);

-- ---------- data da k-ésima ocorrência (k começa em 0), sempre a partir da referência original ----------
create or replace function serie_data(p_inicio date, p_unidade text, p_intervalo integer, p_k integer) returns date
language plpgsql immutable set search_path = public as $tag_serie_data$
declare m date; ultimo date;
begin
  if p_unidade = 'dia' then return p_inicio + p_k * p_intervalo;
  elsif p_unidade = 'semana' then return p_inicio + 7 * p_k * p_intervalo;
  elsif p_unidade in ('mes','ano') then
    m := (date_trunc('month', p_inicio) + make_interval(months => p_k * p_intervalo * case p_unidade when 'ano' then 12 else 1 end))::date;
    ultimo := (m + interval '1 month - 1 day')::date;
    return least(m + (extract(day from p_inicio)::int - 1), ultimo);
  end if;
  raise exception 'Unidade inválida';
end;
$tag_serie_data$;

create or replace function serie_regra(p_frequencia text, p_intervalo integer, p_unidade text, out o_intervalo integer, out o_unidade text) returns record
language plpgsql immutable set search_path = public as $tag_serie_regra$
begin
  case p_frequencia
    when 'semanal' then o_intervalo := 1; o_unidade := 'semana';
    when 'quinzenal' then o_intervalo := 15; o_unidade := 'dia';
    when 'mensal' then o_intervalo := 1; o_unidade := 'mes';
    when 'anual' then o_intervalo := 1; o_unidade := 'ano';
    when 'personalizada' then
      if p_unidade not in ('dia','semana','mes','ano') then raise exception 'Escolha a unidade do intervalo (dias, semanas, meses ou anos)'; end if;
      if p_intervalo is null or p_intervalo < 1 or p_intervalo > 365 then raise exception 'O intervalo deve ser de 1 a 365'; end if;
      o_intervalo := p_intervalo; o_unidade := p_unidade;
    else raise exception 'Frequência inválida';
  end case;
end;
$tag_serie_regra$;

-- ---------- prévia (não grava nada) ----------
create or replace function serie_previa(p_frequencia text, p_intervalo integer, p_unidade text, p_inicio date, p_fim_tipo text, p_fim_data date, p_fim_qtd integer, p_limite integer default 12) returns jsonb
language plpgsql stable security definer set search_path = public as $tag_serie_previa$
declare r record; k integer := 0; d date; arr jsonb := '[]'::jsonb; lim integer := least(greatest(coalesce(p_limite, 12), 1), 36); mais boolean := false;
begin
  if not perfil_ativo() then raise exception 'Sem permissão'; end if;
  if p_inicio is null then raise exception 'Informe o primeiro vencimento'; end if;
  if p_fim_tipo not in ('sem_prazo','data','quantidade') then raise exception 'Término inválido'; end if;
  if p_fim_tipo = 'data' and (p_fim_data is null or p_fim_data < p_inicio) then raise exception 'A data final precisa ser igual ou posterior ao primeiro vencimento'; end if;
  if p_fim_tipo = 'quantidade' and (p_fim_qtd is null or p_fim_qtd < 1 or p_fim_qtd > 120) then raise exception 'A quantidade deve ser de 1 a 120'; end if;
  select * into r from serie_regra(p_frequencia, p_intervalo, p_unidade);
  loop
    d := serie_data(p_inicio, r.o_unidade, r.o_intervalo, k);
    exit when (p_fim_tipo = 'data' and d > p_fim_data) or (p_fim_tipo = 'quantidade' and k >= p_fim_qtd);
    if k >= lim then mais := true; exit; end if;
    arr := arr || jsonb_build_object('n', k + 1, 'vencimento', d,
        'ajustada', r.o_unidade in ('mes','ano') and extract(day from d) <> extract(day from p_inicio));
    k := k + 1;
    exit when k > 2000;
  end loop;
  return jsonb_build_object('datas', arr, 'tem_mais', mais);
end;
$tag_serie_previa$;

-- ---------- gerador interno (idempotente; chamado com a série já travada) ----------
create or replace function serie_gerar(p_id uuid) returns integer
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
    if fim then update contas_series set status = 'encerrada', atualizado_em = now() where id = s.id; return feitas; end if;
    exit when feitas >= 24 or (d > v_lim and k > 0);
    insert into financeiro_lancamentos (loja_id, tipo, categoria, descricao, valor, forma_pagamento, status, vencimento, vencimento_ref, exige_comprovante, criado_por, serie_id, serie_n)
    values (s.loja_id, s.tipo, s.categoria, s.descricao, s.valor, s.forma_pagamento, 'pendente', d, d, s.exige_comprovante, s.criado_por, s.id, k + 1)
    on conflict (serie_id, serie_n) where serie_id is not null do nothing returning id into v_id;
    if v_id is not null then
      insert into financeiro_auditoria (lancamento_id, loja_id, acao, por, detalhes) values (v_id, s.loja_id, 'conta_criada', auth.uid(), jsonb_build_object('serie_id', s.id, 'n', k + 1, 'vencimento', d, 'valor', s.valor));
      feitas := feitas + 1; v_id := null;
    end if;
    s.proximo_k := k + 1;
    update contas_series set proximo_k = s.proximo_k, atualizado_em = now() where id = s.id;
  end loop;
  return feitas;
end;
$tag_serie_gerar$;

create or replace function criar_serie(p_loja_id uuid, p_tipo text, p_categoria text, p_descricao text, p_valor numeric, p_forma text, p_exige_comprovante boolean,
  p_frequencia text, p_intervalo integer, p_unidade text, p_inicio date, p_fim_tipo text, p_fim_data date, p_fim_qtd integer, p_chave uuid) returns jsonb
language plpgsql security definer set search_path = public as $tag_criar_serie$
declare r record; v_id uuid; v_n integer;
begin
  if not tenho_acesso_a_loja(p_loja_id) then raise exception 'Você não tem permissão para esta loja'; end if;
  if p_chave is null then raise exception 'Chave de repetição obrigatória'; end if;
  if p_tipo not in ('entrada','saida') then raise exception 'Tipo inválido'; end if;
  if nullif(trim(coalesce(p_categoria, '')), '') is null or lower(trim(p_categoria)) in ('venda','estorno') then raise exception 'Categoria inválida'; end if;
  perform valida_valor(p_valor);
  perform serie_previa(p_frequencia, p_intervalo, p_unidade, p_inicio, p_fim_tipo, p_fim_data, p_fim_qtd, 1);   -- valida regra e término
  select * into r from serie_regra(p_frequencia, p_intervalo, p_unidade);
  perform pg_advisory_xact_lock(hashtext('serie_nova:' || auth.uid()::text || p_chave::text));
  select id into v_id from contas_series where criado_por = auth.uid() and chave_criacao = p_chave;
  if v_id is not null then return jsonb_build_object('serie_id', v_id, 'geradas', 0, 'repetida', true); end if;
  insert into contas_series (loja_id, tipo, categoria, descricao, valor, forma_pagamento, exige_comprovante, frequencia, intervalo, unidade, inicio, fim_tipo, fim_data, fim_qtd, criado_por, chave_criacao)
  values (p_loja_id, p_tipo, trim(p_categoria), nullif(trim(coalesce(p_descricao, '')), ''), p_valor, nullif(trim(coalesce(p_forma, '')), ''), coalesce(p_exige_comprovante, false),
          p_frequencia, r.o_intervalo, r.o_unidade, p_inicio, p_fim_tipo, case when p_fim_tipo = 'data' then p_fim_data end, case when p_fim_tipo = 'quantidade' then p_fim_qtd end, auth.uid(), p_chave)
  returning id into v_id;
  insert into financeiro_auditoria (loja_id, acao, por, detalhes) values (p_loja_id, 'serie_criada', auth.uid(), jsonb_build_object('serie_id', v_id, 'frequencia', p_frequencia, 'inicio', p_inicio, 'valor', p_valor));
  v_n := serie_gerar(v_id);
  return jsonb_build_object('serie_id', v_id, 'geradas', v_n, 'repetida', false);
end;
$tag_criar_serie$;

-- geração sob demanda para as séries ativas de UMA loja (a tela chama ao abrir o Financeiro)
create or replace function gerar_series_loja(p_loja_id uuid) returns integer
language plpgsql security definer set search_path = public as $tag_gerar_series_loja$
declare s record; n integer := 0;
begin
  if not pode_ver_loja(p_loja_id) then raise exception 'Você não tem permissão para esta loja'; end if;
  for s in select id from contas_series where loja_id = p_loja_id and status = 'ativa' order by criado_em loop n := n + serie_gerar(s.id); end loop;
  return n;
end;
$tag_gerar_series_loja$;

-- para o agendador (pg_cron / Edge Function com service_role): todas as séries ativas
create or replace function gerar_series_pendentes() returns integer
language plpgsql security definer set search_path = public as $tag_gerar_series_pendentes$
declare s record; n integer := 0;
begin
  for s in select id from contas_series where status = 'ativa' order by criado_em loop n := n + serie_gerar(s.id); end loop;
  return n;
end;
$tag_gerar_series_pendentes$;

-- ---------- controle da série ----------
create or replace function serie_controlar(p_id uuid, p_acao text, p_cancelar_futuras boolean default false, p_motivo text default null) returns jsonb
language plpgsql security definer set search_path = public as $tag_serie_controlar$
declare s contas_series%rowtype; v_hoje date := (now() at time zone 'America/Sao_Paulo')::date; v_pul integer := 0; k integer; v_canc integer := 0; l record;
begin
  perform pg_advisory_xact_lock(hashtext('serie:' || p_id::text));
  select * into s from contas_series where id = p_id for update;
  if s.id is null then raise exception 'Série não encontrada'; end if;
  if not pode_gerir_loja(s.loja_id) then raise exception 'Só gerente ou dono controla séries'; end if;
  if p_acao not in ('pausar','retomar','encerrar') then raise exception 'Ação inválida'; end if;
  if s.status = 'encerrada' then raise exception 'Esta série já foi encerrada'; end if;
  if p_acao = 'pausar' then
    if s.status = 'pausada' then return jsonb_build_object('status', 'pausada'); end if;
    update contas_series set status = 'pausada', atualizado_em = now() where id = s.id;
    insert into financeiro_auditoria (loja_id, acao, por, motivo, detalhes) values (s.loja_id, 'serie_pausada', auth.uid(), nullif(trim(coalesce(p_motivo, '')), ''), jsonb_build_object('serie_id', s.id));
  elsif p_acao = 'retomar' then
    if s.status = 'ativa' then return jsonb_build_object('status', 'ativa'); end if;
    k := s.proximo_k;   -- pula o que já venceu durante a pausa (não gera conta no passado)
    while serie_data(s.inicio, s.unidade, s.intervalo, k) < v_hoje
          and not ((s.fim_tipo = 'quantidade' and k >= s.fim_qtd) or (s.fim_tipo = 'data' and serie_data(s.inicio, s.unidade, s.intervalo, k) > s.fim_data)) loop k := k + 1; v_pul := v_pul + 1; end loop;
    update contas_series set status = 'ativa', proximo_k = k, puladas = puladas + v_pul, atualizado_em = now() where id = s.id;
    insert into financeiro_auditoria (loja_id, acao, por, detalhes) values (s.loja_id, 'serie_retomada', auth.uid(), jsonb_build_object('serie_id', s.id, 'puladas', v_pul));
    perform serie_gerar(s.id);
  else
    update contas_series set status = 'encerrada', atualizado_em = now() where id = s.id;
    if coalesce(p_cancelar_futuras, false) then
      for l in select id from financeiro_lancamentos f where f.serie_id = s.id and f.status = 'pendente' and f.vencimento >= v_hoje and not f.serie_editada
                  and not exists (select 1 from pagamentos_lancamento p where p.lancamento_id = f.id) order by f.vencimento loop
        perform cancelar_conta(l.id, coalesce(nullif(trim(coalesce(p_motivo, '')), ''), 'Série encerrada')); v_canc := v_canc + 1;
      end loop;
    end if;
    insert into financeiro_auditoria (loja_id, acao, por, motivo, detalhes) values (s.loja_id, 'serie_encerrada', auth.uid(), nullif(trim(coalesce(p_motivo, '')), ''), jsonb_build_object('serie_id', s.id, 'canceladas', v_canc));
  end if;
  return jsonb_build_object('status', (select status from contas_series where id = s.id), 'puladas', v_pul, 'canceladas', v_canc);
end;
$tag_serie_controlar$;

-- ---------- edição de conta: só esta ocorrência ou esta e as próximas ----------
create or replace function editar_conta(p_id uuid, p_escopo text, p_descricao text, p_categoria text, p_valor numeric, p_vencimento date, p_forma text, p_exige_comprovante boolean) returns jsonb
language plpgsql security definer set search_path = public as $tag_editar_conta$
declare l financeiro_lancamentos%rowtype; s contas_series%rowtype; f record; v_alt integer := 0; v_pres integer := 0; v_mov boolean;
begin
  select * into l from financeiro_lancamentos where id = p_id for update;
  if l.id is null then raise exception 'Conta não encontrada'; end if;
  if not pode_gerir_loja(l.loja_id) then raise exception 'Só gerente ou dono edita contas'; end if;
  if l.venda_id is not null or lower(l.categoria) in ('venda','estorno') then raise exception 'Lançamentos de venda não são editados por aqui'; end if;
  if p_escopo not in ('esta','proximas') then raise exception 'Escopo inválido'; end if;
  if p_escopo = 'proximas' and l.serie_id is null then raise exception 'Esta conta não pertence a uma série'; end if;
  if nullif(trim(coalesce(p_categoria, '')), '') is null or lower(trim(p_categoria)) in ('venda','estorno') then raise exception 'Categoria inválida'; end if;
  perform valida_valor(p_valor);
  v_mov := l.status in ('pago','parcial','cancelada') or exists (select 1 from pagamentos_lancamento where lancamento_id = l.id);
  if l.status = 'cancelada' then raise exception 'Conta cancelada não pode ser editada'; end if;
  if p_escopo = 'esta' and v_mov and (p_valor <> l.valor or coalesce(p_exige_comprovante, false) <> l.exige_comprovante) then raise exception 'Conta com pagamentos: só descrição, categoria e vencimento podem mudar (estorne os pagamentos para alterar o valor)'; end if;
  if p_escopo = 'esta' then
    update financeiro_lancamentos set descricao = nullif(trim(coalesce(p_descricao, '')), ''), categoria = trim(p_categoria), valor = p_valor, vencimento = coalesce(p_vencimento, vencimento),
           forma_pagamento = nullif(trim(coalesce(p_forma, '')), ''), exige_comprovante = coalesce(p_exige_comprovante, false), serie_editada = (l.serie_id is not null) where id = l.id;
    perform fin_audit(l.id, null, l.loja_id, 'conta_editada', null, jsonb_build_object('antes', jsonb_build_object('valor', l.valor, 'vencimento', l.vencimento, 'categoria', l.categoria), 'depois', jsonb_build_object('valor', p_valor, 'vencimento', coalesce(p_vencimento, l.vencimento), 'categoria', trim(p_categoria)), 'escopo', 'esta'));
    return jsonb_build_object('alteradas', 1, 'preservadas', 0);
  end if;
  -- esta e as próximas: atualiza o modelo da série e as ocorrências ainda intocadas (pendentes, sem pagamentos, não editadas à mão)
  select * into s from contas_series where id = l.serie_id for update;
  update contas_series set descricao = nullif(trim(coalesce(p_descricao, '')), ''), categoria = trim(p_categoria), valor = p_valor, forma_pagamento = nullif(trim(coalesce(p_forma, '')), ''),
         exige_comprovante = coalesce(p_exige_comprovante, false), atualizado_em = now() where id = s.id;
  for f in select * from financeiro_lancamentos where serie_id = s.id and serie_n >= l.serie_n order by serie_n for update loop
    if f.status = 'pendente' and not f.serie_editada and not exists (select 1 from pagamentos_lancamento where lancamento_id = f.id) then
      update financeiro_lancamentos set descricao = nullif(trim(coalesce(p_descricao, '')), ''), categoria = trim(p_categoria), valor = p_valor, forma_pagamento = nullif(trim(coalesce(p_forma, '')), ''),
             exige_comprovante = coalesce(p_exige_comprovante, false) where id = f.id;
      v_alt := v_alt + 1;
    else v_pres := v_pres + 1; end if;
  end loop;
  insert into financeiro_auditoria (lancamento_id, loja_id, acao, por, detalhes) values (l.id, l.loja_id, 'serie_editada', auth.uid(), jsonb_build_object('serie_id', s.id, 'a_partir_de', l.serie_n, 'alteradas', v_alt, 'preservadas', v_pres, 'valor', p_valor));
  return jsonb_build_object('alteradas', v_alt, 'preservadas', v_pres);
end;
$tag_editar_conta$;

-- ---------- leitura ----------
create or replace function listar_series(p_loja_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $tag_listar_series$
begin
  if not pode_ver_loja(p_loja_id) then raise exception 'Você não tem permissão para esta loja'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'tipo', s.tipo, 'categoria', s.categoria, 'descricao', s.descricao, 'valor', s.valor, 'frequencia', s.frequencia,
      'intervalo', s.intervalo, 'unidade', s.unidade, 'inicio', s.inicio, 'fim_tipo', s.fim_tipo, 'fim_data', s.fim_data, 'fim_qtd', s.fim_qtd, 'status', s.status, 'puladas', s.puladas,
      'geradas', (select count(*) from financeiro_lancamentos f where f.serie_id = s.id),
      'proximo_vencimento', (select min(f.vencimento) from financeiro_lancamentos f where f.serie_id = s.id and f.status in ('pendente','parcial')),
      'criado_por_nome', (select nome from perfis where id = s.criado_por), 'criado_em', s.criado_em, 'pode_gerir', pode_gerir_loja(s.loja_id)) order by s.status, s.criado_em desc), '[]'::jsonb)
    from contas_series s where s.loja_id = p_loja_id);
end;
$tag_listar_series$;

-- listar_contas passa a informar a série de cada conta (mesma função da 005, mais 3 campos; nada mais muda)
do $mig$
declare def text;
begin
  select pg_get_functiondef('public.listar_contas(uuid,date,date,text)'::regprocedure) into def;
  if def not like '%serie_id%' then
    def := replace(def, '''legado'', (not c.tem_pag and c.status = ''pago''), ''venda_id'', c.venda_id)', '''legado'', (not c.tem_pag and c.status = ''pago''), ''venda_id'', c.venda_id, ''serie_id'', c.serie_id, ''serie_n'', c.serie_n, ''serie_editada'', c.serie_editada)');
    if def not like '%serie_id%' then raise exception 'Não foi possível estender listar_contas'; end if;
    execute def;
  end if;
end
$mig$;

revoke execute on function public.serie_data(date, text, integer, integer), public.serie_regra(text, integer, text), public.serie_gerar(uuid), public.gerar_series_pendentes() from public, anon, authenticated;
revoke execute on function public.serie_previa(text, integer, text, date, text, date, integer, integer), public.criar_serie(uuid, text, text, text, numeric, text, boolean, text, integer, text, date, text, date, integer, uuid),
  public.gerar_series_loja(uuid), public.serie_controlar(uuid, text, boolean, text), public.editar_conta(uuid, text, text, text, numeric, date, text, boolean), public.listar_series(uuid) from public, anon;

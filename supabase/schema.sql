-- ============================================================
-- SMOKE CLUB — Painel multi-loja (estoque compartilhado + financeiro)
-- Execute este arquivo inteiro no SQL Editor do seu projeto Supabase.
-- ============================================================

create extension if not exists pgcrypto;

-- ============ LOJAS ============
create table lojas (
  id uuid primary key default gen_random_uuid(),
  nome text not null,
  slug text unique not null,
  whatsapp text,
  ativo boolean not null default true,
  criado_em timestamptz not null default now()
);

-- Perfil de cada usuário (funcionário) — vincula o login à loja dele
create table perfis (
  id uuid primary key references auth.users(id) on delete cascade,
  loja_id uuid not null references lojas(id),
  nome text,
  papel text not null default 'operador' check (papel in ('operador','gerente','dono')),
  criado_em timestamptz not null default now()
);

create or replace function loja_atual() returns uuid
language sql stable security definer set search_path = public as $tag_loja_atual$
  select loja_id from perfis where id = auth.uid()
$tag_loja_atual$;

create or replace function eh_dono() returns boolean
language sql stable security definer set search_path = public as $tag_eh_dono$
  select coalesce((select papel = 'dono' from perfis where id = auth.uid()), false)
$tag_eh_dono$;

-- ============ CATÁLOGO (compartilhado entre as 4 lojas) ============
create table categorias (
  id uuid primary key default gen_random_uuid(),
  nome text unique not null,
  cor text default 'fogo',
  ordem int default 0
);

create table marcas (
  id uuid primary key default gen_random_uuid(),
  nome text not null,
  descricao text,
  cor_fita text, cor_grad_a text, cor_grad_b text, cor_fundo text,
  ativo boolean not null default true,
  ordem int default 0
);

-- "item" = um produto avulso (tipo='produto', usa categoria_id) ou um modelo de marca (tipo='modelo', usa marca_id)
create table itens (
  id uuid primary key default gen_random_uuid(),
  tipo text not null check (tipo in ('produto','modelo')),
  marca_id uuid references marcas(id) on delete cascade,
  categoria_id uuid references categorias(id) on delete set null,
  nome text not null,
  descricao text,
  emoji text,
  imagem_url text,
  ativo boolean not null default true,
  destaque boolean not null default false,
  ordem int default 0,
  criado_em timestamptz not null default now(),
  constraint chk_item_dono check (
    (tipo = 'produto' and marca_id is null) or
    (tipo = 'modelo' and categoria_id is null and marca_id is not null)
  )
);

create table sabores (
  id uuid primary key default gen_random_uuid(),
  item_id uuid not null references itens(id) on delete cascade,
  nome text not null,
  ordem int default 0
);

-- ============ ESTOQUE (compartilhado — o coração do sistema) ============
-- uma linha por item (sabor_id null) ou por combinação item+sabor
create table estoque (
  id uuid primary key default gen_random_uuid(),
  item_id uuid not null references itens(id) on delete cascade,
  sabor_id uuid references sabores(id) on delete cascade,
  quantidade int not null default 0 check (quantidade >= 0),
  estoque_minimo int not null default 3,
  atualizado_em timestamptz not null default now(),
  unique (item_id, sabor_id)
);
-- índice p/ permitir unique com null em sabor_id (duas linhas item_id+null seriam "iguais" sem isso)
create unique index estoque_item_sem_sabor on estoque(item_id) where sabor_id is null;

create table estoque_movimentos (
  id uuid primary key default gen_random_uuid(),
  estoque_id uuid not null references estoque(id),
  loja_id uuid references lojas(id),
  tipo text not null check (tipo in ('venda','entrada','ajuste','estorno')),
  quantidade int not null,
  saldo_resultante int not null,
  venda_id uuid,
  observacao text,
  criado_em timestamptz not null default now(),
  criado_por uuid references perfis(id)
);

-- ============ PREÇOS POR LOJA (cada loja define o próprio preço) ============
create table precos_loja (
  loja_id uuid not null references lojas(id) on delete cascade,
  item_id uuid not null references itens(id) on delete cascade,
  preco numeric(10,2) not null,
  preco_de numeric(10,2),
  ativo boolean not null default true,
  primary key (loja_id, item_id)
);

-- ============ CLIENTES (histórico separado por loja) ============
create table clientes (
  id uuid primary key default gen_random_uuid(),
  loja_id uuid not null references lojas(id),
  nome text not null,
  telefone text,
  endereco text,
  observacoes text,
  criado_em timestamptz not null default now(),
  unique (loja_id, telefone)
);

-- ============ VENDAS ============
create table vendas (
  id uuid primary key default gen_random_uuid(),
  loja_id uuid not null references lojas(id),
  cliente_id uuid references clientes(id),
  forma_pagamento text,
  subtotal numeric(10,2) not null,
  desconto numeric(10,2) not null default 0,
  total numeric(10,2) not null,
  status text not null default 'concluida' check (status in ('concluida','cancelada')),
  criado_em timestamptz not null default now(),
  criado_por uuid references perfis(id)
);

create table venda_itens (
  id uuid primary key default gen_random_uuid(),
  venda_id uuid not null references vendas(id) on delete cascade,
  item_id uuid not null references itens(id),
  sabor_id uuid references sabores(id),
  nome_snapshot text not null,
  quantidade int not null,
  preco_unitario numeric(10,2) not null
);

-- ============ FINANCEIRO ============
create table financeiro_lancamentos (
  id uuid primary key default gen_random_uuid(),
  loja_id uuid references lojas(id),
  tipo text not null check (tipo in ('entrada','saida')),
  categoria text not null default 'outro',
  descricao text,
  valor numeric(10,2) not null,
  forma_pagamento text,
  status text not null default 'pago' check (status in ('pago','pendente','atrasado')),
  vencimento date,
  venda_id uuid references vendas(id),
  criado_em timestamptz not null default now(),
  criado_por uuid references perfis(id)
);

-- ============================================================
-- RPCs — únicos caminhos que alteram estoque (garante consistência)
-- ============================================================

-- Registra uma venda: valida e trava estoque linha a linha, debita, grava venda,
-- itens, movimentação de estoque e lançamento financeiro — tudo em uma transação.
-- Se QUALQUER item não tiver estoque suficiente, a função inteira falha e nada é gravado.
create or replace function registrar_venda(
  p_itens jsonb,
  p_cliente jsonb default null,
  p_forma_pagamento text default null,
  p_desconto numeric default 0
) returns uuid
language plpgsql security definer set search_path = public as $tag_registrar_venda$
declare
  v_loja_id uuid := loja_atual();
  v_venda_id uuid;
  v_cliente_id uuid;
  v_subtotal numeric := 0;
  v_total numeric;
  v_item jsonb;
  v_estoque_id uuid;
  v_qtd int;
  v_saldo int;
begin
  if v_loja_id is null then
    raise exception 'Usuário sem loja associada';
  end if;

  if p_cliente is not null and coalesce(p_cliente->>'telefone','') <> '' then
    insert into clientes (loja_id, nome, telefone, endereco)
    values (v_loja_id, p_cliente->>'nome', p_cliente->>'telefone', p_cliente->>'endereco')
    on conflict (loja_id, telefone) do update
      set nome = excluded.nome, endereco = coalesce(excluded.endereco, clientes.endereco)
    returning id into v_cliente_id;
  end if;

  for v_item in select * from jsonb_array_elements(p_itens) loop
    v_qtd := (v_item->>'quantidade')::int;
    if v_qtd is null or v_qtd <= 0 then
      raise exception 'Quantidade inválida para "%"', v_item->>'nome';
    end if;

    select id into v_estoque_id from estoque
      where item_id = (v_item->>'item_id')::uuid
        and sabor_id is not distinct from nullif(v_item->>'sabor_id','')::uuid
      for update;

    if v_estoque_id is null then
      raise exception 'Item sem registro de estoque: %', v_item->>'nome';
    end if;

    update estoque set quantidade = quantidade - v_qtd, atualizado_em = now()
      where id = v_estoque_id and quantidade >= v_qtd
      returning quantidade into v_saldo;

    if v_saldo is null then
      raise exception 'Estoque insuficiente para "%" (pedido: % un.)', v_item->>'nome', v_qtd;
    end if;

    v_subtotal := v_subtotal + v_qtd * (v_item->>'preco_unitario')::numeric;
  end loop;

  v_total := v_subtotal - coalesce(p_desconto,0);
  if v_total < 0 then
    raise exception 'Desconto maior que o subtotal';
  end if;

  insert into vendas (loja_id, cliente_id, forma_pagamento, subtotal, desconto, total, criado_por)
  values (v_loja_id, v_cliente_id, p_forma_pagamento, v_subtotal, coalesce(p_desconto,0), v_total, auth.uid())
  returning id into v_venda_id;

  for v_item in select * from jsonb_array_elements(p_itens) loop
    insert into venda_itens (venda_id, item_id, sabor_id, nome_snapshot, quantidade, preco_unitario)
    values (v_venda_id, (v_item->>'item_id')::uuid, nullif(v_item->>'sabor_id','')::uuid,
            v_item->>'nome', (v_item->>'quantidade')::int, (v_item->>'preco_unitario')::numeric);

    select e.id, e.quantidade into v_estoque_id, v_saldo from estoque e
      where e.item_id = (v_item->>'item_id')::uuid
        and e.sabor_id is not distinct from nullif(v_item->>'sabor_id','')::uuid;

    insert into estoque_movimentos (estoque_id, loja_id, tipo, quantidade, saldo_resultante, venda_id, criado_por)
    values (v_estoque_id, v_loja_id, 'venda', -((v_item->>'quantidade')::int), v_saldo, v_venda_id, auth.uid());
  end loop;

  insert into financeiro_lancamentos (loja_id, tipo, categoria, descricao, valor, forma_pagamento, status, venda_id, criado_por)
  values (v_loja_id, 'entrada', 'venda', 'Venda #' || substr(v_venda_id::text,1,8), v_total, p_forma_pagamento, 'pago', v_venda_id, auth.uid());

  return v_venda_id;
end;
$tag_registrar_venda$;

-- Cancela uma venda já registrada: estorna o estoque e lança uma saída financeira de estorno.
create or replace function cancelar_venda(p_venda_id uuid) returns void
language plpgsql security definer set search_path = public as $tag_cancelar_venda$
declare
  v_loja_id uuid := loja_atual();
  v_venda vendas%rowtype;
  v_item venda_itens%rowtype;
  v_estoque_id uuid;
  v_saldo int;
begin
  select * into v_venda from vendas where id = p_venda_id;
  if v_venda is null then raise exception 'Venda não encontrada'; end if;
  if v_venda.loja_id <> v_loja_id and not eh_dono() then
    raise exception 'Você não pode cancelar vendas de outra loja';
  end if;
  if v_venda.status = 'cancelada' then
    raise exception 'Venda já está cancelada';
  end if;

  for v_item in select * from venda_itens where venda_id = p_venda_id loop
    select id into v_estoque_id from estoque
      where item_id = v_item.item_id and sabor_id is not distinct from v_item.sabor_id
      for update;

    update estoque set quantidade = quantidade + v_item.quantidade, atualizado_em = now()
      where id = v_estoque_id
      returning quantidade into v_saldo;

    insert into estoque_movimentos (estoque_id, loja_id, tipo, quantidade, saldo_resultante, venda_id, criado_por)
    values (v_estoque_id, v_venda.loja_id, 'estorno', v_item.quantidade, v_saldo, p_venda_id, auth.uid());
  end loop;

  update vendas set status = 'cancelada' where id = p_venda_id;

  insert into financeiro_lancamentos (loja_id, tipo, categoria, descricao, valor, status, venda_id, criado_por)
  values (v_venda.loja_id, 'saida', 'estorno', 'Estorno da venda #' || substr(p_venda_id::text,1,8), v_venda.total, 'pago', p_venda_id, auth.uid());
end;
$tag_cancelar_venda$;

-- Entrada/ajuste manual de estoque (reposição de mercadoria, contagem, etc.)
create or replace function ajustar_estoque(p_estoque_id uuid, p_quantidade int, p_observacao text default null)
returns int language plpgsql security definer set search_path = public as $tag_ajustar_estoque$
declare v_saldo int;
begin
  if p_quantidade = 0 then raise exception 'Quantidade de ajuste não pode ser zero'; end if;

  update estoque set quantidade = quantidade + p_quantidade, atualizado_em = now()
    where id = p_estoque_id and quantidade + p_quantidade >= 0
    returning quantidade into v_saldo;

  if v_saldo is null then
    raise exception 'Esse ajuste deixaria o estoque negativo';
  end if;

  insert into estoque_movimentos(estoque_id, loja_id, tipo, quantidade, saldo_resultante, observacao, criado_por)
  values (p_estoque_id, loja_atual(), case when p_quantidade > 0 then 'entrada' else 'ajuste' end, p_quantidade, v_saldo, p_observacao, auth.uid());

  return v_saldo;
end;
$tag_ajustar_estoque$;

-- ============================================================
-- RLS (idempotente: pode ser rodado de novo sem erro caso uma
-- execução anterior tenha parado no meio)
-- ============================================================
alter table lojas enable row level security;
alter table perfis enable row level security;
alter table categorias enable row level security;
alter table marcas enable row level security;
alter table itens enable row level security;
alter table sabores enable row level security;
alter table estoque enable row level security;
alter table estoque_movimentos enable row level security;
alter table precos_loja enable row level security;
alter table clientes enable row level security;
alter table vendas enable row level security;
alter table venda_itens enable row level security;
alter table financeiro_lancamentos enable row level security;

drop policy if exists "leitura autenticada" on lojas;
drop policy if exists "leitura propria" on perfis;
drop policy if exists "leitura autenticada" on categorias;
drop policy if exists "leitura autenticada" on marcas;
drop policy if exists "leitura autenticada" on itens;
drop policy if exists "leitura autenticada" on sabores;
drop policy if exists "leitura autenticada" on estoque;
drop policy if exists "leitura autenticada" on estoque_movimentos;
drop policy if exists "escrita gerente" on categorias;
drop policy if exists "escrita gerente" on marcas;
drop policy if exists "escrita gerente" on itens;
drop policy if exists "escrita gerente" on sabores;
drop policy if exists "sem escrita direta" on estoque;
drop policy if exists "sem update direto" on estoque;
drop policy if exists "precos por loja" on precos_loja;
drop policy if exists "precos escrita propria" on precos_loja;
drop policy if exists "precos update propria" on precos_loja;
drop policy if exists "precos delete propria" on precos_loja;
drop policy if exists "clientes por loja" on clientes;
drop policy if exists "clientes escrita propria" on clientes;
drop policy if exists "clientes update propria" on clientes;
drop policy if exists "vendas por loja" on vendas;
drop policy if exists "venda_itens por loja" on venda_itens;
drop policy if exists "financeiro por loja" on financeiro_lancamentos;
drop policy if exists "financeiro escrita propria" on financeiro_lancamentos;
drop policy if exists "financeiro update propria" on financeiro_lancamentos;

-- todo usuário autenticado (funcionário de alguma das 4 lojas) enxerga o catálogo/estoque compartilhado
create policy "leitura autenticada" on lojas for select using (auth.role() = 'authenticated');
create policy "leitura propria" on perfis for select using (id = auth.uid());
create policy "leitura autenticada" on categorias for select using (auth.role() = 'authenticated');
create policy "leitura autenticada" on marcas for select using (auth.role() = 'authenticated');
create policy "leitura autenticada" on itens for select using (auth.role() = 'authenticated');
create policy "leitura autenticada" on sabores for select using (auth.role() = 'authenticated');
create policy "leitura autenticada" on estoque for select using (auth.role() = 'authenticated');
create policy "leitura autenticada" on estoque_movimentos for select using (auth.role() = 'authenticated');

-- catálogo/estoque só é escrito pelos RPCs (security definer) ou por gerente/dono
create policy "escrita gerente" on categorias for all using (
  exists (select 1 from perfis where id = auth.uid() and papel in ('gerente','dono'))
);
create policy "escrita gerente" on marcas for all using (
  exists (select 1 from perfis where id = auth.uid() and papel in ('gerente','dono'))
);
create policy "escrita gerente" on itens for all using (
  exists (select 1 from perfis where id = auth.uid() and papel in ('gerente','dono'))
);
create policy "escrita gerente" on sabores for all using (
  exists (select 1 from perfis where id = auth.uid() and papel in ('gerente','dono'))
);
-- estoque (quantidade) só muda via RPC (security definer roda como dono da função, ignora RLS de escrita normal)
create policy "sem escrita direta" on estoque for insert with check (
  exists (select 1 from perfis where id = auth.uid() and papel in ('gerente','dono'))
);
create policy "sem update direto" on estoque for update using (
  exists (select 1 from perfis where id = auth.uid() and papel in ('gerente','dono'))
);

-- preços: cada loja só vê/edita o próprio preço; dono vê todos
create policy "precos por loja" on precos_loja for select using (loja_id = loja_atual() or eh_dono());
create policy "precos escrita propria" on precos_loja for insert with check (loja_id = loja_atual());
create policy "precos update propria" on precos_loja for update using (loja_id = loja_atual());
create policy "precos delete propria" on precos_loja for delete using (loja_id = loja_atual());

-- clientes: histórico isolado por loja (dono enxerga tudo)
create policy "clientes por loja" on clientes for select using (loja_id = loja_atual() or eh_dono());
create policy "clientes escrita propria" on clientes for insert with check (loja_id = loja_atual());
create policy "clientes update propria" on clientes for update using (loja_id = loja_atual());

-- vendas: isoladas por loja (dono enxerga tudo) — inserção real só acontece via RPC, mas mantemos policy coerente
create policy "vendas por loja" on vendas for select using (loja_id = loja_atual() or eh_dono());
create policy "venda_itens por loja" on venda_itens for select using (
  exists (select 1 from vendas v where v.id = venda_id and (v.loja_id = loja_atual() or eh_dono()))
);

-- financeiro: isolado por loja (dono enxerga tudo); lançamentos manuais (despesas) qualquer operador da própria loja pode criar
create policy "financeiro por loja" on financeiro_lancamentos for select using (loja_id = loja_atual() or eh_dono());
create policy "financeiro escrita propria" on financeiro_lancamentos for insert with check (loja_id = loja_atual());
create policy "financeiro update propria" on financeiro_lancamentos for update using (loja_id = loja_atual() or eh_dono());

-- ============================================================
-- Realtime — estoque, vendas e financeiro atualizam ao vivo nas 4 lojas
-- ============================================================
do $tag_realtime_setup$
begin
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='estoque') then
    alter publication supabase_realtime add table estoque;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='vendas') then
    alter publication supabase_realtime add table vendas;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='financeiro_lancamentos') then
    alter publication supabase_realtime add table financeiro_lancamentos;
  end if;
end
$tag_realtime_setup$;

-- ============================================================
-- Seed inicial das 4 lojas (ajuste os nomes/whatsapp conforme necessário)
-- ============================================================
insert into lojas (nome, slug, whatsapp) values
  ('Loja 1', 'loja-1', null),
  ('Loja 2', 'loja-2', null),
  ('Loja 3', 'loja-3', null),
  ('Loja 4', 'loja-4', null)
on conflict (slug) do nothing;

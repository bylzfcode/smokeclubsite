-- ============================================================
-- 002 — Melhorias de integridade e funções do painel
-- Rode DEPOIS do schema.sql. Pode ser rodado mais de uma vez.
-- ============================================================

-- ---------- 1) Colunas, regras e índices ----------
alter table vendas
  add column if not exists cliente_nome text,
  add column if not exists cancelada_em timestamptz,
  add column if not exists cancelada_por uuid references perfis(id),
  add column if not exists motivo_cancelamento text,
  add column if not exists chave_idempotencia uuid;
-- chave única por tentativa de venda: reenviar a mesma venda (clique duplo, internet que caiu)
-- devolve a venda já feita em vez de vender de novo
create unique index if not exists vendas_chave_unica on vendas (loja_id, chave_idempotencia) where chave_idempotencia is not null;

alter table financeiro_lancamentos add column if not exists pago_em timestamptz;
-- data de caixa: quando foi pago (ou quando foi lançado, se ainda está pendente)
alter table financeiro_lancamentos
  add column if not exists data_ref timestamptz generated always as (coalesce(pago_em, criado_em)) stored;
alter table financeiro_lancamentos alter column criado_por set default auth.uid();

alter table financeiro_lancamentos drop constraint if exists financeiro_valor_positivo;
alter table financeiro_lancamentos add constraint financeiro_valor_positivo check (valor > 0);
alter table venda_itens drop constraint if exists venda_itens_qtd_positiva;
alter table venda_itens add constraint venda_itens_qtd_positiva check (quantidade > 0);
alter table precos_loja drop constraint if exists precos_preco_nao_negativo;
alter table precos_loja add constraint precos_preco_nao_negativo check (preco >= 0);
alter table vendas drop constraint if exists vendas_valores_ok;
alter table vendas add constraint vendas_valores_ok check (subtotal >= 0 and desconto >= 0 and total >= 0);

create unique index if not exists sabores_item_nome_unico on sabores (item_id, lower(nome));
create index if not exists idx_venda_itens_venda on venda_itens (venda_id);
create index if not exists idx_venda_itens_item on venda_itens (item_id);
create index if not exists idx_estoque_mov_estoque on estoque_movimentos (estoque_id, criado_em desc);
create index if not exists idx_estoque_mov_venda on estoque_movimentos (venda_id);
create index if not exists idx_vendas_loja_data on vendas (loja_id, criado_em desc);
create index if not exists idx_vendas_cliente on vendas (cliente_id);
create index if not exists idx_financeiro_loja_data on financeiro_lancamentos (loja_id, data_ref desc);
create index if not exists idx_financeiro_venda on financeiro_lancamentos (venda_id);
create index if not exists idx_precos_item on precos_loja (item_id);
create index if not exists idx_sabores_item on sabores (item_id);
create index if not exists idx_itens_marca on itens (marca_id);
create index if not exists idx_itens_categoria on itens (categoria_id);
create index if not exists idx_perfis_lojas_loja on perfis_lojas (loja_id);

create or replace function trg_financeiro_pago_em() returns trigger
language plpgsql set search_path = public as $tag_trg_pago_em$
begin
  if new.status = 'pago' and new.pago_em is null then
    new.pago_em := now();
  end if;
  return new;
end;
$tag_trg_pago_em$;

drop trigger if exists financeiro_pago_em on financeiro_lancamentos;
create trigger financeiro_pago_em before insert on financeiro_lancamentos
  for each row execute function trg_financeiro_pago_em();

-- ---------- 2) Políticas ----------
-- quantidade de estoque só muda pelas funções (que gravam histórico)
drop policy if exists "sem escrita direta" on estoque;
drop policy if exists "sem update direto" on estoque;

-- lançamentos financeiros: o cliente só cria lançamentos manuais; mudar status é pela função
drop policy if exists "financeiro update propria" on financeiro_lancamentos;
drop policy if exists "financeiro escrita propria" on financeiro_lancamentos;
create policy "financeiro escrita propria" on financeiro_lancamentos for insert with check (
  loja_id in (select minhas_lojas())
  and venda_id is null
  and categoria not in ('venda','estorno')
  and criado_por = auth.uid()
);

-- a equipe enxerga os nomes (para mostrar quem fez cada movimento)
drop policy if exists "equipe le perfis" on perfis;
create policy "equipe le perfis" on perfis for select using (eh_da_equipe());

-- ---------- 3) Funções ----------
create or replace function eh_gerente() returns boolean
language sql stable security definer set search_path = public as $tag_eh_gerente$
  select exists (select 1 from perfis where id = auth.uid() and papel in ('gerente','dono'))
$tag_eh_gerente$;

-- Venda: preço, nome e estoque vêm do SERVIDOR (o navegador só diz o que e quantos).
-- Tudo ou nada: se qualquer item falhar, nada é gravado.
drop function if exists registrar_venda(uuid, jsonb, jsonb, text, numeric);
create or replace function registrar_venda(
  p_loja_id uuid,
  p_itens jsonb,
  p_cliente jsonb default null,
  p_forma_pagamento text default null,
  p_desconto numeric default 0,
  p_chave uuid default null
) returns jsonb
language plpgsql security definer set search_path = public as $tag_registrar_venda$
declare
  v_ex record;
  v_venda_id uuid;
  v_cliente_id uuid;
  v_cliente_nome text;
  v_telefone text;
  v_subtotal numeric := 0;
  v_desconto numeric := round(coalesce(p_desconto, 0), 2);
  v_total numeric;
  v_linha record;
  v_linhas jsonb := '[]'::jsonb;
  v_l jsonb;
  v_estoque_id uuid;
  v_saldo int;
  v_preco numeric;
  v_nome text;
  v_sabor_nome text;
  v_ativo boolean;
begin
  if p_loja_id is null or not tenho_acesso_a_loja(p_loja_id) then
    raise exception 'Você não tem permissão para vender por esta loja';
  end if;
  if p_chave is not null then
    -- duas chamadas simultâneas com a mesma chave: a 2ª espera a 1ª terminar e recebe a venda já feita
    perform pg_advisory_xact_lock(hashtextextended(p_loja_id::text || ':' || p_chave::text, 0));
    select id, subtotal, desconto, total into v_ex from vendas
      where loja_id = p_loja_id and chave_idempotencia = p_chave;
    if found then
      return jsonb_build_object('id', v_ex.id, 'subtotal', v_ex.subtotal, 'desconto', v_ex.desconto,
                                'total', v_ex.total, 'repetida', true);
    end if;
  end if;
  if p_itens is null or jsonb_typeof(p_itens) <> 'array' or jsonb_array_length(p_itens) = 0 then
    raise exception 'A venda precisa ter pelo menos um item';
  end if;
  if v_desconto < 0 then
    raise exception 'Desconto inválido';
  end if;
  if p_forma_pagamento is not null and p_forma_pagamento not in ('Pix','Cartão','Débito','Crédito','Dinheiro','Outro') then
    raise exception 'Forma de pagamento inválida';
  end if;

  v_cliente_nome := nullif(trim(coalesce(p_cliente->>'nome','')), '');
  v_telefone := nullif(regexp_replace(coalesce(p_cliente->>'telefone',''), '\D', '', 'g'), '');
  if v_telefone is not null then
    insert into clientes (loja_id, nome, telefone, endereco)
    values (p_loja_id, coalesce(v_cliente_nome, 'Cliente'), v_telefone,
            nullif(trim(coalesce(p_cliente->>'endereco','')), ''))
    on conflict (loja_id, telefone) do update
      set nome = coalesce(v_cliente_nome, clientes.nome),
          endereco = coalesce(excluded.endereco, clientes.endereco)
    returning id, nome into v_cliente_id, v_cliente_nome;
  end if;

  -- ordem fixa de travamento evita impasse (deadlock) entre vendas simultâneas
  for v_linha in
    select (e.value->>'item_id')::uuid as item_id,
           nullif(e.value->>'sabor_id','')::uuid as sabor_id,
           (e.value->>'quantidade')::int as qtd
    from jsonb_array_elements(p_itens) e
    order by 1, 2
  loop
    if v_linha.qtd is null or v_linha.qtd <= 0 then
      raise exception 'Quantidade inválida';
    end if;

    select i.nome, i.ativo into v_nome, v_ativo from itens i where i.id = v_linha.item_id;
    if v_nome is null then
      raise exception 'Item não encontrado';
    end if;
    if v_linha.sabor_id is not null then
      select s.nome into v_sabor_nome from sabores s
        where s.id = v_linha.sabor_id and s.item_id = v_linha.item_id;
      if v_sabor_nome is null then
        raise exception 'Sabor não encontrado para "%"', v_nome;
      end if;
      v_nome := v_nome || ' — ' || v_sabor_nome;
    end if;
    if not v_ativo then
      raise exception '"%" está desativado', v_nome;
    end if;

    select pl.preco into v_preco from precos_loja pl
      where pl.loja_id = p_loja_id and pl.item_id = v_linha.item_id and pl.ativo;
    if v_preco is null then
      raise exception '"%" não tem preço definido para esta loja', v_nome;
    end if;

    select e.id into v_estoque_id from estoque e
      where e.item_id = v_linha.item_id and e.sabor_id is not distinct from v_linha.sabor_id
      for update;
    if v_estoque_id is null then
      raise exception 'Item sem registro de estoque: %', v_nome;
    end if;

    update estoque set quantidade = quantidade - v_linha.qtd, atualizado_em = now()
      where id = v_estoque_id and quantidade >= v_linha.qtd
      returning quantidade into v_saldo;
    if v_saldo is null then
      raise exception 'Estoque insuficiente para "%" (pedido: % un.)', v_nome, v_linha.qtd;
    end if;

    v_subtotal := v_subtotal + v_linha.qtd * v_preco;
    v_linhas := v_linhas || jsonb_build_object(
      'item_id', v_linha.item_id, 'sabor_id', v_linha.sabor_id, 'nome', v_nome,
      'qtd', v_linha.qtd, 'preco', v_preco, 'estoque_id', v_estoque_id, 'saldo', v_saldo);
  end loop;

  if v_desconto > v_subtotal then
    raise exception 'Desconto maior que o subtotal';
  end if;
  v_total := v_subtotal - v_desconto;

  insert into vendas (loja_id, cliente_id, cliente_nome, forma_pagamento, subtotal, desconto, total, criado_por, chave_idempotencia)
  values (p_loja_id, v_cliente_id, v_cliente_nome, p_forma_pagamento, v_subtotal, v_desconto, v_total, auth.uid(), p_chave)
  returning id into v_venda_id;

  for v_l in select * from jsonb_array_elements(v_linhas) loop
    insert into venda_itens (venda_id, item_id, sabor_id, nome_snapshot, quantidade, preco_unitario)
    values (v_venda_id, (v_l->>'item_id')::uuid, nullif(v_l->>'sabor_id','')::uuid,
            v_l->>'nome', (v_l->>'qtd')::int, (v_l->>'preco')::numeric);
    insert into estoque_movimentos (estoque_id, loja_id, tipo, quantidade, saldo_resultante, venda_id, criado_por)
    values ((v_l->>'estoque_id')::uuid, p_loja_id, 'venda', -((v_l->>'qtd')::int), (v_l->>'saldo')::int, v_venda_id, auth.uid());
  end loop;

  insert into financeiro_lancamentos (loja_id, tipo, categoria, descricao, valor, forma_pagamento, status, venda_id, criado_por)
  values (p_loja_id, 'entrada', 'venda', 'Venda #' || substr(v_venda_id::text,1,8), v_total, p_forma_pagamento, 'pago', v_venda_id, auth.uid());

  return jsonb_build_object('id', v_venda_id, 'subtotal', v_subtotal, 'desconto', v_desconto, 'total', v_total);
end;
$tag_registrar_venda$;

-- Cancela a venda: devolve o estoque, registra quem/por quê e lança o estorno no financeiro.
drop function if exists cancelar_venda(uuid);
create or replace function cancelar_venda(p_venda_id uuid, p_motivo text default null) returns void
language plpgsql security definer set search_path = public as $tag_cancelar_venda$
declare
  v_venda vendas%rowtype;
  v_item venda_itens%rowtype;
  v_estoque_id uuid;
  v_saldo int;
begin
  select * into v_venda from vendas where id = p_venda_id for update;
  if v_venda.id is null then
    raise exception 'Venda não encontrada';
  end if;
  if not tenho_acesso_a_loja(v_venda.loja_id) and not eh_dono() then
    raise exception 'Você não pode cancelar vendas de outra loja';
  end if;
  if v_venda.status = 'cancelada' then
    raise exception 'Venda já está cancelada';
  end if;

  for v_item in select * from venda_itens where venda_id = p_venda_id order by item_id, sabor_id loop
    select id into v_estoque_id from estoque
      where item_id = v_item.item_id and sabor_id is not distinct from v_item.sabor_id
      for update;
    if v_estoque_id is null then
      raise exception 'Não foi possível devolver "%" ao estoque: o item foi reorganizado em sabores depois da venda. Ajuste o estoque manualmente.', v_item.nome_snapshot;
    end if;

    update estoque set quantidade = quantidade + v_item.quantidade, atualizado_em = now()
      where id = v_estoque_id
      returning quantidade into v_saldo;

    insert into estoque_movimentos (estoque_id, loja_id, tipo, quantidade, saldo_resultante, venda_id, observacao, criado_por)
    values (v_estoque_id, v_venda.loja_id, 'estorno', v_item.quantidade, v_saldo, p_venda_id, nullif(trim(coalesce(p_motivo,'')),''), auth.uid());
  end loop;

  update vendas
     set status = 'cancelada', cancelada_em = now(), cancelada_por = auth.uid(),
         motivo_cancelamento = nullif(trim(coalesce(p_motivo,'')),'')
   where id = p_venda_id;

  insert into financeiro_lancamentos (loja_id, tipo, categoria, descricao, valor, status, venda_id, criado_por)
  values (v_venda.loja_id, 'saida', 'estorno', 'Estorno da venda #' || substr(p_venda_id::text,1,8), v_venda.total, 'pago', p_venda_id, auth.uid());
end;
$tag_cancelar_venda$;

-- Entrada/saída manual de estoque (só gerente/dono). Sempre grava histórico.
create or replace function ajustar_estoque(p_estoque_id uuid, p_quantidade int, p_loja_id uuid, p_observacao text default null)
returns int language plpgsql security definer set search_path = public as $tag_ajustar_estoque$
declare v_saldo int;
begin
  if p_quantidade is null or p_quantidade = 0 then
    raise exception 'Quantidade de ajuste não pode ser zero';
  end if;
  if not tenho_acesso_a_loja(p_loja_id) then
    raise exception 'Você não tem permissão para ajustar estoque por esta loja';
  end if;
  if not eh_gerente() then
    raise exception 'Só gerente ou dono pode ajustar o estoque';
  end if;

  perform 1 from estoque where id = p_estoque_id for update;
  update estoque set quantidade = quantidade + p_quantidade, atualizado_em = now()
    where id = p_estoque_id and quantidade + p_quantidade >= 0
    returning quantidade into v_saldo;
  if v_saldo is null then
    raise exception 'Esse ajuste deixaria o estoque negativo';
  end if;

  insert into estoque_movimentos(estoque_id, loja_id, tipo, quantidade, saldo_resultante, observacao, criado_por)
  values (p_estoque_id, p_loja_id, case when p_quantidade > 0 then 'entrada' else 'ajuste' end,
          p_quantidade, v_saldo, nullif(trim(coalesce(p_observacao,'')),''), auth.uid());
  return v_saldo;
end;
$tag_ajustar_estoque$;

-- Contagem física: o servidor calcula a diferença com o estoque travado (sem corrida).
create or replace function contar_estoque(p_estoque_id uuid, p_quantidade_contada int, p_loja_id uuid, p_observacao text default null)
returns int language plpgsql security definer set search_path = public as $tag_contar_estoque$
declare v_atual int; v_delta int;
begin
  if p_quantidade_contada is null or p_quantidade_contada < 0 then
    raise exception 'Informe a quantidade contada (zero ou mais)';
  end if;
  if not tenho_acesso_a_loja(p_loja_id) then
    raise exception 'Você não tem permissão para ajustar estoque por esta loja';
  end if;
  if not eh_gerente() then
    raise exception 'Só gerente ou dono pode ajustar o estoque';
  end if;

  select quantidade into v_atual from estoque where id = p_estoque_id for update;
  if v_atual is null then
    raise exception 'Estoque não encontrado';
  end if;
  v_delta := p_quantidade_contada - v_atual;
  if v_delta = 0 then
    return v_atual;
  end if;

  update estoque set quantidade = p_quantidade_contada, atualizado_em = now() where id = p_estoque_id;
  insert into estoque_movimentos(estoque_id, loja_id, tipo, quantidade, saldo_resultante, observacao, criado_por)
  values (p_estoque_id, p_loja_id, 'ajuste', v_delta, p_quantidade_contada,
          'Contagem física' || coalesce(': ' || nullif(trim(coalesce(p_observacao,'')),''), ''), auth.uid());
  return p_quantidade_contada;
end;
$tag_contar_estoque$;

create or replace function definir_estoque_minimo(p_estoque_id uuid, p_minimo int) returns void
language plpgsql security definer set search_path = public as $tag_estoque_minimo$
begin
  if not eh_gerente() then
    raise exception 'Só gerente ou dono pode alterar o estoque mínimo';
  end if;
  if p_minimo is null or p_minimo < 0 then
    raise exception 'Estoque mínimo inválido';
  end if;
  update estoque set estoque_minimo = p_minimo where id = p_estoque_id;
end;
$tag_estoque_minimo$;

-- Cadastro de item já com estoque inicial NO HISTÓRICO (cada sabor começa com a quantidade informada).
create or replace function criar_item(
  p_loja_id uuid, p_tipo text, p_marca_id uuid, p_categoria_id uuid,
  p_nome text, p_emoji text, p_sabores text[], p_estoque_inicial int, p_estoque_minimo int default 3
) returns uuid
language plpgsql security definer set search_path = public as $tag_criar_item$
declare
  v_item uuid; v_est uuid; v_sabor uuid; v_nome text; v_qtd int := coalesce(p_estoque_inicial, 0);
  v_tem_sabor boolean := false;
begin
  if not tenho_acesso_a_loja(p_loja_id) then
    raise exception 'Você não tem permissão para esta loja';
  end if;
  if not eh_gerente() then
    raise exception 'Só gerente ou dono pode cadastrar itens';
  end if;
  if coalesce(trim(p_nome),'') = '' then
    raise exception 'Informe o nome do item';
  end if;
  if v_qtd < 0 or coalesce(p_estoque_minimo, 0) < 0 then
    raise exception 'Quantidade não pode ser negativa';
  end if;

  insert into itens (tipo, marca_id, categoria_id, nome, emoji)
  values (p_tipo, p_marca_id, p_categoria_id, trim(p_nome), nullif(trim(coalesce(p_emoji,'')),''))
  returning id into v_item;

  if p_sabores is not null then
    foreach v_nome in array p_sabores loop
      v_nome := trim(v_nome);
      if v_nome = '' then continue; end if;
      v_tem_sabor := true;
      insert into sabores (item_id, nome) values (v_item, v_nome) returning id into v_sabor;
      insert into estoque (item_id, sabor_id, quantidade, estoque_minimo)
      values (v_item, v_sabor, v_qtd, coalesce(p_estoque_minimo, 3)) returning id into v_est;
      if v_qtd > 0 then
        insert into estoque_movimentos (estoque_id, loja_id, tipo, quantidade, saldo_resultante, observacao, criado_por)
        values (v_est, p_loja_id, 'entrada', v_qtd, v_qtd, 'Estoque inicial', auth.uid());
      end if;
    end loop;
  end if;

  if not v_tem_sabor then
    insert into estoque (item_id, sabor_id, quantidade, estoque_minimo)
    values (v_item, null, v_qtd, coalesce(p_estoque_minimo, 3)) returning id into v_est;
    if v_qtd > 0 then
      insert into estoque_movimentos (estoque_id, loja_id, tipo, quantidade, saldo_resultante, observacao, criado_por)
      values (v_est, p_loja_id, 'entrada', v_qtd, v_qtd, 'Estoque inicial', auth.uid());
    end if;
  end if;
  return v_item;
end;
$tag_criar_item$;

-- Adiciona sabor. Se o item ainda não tinha sabores, o estoque que ele já tinha passa a ser
-- DESTE sabor (nada fica escondido), e o histórico anota isso.
create or replace function adicionar_sabor(p_loja_id uuid, p_item_id uuid, p_nome text, p_quantidade int default 0)
returns uuid
language plpgsql security definer set search_path = public as $tag_adicionar_sabor$
declare
  v_sabor uuid; v_base uuid; v_base_qtd int; v_est uuid; v_saldo int;
  v_nome text := trim(coalesce(p_nome,'')); v_qtd int := coalesce(p_quantidade, 0);
begin
  if not tenho_acesso_a_loja(p_loja_id) then
    raise exception 'Você não tem permissão para esta loja';
  end if;
  if not eh_gerente() then
    raise exception 'Só gerente ou dono pode cadastrar sabores';
  end if;
  if v_nome = '' then
    raise exception 'Informe o nome do sabor';
  end if;
  if v_qtd < 0 then
    raise exception 'Quantidade não pode ser negativa';
  end if;
  perform 1 from itens where id = p_item_id for update;
  if not found then
    raise exception 'Item não encontrado';
  end if;

  insert into sabores (item_id, nome) values (p_item_id, v_nome) returning id into v_sabor;

  select id, quantidade into v_base, v_base_qtd from estoque
    where item_id = p_item_id and sabor_id is null for update;
  if v_base is not null then
    update estoque set sabor_id = v_sabor where id = v_base;
    v_est := v_base;
    v_saldo := v_base_qtd;
    insert into estoque_movimentos (estoque_id, loja_id, tipo, quantidade, saldo_resultante, observacao, criado_por)
    values (v_est, p_loja_id, 'ajuste', 0, v_saldo, 'Estoque do item passou a ser do sabor ' || v_nome, auth.uid());
  else
    insert into estoque (item_id, sabor_id, quantidade) values (p_item_id, v_sabor, 0) returning id into v_est;
    v_saldo := 0;
  end if;

  if v_qtd > 0 then
    update estoque set quantidade = quantidade + v_qtd, atualizado_em = now()
      where id = v_est returning quantidade into v_saldo;
    insert into estoque_movimentos (estoque_id, loja_id, tipo, quantidade, saldo_resultante, observacao, criado_por)
    values (v_est, p_loja_id, 'entrada', v_qtd, v_saldo, 'Estoque inicial do sabor', auth.uid());
  end if;
  return v_sabor;
end;
$tag_adicionar_sabor$;

-- Marca um lançamento MANUAL como pago (lançamentos de venda não podem ser mexidos).
create or replace function pagar_lancamento(p_id uuid) returns void
language plpgsql security definer set search_path = public as $tag_pagar_lancamento$
declare v financeiro_lancamentos%rowtype;
begin
  select * into v from financeiro_lancamentos where id = p_id for update;
  if v.id is null then
    raise exception 'Lançamento não encontrado';
  end if;
  if v.loja_id is null or not tenho_acesso_a_loja(v.loja_id) then
    raise exception 'Você não tem permissão para este lançamento';
  end if;
  if v.venda_id is not null then
    raise exception 'Lançamentos de venda não podem ser alterados; cancele a venda';
  end if;
  if v.status = 'pago' then
    raise exception 'Este lançamento já está pago';
  end if;
  update financeiro_lancamentos set status = 'pago', pago_em = now() where id = p_id;
end;
$tag_pagar_lancamento$;

-- WhatsApp da loja (só números; se vier sem o 55 do Brasil, acrescenta)
create or replace function definir_whatsapp_loja(p_loja_id uuid, p_whatsapp text) returns text
language plpgsql security definer set search_path = public as $tag_whatsapp_loja$
declare v_num text := regexp_replace(coalesce(p_whatsapp,''), '\D', '', 'g');
begin
  if not tenho_acesso_a_loja(p_loja_id) then
    raise exception 'Você não tem permissão para esta loja';
  end if;
  if not eh_gerente() then
    raise exception 'Só gerente ou dono pode alterar o WhatsApp da loja';
  end if;
  if v_num = '' then
    update lojas set whatsapp = null where id = p_loja_id;
    return null;
  end if;
  if length(v_num) in (10, 11) then
    v_num := '55' || v_num;
  end if;
  if length(v_num) < 12 or length(v_num) > 15 then
    raise exception 'Número de WhatsApp inválido';
  end if;
  update lojas set whatsapp = v_num where id = p_loja_id;
  return v_num;
end;
$tag_whatsapp_loja$;

-- Resumos calculados no banco (somam TUDO, sem limite de linhas). Respeitam as regras de acesso.
create or replace function painel_resumo(p_loja_id uuid) returns jsonb
language plpgsql stable set search_path = public as $tag_painel_resumo$
declare
  tz constant text := 'America/Sao_Paulo';
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  v_mes date := date_trunc('month', now() at time zone 'America/Sao_Paulo')::date;
begin
  if not tenho_acesso_a_loja(p_loja_id) then
    raise exception 'Sem permissão para esta loja';
  end if;
  return jsonb_build_object(
    'hoje', (select jsonb_build_object('qtd', count(*), 'total', coalesce(sum(total),0))
             from vendas where loja_id = p_loja_id and status = 'concluida' and (criado_em at time zone tz)::date = v_hoje),
    'mes', (select jsonb_build_object('qtd', count(*), 'total', coalesce(sum(total),0))
            from vendas where loja_id = p_loja_id and status = 'concluida' and (criado_em at time zone tz)::date >= v_mes),
    'saldo_caixa', (select coalesce(sum(case when tipo = 'entrada' then valor else -valor end),0)
                    from financeiro_lancamentos where loja_id = p_loja_id and status = 'pago'),
    'a_receber', (select jsonb_build_object('qtd', count(*), 'total', coalesce(sum(valor),0))
                  from financeiro_lancamentos where loja_id = p_loja_id and status <> 'pago' and tipo = 'entrada'),
    'a_pagar', (select jsonb_build_object('qtd', count(*), 'total', coalesce(sum(valor),0))
                from financeiro_lancamentos where loja_id = p_loja_id and status <> 'pago' and tipo = 'saida'),
    'atrasados', (select jsonb_build_object('qtd', count(*), 'total', coalesce(sum(valor),0))
                  from financeiro_lancamentos where loja_id = p_loja_id and status <> 'pago' and vencimento < v_hoje),
    'por_dia', (select coalesce(jsonb_agg(jsonb_build_object('dia', d.dia, 'total', coalesce(t.total,0), 'qtd', coalesce(t.qtd,0)) order by d.dia), '[]'::jsonb)
                from generate_series(v_hoje - 6, v_hoje, interval '1 day') as g(dia_ts)
                cross join lateral (select g.dia_ts::date as dia) d
                left join (select (criado_em at time zone tz)::date as dia, sum(total) as total, count(*) as qtd
                           from vendas where loja_id = p_loja_id and status = 'concluida'
                             and (criado_em at time zone tz)::date >= v_hoje - 6
                           group by 1) t on t.dia = d.dia),
    'top_produtos', (select coalesce(jsonb_agg(x), '[]'::jsonb) from (
                       select vi.nome_snapshot as nome, sum(vi.quantidade)::int as qtd,
                              sum(vi.quantidade * vi.preco_unitario) as total
                       from venda_itens vi join vendas v on v.id = vi.venda_id
                       where v.loja_id = p_loja_id and v.status = 'concluida' and (v.criado_em at time zone tz)::date >= v_mes
                       group by vi.nome_snapshot order by sum(vi.quantidade) desc, vi.nome_snapshot limit 5) x)
  );
end;
$tag_painel_resumo$;

create or replace function financeiro_resumo(p_loja_id uuid, p_inicio date, p_fim date) returns jsonb
language plpgsql stable set search_path = public as $tag_financeiro_resumo$
declare
  tz constant text := 'America/Sao_Paulo';
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  v_entradas numeric; v_saidas numeric;
begin
  if not tenho_acesso_a_loja(p_loja_id) then
    raise exception 'Sem permissão para esta loja';
  end if;
  select coalesce(sum(valor) filter (where tipo = 'entrada'),0), coalesce(sum(valor) filter (where tipo = 'saida'),0)
    into v_entradas, v_saidas
    from financeiro_lancamentos
   where loja_id = p_loja_id and status = 'pago'
     and (p_inicio is null or (data_ref at time zone tz)::date >= p_inicio)
     and (p_fim is null or (data_ref at time zone tz)::date <= p_fim);
  return jsonb_build_object(
    'entradas', v_entradas, 'saidas', v_saidas, 'saldo_periodo', v_entradas - v_saidas,
    'saldo_caixa', (select coalesce(sum(case when tipo = 'entrada' then valor else -valor end),0)
                    from financeiro_lancamentos where loja_id = p_loja_id and status = 'pago'),
    'a_receber', (select jsonb_build_object('qtd', count(*), 'total', coalesce(sum(valor),0))
                  from financeiro_lancamentos where loja_id = p_loja_id and status <> 'pago' and tipo = 'entrada'),
    'a_pagar', (select jsonb_build_object('qtd', count(*), 'total', coalesce(sum(valor),0))
                from financeiro_lancamentos where loja_id = p_loja_id and status <> 'pago' and tipo = 'saida'),
    'atrasados', (select jsonb_build_object('qtd', count(*), 'total', coalesce(sum(valor),0))
                  from financeiro_lancamentos where loja_id = p_loja_id and status <> 'pago' and vencimento < v_hoje)
  );
end;
$tag_financeiro_resumo$;

-- ---------- 4) Quem pode chamar o quê ----------
revoke execute on function public.registrar_venda(uuid, jsonb, jsonb, text, numeric, uuid) from public, anon;
revoke execute on function public.cancelar_venda(uuid, text) from public, anon;
revoke execute on function public.ajustar_estoque(uuid, integer, uuid, text) from public, anon;
revoke execute on function public.contar_estoque(uuid, integer, uuid, text) from public, anon;
revoke execute on function public.definir_estoque_minimo(uuid, integer) from public, anon;
revoke execute on function public.criar_item(uuid, text, uuid, uuid, text, text, text[], integer, integer) from public, anon;
revoke execute on function public.adicionar_sabor(uuid, uuid, text, integer) from public, anon;
revoke execute on function public.pagar_lancamento(uuid) from public, anon;
revoke execute on function public.definir_whatsapp_loja(uuid, text) from public, anon;
revoke execute on function public.painel_resumo(uuid) from public, anon;
revoke execute on function public.financeiro_resumo(uuid, date, date) from public, anon;
revoke execute on function public.eh_gerente() from public, anon;
revoke execute on function public.trg_financeiro_pago_em() from public, anon;

-- ============================================================
-- 014_catalogo_online.sql — Catálogo ONLINE (site público) alimentado pelo mesmo banco da dashboard: preços, itens, sabores e ESTOQUE.
-- Ordem (nada aplicado no remoto): ... -> 013 -> 014. Pré-requisito: schema.sql (catálogo/estoque/preços) — não depende das demais.
-- SOMENTE LEITURA e sem login: uma função pública (anon) devolve o catálogo de UMA loja (padrão: smoke-club), já pronto para o site:
--   * só entra o que está publicado: item ativo + preço da loja ativo e > 0 + marca ativa (marca inativa some);
--   * cada sabor vira uma linha ("Nome — Sabor"), como já funciona no site; item sem sabor = uma linha;
--   * "estoque" = há unidade disponível; "limite" = unidades disponíveis até no máximo 20 (não expõe o estoque exato nem dados de venda);
--   * "de" (preço riscado) só aparece se for maior que o preço atual.
-- O que a dashboard edita (itens, preço, "de", destaque, imagem, descrição, marcas, categorias, WhatsApp e estoque) aparece no site sozinho.
-- Não expõe clientes, vendas, financeiro, custos nem pessoas. Não altera nenhum dado.
-- ============================================================
create or replace function catalogo_publico(p_loja_slug text default 'smoke-club') returns jsonb
language plpgsql stable security definer set search_path = public as $tag_catalogo_publico$
declare v_loja lojas%rowtype; r jsonb;
begin
  select * into v_loja from lojas where slug = p_loja_slug and ativo;
  if v_loja.id is null then raise exception 'Loja não encontrada'; end if;
  with linhas as (
    select i.id as item_id, i.tipo, i.marca_id, i.categoria_id, i.ordem as item_ordem, i.nome as item_nome, s.id as sabor_id, s.nome as sabor_nome, s.ordem as sabor_ordem,
           coalesce(i.descricao, '') as descricao, i.emoji, i.imagem_url, i.destaque, p.preco, p.preco_de,
           coalesce(e.quantidade, 0) as qtd
      from itens i
      join precos_loja p on p.item_id = i.id and p.loja_id = v_loja.id and p.ativo and p.preco > 0
      left join marcas m on m.id = i.marca_id
      left join sabores s on s.item_id = i.id
      left join estoque e on e.item_id = i.id and e.sabor_id is not distinct from s.id
     where i.ativo and (i.tipo = 'produto' or coalesce(m.ativo, false))),
  fmt as (
    select l.*, case when l.sabor_id is null then l.item_nome else l.item_nome || ' — ' || l.sabor_nome end as nome_linha,
           jsonb_build_object('id', l.item_id::text || ':' || coalesce(l.sabor_id::text, ''), 'item_id', l.item_id, 'nome', case when l.sabor_id is null then l.item_nome else l.item_nome || ' — ' || l.sabor_nome end,
             'item_nome', l.item_nome, 'sabor', l.sabor_nome, 'desc', l.descricao, 'emoji', l.emoji, 'img', l.imagem_url, 'destaque', l.destaque, 'preco', l.preco,
             'de', case when l.preco_de is not null and l.preco_de > l.preco then l.preco_de end, 'estoque', l.qtd > 0, 'limite', least(l.qtd, 20)) as j
      from linhas l)
  select jsonb_build_object(
    'gerado_em', now(),
    'loja', jsonb_build_object('nome', v_loja.nome, 'whatsapp', regexp_replace(coalesce(v_loja.whatsapp, ''), '\D', '', 'g')),
    'categorias', coalesce((select jsonb_agg(jsonb_build_object('nome', c.nome, 'cor', c.cor) order by c.ordem, c.nome) from categorias c where exists (select 1 from fmt f where f.categoria_id = c.id)), '[]'::jsonb),
    'produtos', coalesce((select jsonb_agg(f.j || jsonb_build_object('categoria', coalesce(c.nome, 'Outros')) order by coalesce(c.ordem, 9999), coalesce(c.nome, 'Outros'), f.item_ordem, f.item_nome, f.sabor_ordem, f.sabor_nome)
                            from fmt f left join categorias c on c.id = f.categoria_id where f.tipo = 'produto'), '[]'::jsonb),
    'marcas', coalesce((select jsonb_agg(jsonb_build_object('nome', m.nome, 'descricao', coalesce(m.descricao, ''), 'cor_fita', m.cor_fita, 'cor_grad_a', m.cor_grad_a, 'cor_grad_b', m.cor_grad_b, 'cor_fundo', m.cor_fundo,
                              'modelos', (select jsonb_agg(f.j order by f.item_ordem, f.item_nome, f.sabor_ordem, f.sabor_nome) from fmt f where f.marca_id = m.id and f.tipo = 'modelo')) order by m.ordem, m.nome)
                          from marcas m where m.ativo and exists (select 1 from fmt f where f.marca_id = m.id and f.tipo = 'modelo')), '[]'::jsonb)
  ) into r;
  return r;
end;
$tag_catalogo_publico$;

revoke execute on function public.catalogo_publico(text) from public;
grant execute on function public.catalogo_publico(text) to anon, authenticated;

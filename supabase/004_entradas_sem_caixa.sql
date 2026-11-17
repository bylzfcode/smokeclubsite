-- ============================================================
-- 004_entradas_sem_caixa.sql — Entradas em DINHEIRO que não pertencem a nenhum caixa.
-- Só leitura: não vincula nada ao próximo caixa e não altera vendas, caixas nem financeiro.
-- Rodar DEPOIS de 003_caixa_avisos.sql. Mesmas regras de acesso do histórico financeiro
-- (administrador geral vê tudo; os demais, só as lojas liberadas para eles).
--
-- "Sem caixa" = venda concluída paga em Dinheiro cujo horário não cai na janela de nenhum caixa da loja
-- (da abertura até o fim da janela; caixa ainda aberto cobre até agora; reabrir um caixa NÃO estende a janela).
-- ============================================================
create or replace function entradas_sem_caixa(p_loja_id uuid default null, p_inicio date default null, p_fim date default null,
  p_responsavel uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public as $tag_sem_caixa$
declare
  tz constant text := 'America/Sao_Paulo';
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  v_ini date; v_fim date; v_lojas uuid[]; r jsonb;
begin
  if not (eh_dono() or eh_da_equipe()) then raise exception 'Sem permissão'; end if;
  v_lojas := case when eh_dono() then array(select id from lojas where ativo) else array(select minhas_lojas()) end;
  if p_loja_id is not null and not (p_loja_id = any(v_lojas)) then raise exception 'Você não tem permissão para esta loja'; end if;
  v_fim := coalesce(p_fim, v_hoje); v_ini := coalesce(p_inicio, v_fim - 30);
  if v_ini > v_fim then raise exception 'Período inválido'; end if;
  if v_fim - v_ini > 366 then raise exception 'Período máximo: 1 ano'; end if;

  with sem as (
    select v.id, v.loja_id, lo.nome as loja_nome, v.criado_em, (v.criado_em at time zone tz)::date as dia, v.total as valor,
           (select nome from perfis where id = v.criado_por) as responsavel
      from vendas v join lojas lo on lo.id = v.loja_id
     where v.loja_id = any(v_lojas) and (p_loja_id is null or v.loja_id = p_loja_id)
       and v.status = 'concluida' and v.forma_pagamento = 'Dinheiro'
       and (v.criado_em at time zone tz)::date between v_ini and v_fim
       and (p_responsavel is null or v.criado_por = p_responsavel)
       and not exists (select 1 from caixas c
                        where c.loja_id = v.loja_id and v.criado_em >= c.aberto_em
                          and (c.janela_fim is null or v.criado_em <= c.janela_fim))
  )
  select jsonb_build_object(
    'total', coalesce((select sum(valor) from sem), 0),
    'quantidade', (select count(*) from sem),
    'por_dia', coalesce((select jsonb_agg(jsonb_build_object('dia', g.dia, 'loja_id', g.loja_id, 'loja_nome', g.loja_nome, 'total', g.total, 'quantidade', g.qtd) order by g.dia desc, g.loja_nome)
                           from (select dia, loja_id, loja_nome, sum(valor) as total, count(*) as qtd from sem group by dia, loja_id, loja_nome) g), '[]'::jsonb),
    'itens', coalesce((select jsonb_agg(jsonb_build_object('venda_id', s.id, 'loja_id', s.loja_id, 'loja_nome', s.loja_nome, 'criado_em', s.criado_em, 'dia', s.dia,
                           'valor', s.valor, 'responsavel', s.responsavel) order by s.criado_em desc) from sem s), '[]'::jsonb))
    into r;
  return r;
end;
$tag_sem_caixa$;

revoke execute on function public.entradas_sem_caixa(uuid, date, date, uuid) from public, anon;

# Escritório — Painel Compartilhado (4 lojas)

`dashboard.html` é um arquivo único (sem build) que usa o Supabase como banco
compartilhado. Fica separado do site público (`index (23).html`).

## Como funciona o acesso

- Login por **pessoa** (User + Senha). Internamente vira `<user>@painel.local`.
- Cada pessoa tem uma lista de lojas permitidas (`perfis_lojas`). Quem tem mais
  de uma escolhe a loja depois do login e troca sem logar de novo.
- Papéis: `operador` (vende), `gerente`/`dono` (também ajusta estoque, cadastra
  itens/preços no Catálogo).
- Estoque é **compartilhado**; preços, clientes, vendas e financeiro são **por loja**.

## Instalar do zero

No SQL Editor do Supabase, nesta ordem:
1. `supabase/schema.sql`
2. `supabase/002_melhorias.sql`
3. `supabase/003_caixa_avisos.sql` (caixa, histórico financeiro e avisos — sem ela as abas Caixa/Histórico e a seção de avisos mostram "falta aplicar a migração")

Crie os usuários (Authentication → Users, e-mail `user@painel.local`, auto-confirm),
depois vincule:

```sql
insert into perfis (id, nome, papel) values ('<id do auth.users>', 'LUIZ', 'dono');
insert into perfis_lojas (perfil_id, loja_id)
select '<id do auth.users>', id from lojas where slug in ('smoke-club','ez-store');
```

Em `dashboard.html`, ajuste `SUPABASE_URL` e `SUPABASE_ANON_KEY` (só a chave anon/pública, nunca a service_role).

## Garantias de estoque/financeiro

- Venda é uma função no banco (`registrar_venda`): trava as linhas, confere saldo,
  usa preço/nome do servidor e é tudo-ou-nada. Chave de idempotência evita venda
  duplicada em reenvio/duplo clique.
- Quantidade de estoque só muda por funções (venda, cancelamento, ajuste, contagem);
  todo movimento fica em `estoque_movimentos` (histórico na tela).
- Cancelar venda devolve o estoque e lança o estorno no financeiro.
- Resumos (painel/financeiro) são somados no banco, sem limite de linhas.

## Caixa, histórico e avisos (migração 003)

- **Caixa por loja:** um aberto por vez (garantido por índice único + trava no banco). Saldo inicial, responsável e data.
  Movimentos: entrada, saída, retirada (só dinheiro), ajuste (só gerente/dono, com observação). Movimento confirmado não
  se edita nem apaga: corrige-se por **estorno** (o original fica). Só o **dinheiro** entra na gaveta; Pix/cartão aparecem
  separados. Vendas em dinheiro são lidas de `vendas` (nada é copiado/duplicado no financeiro).
- **Fechamento:** esperado × contado = diferença (justificativa obrigatória se ≠ 0). Caixa fechado não muda; reabrir exige
  gerente/dono + motivo e fica na auditoria (a janela de vendas do caixa não se estende ao reabrir).
- **Histórico:** por dia, com filtros de loja/período/responsável/situação; expande para os detalhes. Dono vê tudo; os demais, só suas lojas.
- **Avisos:** mudanças do sistema, comunicados e alertas automáticos (contas vencidas, comprovantes pendentes, caixa de dia
  anterior, diferenças de fechamento). Global só o administrador geral; gerente publica nas lojas que administra. Lido é individual;
  edição relevante marca "atualizado". Marcar alerta como lido não resolve a pendência.
- Limitação conhecida: venda em dinheiro feita com **nenhum caixa aberto** não entra na conta de nenhum caixa.
- "Comprovante": coluna opcional `exige_comprovante` no lançamento + botão "Comprovante enviado" (não há upload de arquivo).

## Testes

- `supabase/tests/banco_testes.sql` — 128 verificações do banco (rodam e desfazem tudo).
- `supabase/tests/caixa_testes.sql` — 115 verificações de caixa/histórico/avisos (permissões, isolamento entre lojas, estorno, fechamento, reabertura).
- `supabase/tests/lab/` — banco local + concorrência (`concorrencia.sh` vendas; `concorrencia_caixa.sh` abertura/estorno/fechamento simultâneos).
- `supabase/tests/ui/` — a tela no Chromium com Supabase simulado e checagem dos
  nomes de parâmetros das funções contra o SQL:
  `NODE_PATH=/opt/node22/lib/node_modules node supabase/tests/ui/ui.test.js`

## Avisos

- Senhas "1234" são fracas; troque quando possível.
- A tabela antiga `sc_data` está aberta ("allow all for now").

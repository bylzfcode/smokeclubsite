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

## Testes

- `supabase/tests/banco_testes.sql` — 128 verificações do banco (rodam e desfazem tudo).
- `supabase/tests/lab/` — banco local + concorrência (últimas unidades, deadlock, chave repetida, cancelamentos simultâneos).
- `supabase/tests/ui/` — a tela no Chromium com Supabase simulado e checagem dos
  nomes de parâmetros das funções contra o SQL:
  `NODE_PATH=/opt/node22/lib/node_modules node supabase/tests/ui/ui.test.js`

## Avisos

- Senhas "1234" são fracas; troque quando possível.
- A tabela antiga `sc_data` está aberta ("allow all for now").

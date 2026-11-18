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
3. `supabase/003_caixa_avisos.sql`, depois 4. `supabase/004_entradas_sem_caixa.sql` e 5. `supabase/005_pagamentos_comprovantes.sql` (caixa, histórico financeiro e avisos — sem ela as abas Caixa/Histórico e a seção de avisos mostram "falta aplicar a migração")

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
- **Valores sem caixa (004):** o Histórico tem uma seção com as vendas em dinheiro feitas sem caixa aberto (total, datas, responsável), respeitando as permissões. É só consulta: nada é vinculado automaticamente a um caixa nem alterado.
- "Comprovante": coluna opcional `exige_comprovante` no lançamento + botão "Comprovante enviado" (não há upload de arquivo).

## Pagamentos parciais e comprovantes (migração 005)

**Ordem de aplicação no Supabase (nenhuma foi aplicada ainda no projeto remoto):** `schema.sql` → `002` → `003` → `004` → `005` → `006`.
A 005 depende da 003 (permissões e caixa) e a 006 da 005. Rode uma por vez no SQL Editor e confira que terminou sem erro antes da próxima.
A ordem foi conferida instalando do zero numa pilha Supabase local real (veja "Validação contra a pilha real").

- **Contas:** cada conta tem valor original, total pago e saldo pendente. Situações: pendente, parcialmente paga, paga e cancelada
  ("saldo vencido" é calculado pela data de vencimento). Vários pagamentos até quitar; valor/data/forma/observação/responsável em cada um.
- **Segurança do pagamento:** pagamento acima do saldo é recusado no banco, inclusive com várias pessoas pagando ao mesmo tempo
  (a conta é travada). Cada requisição leva uma chave de repetição: clique duplo ou reenvio não grava duas vezes.
- **Estorno:** pagamento confirmado não se edita nem apaga; corrige-se com estorno (gerente/dono, com motivo), que fica ao lado do original.
  Tudo vai para a auditoria (`financeiro_auditoria`).
- **Registrar pagamento só anota uma operação já realizada.** Não transfere dinheiro e **não mexe no caixa** (não há integração, logo não há dupla contagem;
  despesa paga com dinheiro da gaveta continua sendo lançada no Caixa). Nos detalhes do dia do Histórico, cada linha mostra a origem
  (venda, pagamento de conta, estorno de pagamento, conta antiga).
- **Comprovantes:** PDF/JPG/PNG/WEBP até 5 MB, em bucket **privado** `comprovantes` (caminho `loja/pagamento/arquivo`). Só quem tem acesso à loja envia e lê
  (o administrador geral lê tudo); download por link assinado de 60 s. Três informações separadas: **pagamento confirmado**, **arquivo anexado**
  e **envio manual confirmado** (quem confirmou e quando). Se o upload falhar, o pagamento não é afetado e dá para tentar de novo; se o arquivo subiu
  mas o registro falhou, repete-se só o registro. Nada é enviado automaticamente a ninguém.
- **Alertas distintos** no Painel: "saldo vencido" (urgente) e "comprovante com envio pendente" (atenção).

**Como ficam os registros que já existiam (nada é reescrito):**
- Lançamento antigo `pago` sem pagamentos novos = **lançamento antigo quitado**: conta como pago o valor inteiro na data em que já constava; não ganha pagamento retroativo,
  não aceita novo pagamento nem estorno por aqui.
- Lançamento antigo `pendente`/`atrasado`: saldo = valor inteiro; aceita pagamentos normalmente.
- Entradas e estornos de venda continuam como estavam e não recebem pagamentos.
- A marcação antiga "comprovante enviado" vale **só** para lançamentos antigos e **não** vira arquivo anexado nem envio confirmado de pagamento novo.
- `pagar_lancamento` continua existindo e agora paga o saldo restante pelo mesmo fluxo (mesmas regras e auditoria).
- Saldo, a pagar/receber, vencidas, histórico por dia e alertas passam a usar os pagamentos; para contas antigas os números não mudam.

## Comprovantes: links assinados, limpeza de órfãos e limites (migração 006)

- **Link assinado:** o download usa um link temporário de 60 s (`createSignedUrl`, forçando "baixar"). **Quem já recebeu um link continua conseguindo usá-lo até ele expirar,
  mesmo que perca o acesso à loja nesse intervalo** (o link é portador do acesso; foi testado). Depois de expirar, deixa de funcionar. Por isso o prazo é curto.
- **Arquivos órfãos** (enviados mas nunca vinculados a um pagamento, por exemplo quando o registro falha): a limpeza é **só do servidor**.
  1. `006_limpeza_comprovantes.sql` cria as funções (restritas a `service_role`/dono do banco) e a tabela de registro `storage_limpeza`.
  2. `supabase/ops/limpar_comprovantes_orfaos.js` roda fora do navegador (agendador/cron), com a chave `service_role` em variável de ambiente (nunca no repositório nem no painel):
     `SUPABASE_URL=… SUPABASE_SERVICE_KEY=… node supabase/ops/limpar_comprovantes_orfaos.js` (simulação) e `… --apply` (executa).
  3. Segurança: tolerância padrão de **24 h** (mínimo 1 h) — uploads recentes ou em andamento não são tocados; **arquivos vinculados a pagamentos (inclusive estornados) nunca são tocados**;
     primeiro **reserva** (a partir daí o arquivo não pode mais ser vinculado, então não há corrida com um registro tardio) e só então apaga pela **API do Storage**
     (apagar só a linha em `storage.objects` por SQL deixaria o arquivo físico). Uma reserva esquecida há mais de 1 h (script interrompido) é retomada na próxima execução.
- **Limites conhecidos do Storage:** o tipo do arquivo é o que o navegador informa (o Storage confere a lista de tipos e a extensão, mas **não lê o conteúdo**): um arquivo com extensão e tipo de PDF mas conteúdo diferente seria aceito.
  Por isso os downloads saem como anexo. Não há antivírus. Se um upload for interrompido no meio da rede, nada é registrado e o pagamento fica intacto.

## Validação contra a pilha real (Docker)

`supabase/tests/stack/` sobe **Postgres do Supabase + Auth (GoTrue) + PostgREST + Storage API** reais em contêineres, instala `schema.sql → 002 → 003 → 004 → 005 → 006` do zero como o papel `postgres`
(o mesmo do SQL Editor), cria usuários por SQL direto (como no projeto remoto) e roda: `real_api.test.js` (login, isolamento entre lojas, pagamentos, Storage, limpeza) e `real_ui.test.js` (o `dashboard.html` no Chromium).
Requisitos: Docker com daemon ativo, Node 18+, Playwright. Uso: `supabase/tests/stack/run_all.sh` (`--keep` deixa a pilha de pé). Os segredos são gerados na hora (`.env`, não versionado).
Não valida: o **Kong** (gateway do Supabase hospedado, inclusive CORS) — aqui um mini-gateway (`gateway.js`) o substitui —, Realtime, e e-mails/recuperação de senha. Nada é enviado ao projeto remoto.

## Testes

- `supabase/tests/banco_testes.sql` — 128 verificações do banco (rodam e desfazem tudo).
- `supabase/tests/caixa_testes.sql` — 115 verificações de caixa/histórico/avisos (permissões, isolamento entre lojas, estorno, fechamento, reabertura).
- `supabase/tests/sem_caixa_testes.sql` — 17 verificações dos valores sem caixa (janelas, permissões, somente leitura); tela: `ui/ui_sem_caixa.test.js`.
- `supabase/tests/pagamentos_testes.sql` — 71 verificações de pagamentos parciais, estornos, comprovantes (políticas do bucket), envio confirmado e acesso indevido; tela: `ui/ui.test.js` (104).
- `supabase/tests/lab/` — banco local + concorrência (`concorrencia.sh` vendas; `concorrencia_caixa.sh` abertura/estorno/fechamento simultâneos; `concorrencia_pagamentos.sh` pagamentos/estornos/repetições simultâneos). As suítes locais acima usam um Storage simulado só nas **políticas**; a API real (limite de 5 MB, tipo MIME, upload, links assinados) é validada em `supabase/tests/stack/`.
- `supabase/tests/ui/` — a tela no Chromium com Supabase simulado e checagem dos
  nomes de parâmetros das funções contra o SQL:
  `NODE_PATH=/opt/node22/lib/node_modules node supabase/tests/ui/ui.test.js`

## Avisos

- Senhas "1234" são fracas; troque quando possível.
- A tabela antiga `sc_data` está aberta ("allow all for now").

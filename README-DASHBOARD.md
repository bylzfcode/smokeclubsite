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

**Ordem de aplicação no Supabase (nenhuma foi aplicada ainda no projeto remoto):** `schema.sql` → `002` → `003` → `004` → `005` → `006` → `007` → `008`.
A 005 depende da 003 (permissões e caixa), a 006 da 005 e a 007 da 005/006 (comprovantes e limpeza). Rode uma por vez no SQL Editor e confira que terminou sem erro antes da próxima.
A ordem foi conferida instalando do zero (schema → 008) numa pilha Supabase local real (veja "Validação contra a pilha real").

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

## Rateio de despesas e reembolsos entre lojas (migração 007)

- **Conta exclusiva continua sendo o padrão.** Rateio só existe se um gerente/dono criar uma "conta compartilhada" com 2+ lojas (Financeiro → "+ Conta compartilhada").
- **Divisão:** igual, por percentual ou por valores. A soma fecha **exatamente em centavos** e a tela mostra a **prévia calculada pelo servidor** antes de criar.
  Arredondamento determinístico: os centavos que sobram vão, um a um, às primeiras lojas por **ordem alfabética do nome** (no percentual, pelo **maior resto**, desempate pela mesma ordem).
  R$ 100 entre 3 lojas = 33,34 (EZ Store) + 33,33 + 33,33.
- **Três coisas separadas:** a **parcela** de cada loja (responsabilidade), o **pagamento externo** (quem pagou o fornecedor; parcial, uma loja pode pagar tudo) e o **reembolso interno** (origem → destino, parcial).
  Posição da loja = pago ao externo + reembolsos pagos − reembolsos recebidos − parcela (+ = a recuperar, − = deve).
  Exemplo: R$ 900 entre A, B, C → A paga tudo e tem R$ 600 a recuperar; B reembolsa R$ 100 e deve R$ 200; C deve R$ 300; a despesa consolidada segue R$ 900.
- **Limites no servidor** (inclusive sob concorrência e requisição repetida): pagamento externo ≤ saldo externo; reembolso ≤ o que a origem deve e ≤ o que o destino tem a recuperar; cada requisição tem chave de repetição (registrada uma vez só);
  o rateio é travado a cada operação e uma verificação final impede deixar reembolsos sem lastro (ex.: não dá para estornar o pagamento externo enquanto houver reembolso que depende dele).
- **Reembolso não quita de novo a conta externa e não é receita nem despesa:** o consolidado (fluxo/histórico) mostra o pagamento externo **uma vez**, na loja que pagou; reembolsos aparecem só na tela do rateio.
- **Não movimenta o caixa automaticamente** (aviso visível em todas as telas do rateio). Se saiu dinheiro da gaveta, lance também uma saída/retirada no Caixa.
- **Estornos, motivo e auditoria** preservados (original intacto; estorno ao lado). Rateio com movimentação **não é alterado nem cancelado**: estorne antes os reembolsos e pagamentos;
  a **revisão** cria uma nova versão das parcelas e guarda a anterior (com motivo).
- **Comprovantes** (bucket privado já existente): obrigatório só se o rateio exigir nos pagamentos externos; **opcional no reembolso**. Caminho `rateio/<rateio>/<movimento>/<arquivo>`. As lojas do rateio conferem os comprovantes umas das outras; quem não participa não lê. A limpeza de órfãos **não toca** em arquivos de rateio.
- **Acessos:** dono administra todas as lojas; gerente só cria/revisa rateios com lojas em que tem autorização; cada loja vê sua parcela e os pagamentos/reembolsos **do rateio de que participa** (para conferir), sem ganhar acesso ao financeiro completo das demais.
- **Alerta:** "despesa compartilhada com saldo externo vencido" no painel. Limitações: rateios não entram em "a pagar/receber" dos resumos antigos (têm tela própria) e **recorrência não foi implementada**.

## Rateios nos resumos financeiros (migração 008)

`rateios_resumo` é a fonte única dos números de rateio; `financeiro_resumo` e `painel_resumo` ganharam só a chave nova `rateios` (as chaves antigas não mudaram).
- **Consolidado (cada despesa externa UMA vez):** previsto (valor total das despesas cuja **data prevista** — vencimento, ou a criação se não houver — cai no período), pago (**data do pagamento** externo no período, líquido de estornos),
  saldo externo pendente e vencido (**foto de hoje**, independem do período). Mesmos filtros de período e permissões dos demais registros; cada indicador declara a data que usa (campo `datas`).
- **Por loja, separado:** parcela de responsabilidade (prevista) · pagamentos externos realizados · **acerto entre lojas** (a receber de outras lojas; a reembolsar a outras lojas, só quando o externo já foi quitado) ·
  **parcela ainda não coberta** (externo em aberto: pode ser quitada pagando o fornecedor ou reembolsando outra loja). Posição de rateio **nunca** é apresentada como dívida ao fornecedor; saldo externo e acerto entre lojas são informações diferentes.
- **Sem duplicar:** o pagamento externo entra em entradas/saídas efetivadas uma vez, na loja que pagou. **Reembolsos internos não são receita nem despesa**: aparecem à parte e não alteram entradas, saídas nem saldo.
- `financeiro_resumo` agora abate o **estorno de um pagamento** na própria família (despesa ou receita), em vez de contá-lo como "entrada"; sem estornos de pagamento os números são idênticos aos de antes.
- Telas: cartão "Contas compartilhadas — resumo" no Financeiro (esta loja / todas as minhas lojas; dono: consolidado de todas), cartão no Painel, etiquetas **exclusiva** × **compartilhada**, e os KPIs antigos de a pagar/receber rotulados como "contas exclusivas".
- Limitações: "Este mês" termina hoje, então uma despesa com vencimento futuro só entra em "previsto" quando o período a alcança (use "Tudo"); rateios não entram nos KPIs antigos de a pagar/receber (têm resumo próprio); recorrência não implementada.

## Validação contra a pilha real (Docker)

`supabase/tests/stack/` sobe **Postgres do Supabase + Auth (GoTrue) + PostgREST + Storage API** reais em contêineres, instala `schema.sql → 002 → 003 → 004 → 005 → 006` do zero como o papel `postgres`
(o mesmo do SQL Editor), cria usuários por SQL direto (como no projeto remoto) e roda: `real_api.test.js` (login, isolamento entre lojas, pagamentos, Storage, limpeza), `real_api_rateios.test.js` (rateios/reembolsos), `real_api_resumos.test.js` (resumos) e `real_ui.test.js` + `real_ui_rateios.test.js` + `real_ui_resumos.test.js` (o `dashboard.html` no Chromium).
Requisitos: Docker com daemon ativo, Node 18+, Playwright. Uso: `supabase/tests/stack/run_all.sh` (`--keep` deixa a pilha de pé). Os segredos são gerados na hora (`.env`, não versionado).
Não valida: o **Kong** (gateway do Supabase hospedado, inclusive CORS) — aqui um mini-gateway (`gateway.js`) o substitui —, Realtime, e e-mails/recuperação de senha. Nada é enviado ao projeto remoto.

## Testes

- `supabase/tests/banco_testes.sql` — 128 verificações do banco (rodam e desfazem tudo).
- `supabase/tests/caixa_testes.sql` — 115 verificações de caixa/histórico/avisos (permissões, isolamento entre lojas, estorno, fechamento, reabertura).
- `supabase/tests/sem_caixa_testes.sql` — 17 verificações dos valores sem caixa (janelas, permissões, somente leitura); tela: `ui/ui_sem_caixa.test.js`.
- `supabase/tests/pagamentos_testes.sql` — 71 verificações de pagamentos parciais, estornos, comprovantes (políticas do bucket), envio confirmado e acesso indevido; tela: `ui/ui.test.js` (104).
- `supabase/tests/rateios_testes.sql` — 83 verificações de rateio/reembolso (arredondamento, exemplo de R$ 900, parcial, estornos após reembolso, permissões, comprovantes); `lab/concorrencia_rateios.sh` — concorrência.
- `supabase/tests/rateios_resumos_testes.sql` — 40 verificações dos resumos de rateio (exemplo de R$ 900, reembolso, parcial, vencimento, estornos, período, uma loja só, dono).
- `supabase/tests/lab/` — banco local + concorrência (`concorrencia.sh` vendas; `concorrencia_caixa.sh` abertura/estorno/fechamento simultâneos; `concorrencia_pagamentos.sh` pagamentos/estornos/repetições simultâneos). As suítes locais acima usam um Storage simulado só nas **políticas**; a API real (limite de 5 MB, tipo MIME, upload, links assinados) é validada em `supabase/tests/stack/`.
- `supabase/tests/ui/` — a tela no Chromium com Supabase simulado e checagem dos
  nomes de parâmetros das funções contra o SQL:
  `NODE_PATH=/opt/node22/lib/node_modules node supabase/tests/ui/ui.test.js`

## Avisos

- Senhas "1234" são fracas; troque quando possível.
- A tabela antiga `sc_data` está aberta ("allow all for now").

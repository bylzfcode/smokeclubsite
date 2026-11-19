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

## Instalar a versão administrativa (migrações 001–013)

> **Nada disto foi aplicado no projeto Supabase hospedado.** Siga este roteiro no destino, na ordem. Os scripts de consulta abaixo são **somente leitura**.

### 0. Regras de ouro
- **Nunca rode `schema.sql` em um banco que já tem dados/tabelas.** Ele só serve para um projeto **vazio**: usa `create table` sem "if not exists" (falha em banco existente) e insere as lojas iniciais. Num banco existente, **primeiro inspecione** (passo 2) e aplique somente as migrações que faltam.
- Uma migração por vez, na ordem, conferindo que terminou **sem erro** antes da próxima. Não pule números.
- Nunca reaplique uma migração antiga sozinha com outras mais novas já aplicadas (ela recria funções que as novas substituíram). Se precisar repetir a migração N, repita **de N até 013**, em ordem — todas são repetíveis (testado: 002–013 rodadas duas vezes seguidas num banco já migrado, sem erro nem perda de dados).

### 1. Backup (obrigatório antes de qualquer migração)
- **Supabase → Database → Backups:** confirme que existe backup recente e anote data/hora (a disponibilidade de backups automáticos e de recuperação a qualquer instante — PITR — **depende do plano**; confira no seu projeto). Se não houver backup recente, faça o manual abaixo antes de continuar.
- **Backup manual do banco** (no seu computador, com `pg_dump` ≥ 15; a *connection string* está em Project Settings → Database; **não cole a senha em chat nem em arquivos do repositório**):
  ```bash
  pg_dump "postgresql://postgres:<SENHA>@<HOST>:5432/postgres" --format=custom --no-owner --file=backup-antes-das-migracoes.dump
  ```
  Guarde o arquivo fora do repositório. O dump **não inclui os arquivos do Storage** (comprovantes): a migração 005 não os altera, mas se quiser garantia extra baixe o bucket `comprovantes` pelo painel (Storage).
- Faça as migrações num horário de pouco movimento (as funções são recriadas; há milissegundos de indisponibilidade por função).

### 2. Descobrir o que já está aplicado (somente leitura)
No SQL Editor do **destino**, execute `supabase/ops/verificar_migracoes.sql`. Cada linha é uma migração: **aplicada** (todos os objetos existem), **ausente** (nenhum) ou **PARCIAL** (alguns — banco fora do padrão ou migração interrompida: **pare** e veja "Recuperação"). Aplique, em ordem, apenas as que estão **ausentes**, começando pela primeira ausente. Exemplo: se `schema.sql`…`008` estão aplicadas e `009`…`013` ausentes, comece pela `009`.

### 3. Ordem exata e pré-requisitos
| # | Arquivo | Pré-requisito | O que faz (resumo) | Cuidados |
|---|---|---|---|---|
| 1 | `schema.sql` | **banco vazio** | tabelas base, RLS, vendas/estoque/financeiro, lojas iniciais | só em projeto novo |
| 2 | `002_melhorias.sql` | 1 | funções de papel (`eh_gerente`), `data_ref`, resumos | |
| 3 | `003_caixa_avisos.sql` | 1, 2 | caixa, histórico, avisos | |
| 4 | `004_entradas_sem_caixa.sql` | 3 | valores sem caixa (leitura) | |
| 5 | `005_pagamentos_comprovantes.sql` | 3 | pagamentos parciais, comprovantes, bucket privado `comprovantes` | exige Storage ativo |
| 6 | `006_limpeza_comprovantes.sql` | 5 | limpeza segura de órfãos | |
| 7 | `007_rateios_reembolsos.sql` | 5, 6 | contas compartilhadas e reembolsos | |
| 8 | `008_rateios_resumos.sql` | 7 | rateios nos resumos | |
| 9 | `009_comunicados.sql` | 3 | comunicados/versões (usa avisos) | |
| 10 | `010_acessos.sql` | 1–9 | `perfis.ativo`, helpers de acesso ativos, auditoria | **recria** `eh_dono`, `eh_gerente`, `minhas_lojas`… e as políticas de escrita do catálogo (mesma regra + "ativo") |
| 11 | `011_recorrencia.sql` | 5 | séries de contas exclusivas, `editar_conta` | amplia `listar_contas` e o CHECK de auditoria |
| 12 | `012_calendario.sql` | 7, 11 | calendário, compromissos, `series_agendamento` | só leitura sobre contas/rateios |
| 13 | `013_series_compartilhadas.sql` | **7 e 11** (e 12 para o calendário) | séries de contas compartilhadas, retomada com prévia, `series_auditoria` | recria `serie_gerar`, `serie_controlar`, `listar_series`, `gerar_series_*`; estende `listar_rateios`, `rateio_detalhe`, `calendario_admin` |

Usuários e vínculos (depois das migrações): crie em Authentication → Users (e-mail `usuario@painel.local`, auto-confirm) e vincule:
```sql
insert into perfis (id, nome, papel) values ('<id do auth.users>', 'LUIZ', 'dono');
insert into perfis_lojas (perfil_id, loja_id) select '<id do auth.users>', id from lojas where slug in ('smoke-club','ez-store');
```
Em `dashboard.html` ajuste `SUPABASE_URL` e `SUPABASE_ANON_KEY` (só a chave anon/pública, **nunca** a `service_role`).

### 4. Conferência depois de cada migração e no final
1. Rode de novo `verificar_migracoes.sql`: a migração aplicada deve aparecer como **aplicada**.
2. No fim, rode `supabase/ops/conferencia_pos_migracao.sql` (somente leitura): nenhuma linha pode estar **FALHA**. Ela confere RLS ligado, ausência de privilégios diretos para `anon`/`authenticated`, quem pode executar as funções de geração, índices anti-duplicação, séries com erro e o estado do agendador (linhas "informativo" dependem do ambiente).
3. Faça o **roteiro de conferência da interface** (abaixo).

### 5. Recuperação em caso de falha
- Se uma migração falhar: **não rode a próxima**. Leia a mensagem de erro, rode `verificar_migracoes.sql` (a migração aparecerá "parcial" ou "ausente") e corrija a causa (ex.: Storage não habilitado para a 005, permissão insuficiente — use o papel `postgres` do SQL Editor).
- Depois de corrigir, **rode o mesmo arquivo de novo** (todos são repetíveis). Se voltar a "aplicada", siga.
- As migrações **só adicionam** tabelas/colunas/funções e recriam funções e políticas; não apagam nem reescrevem dados existentes. Se, mesmo assim, algo estiver inconsistente ou você quiser desfazer tudo, **restaure o backup do passo 1**: Dashboard → Database → Backups → Restore (ou `pg_restore --clean --if-exists --no-owner -d "<conexão>" backup-antes-das-migracoes.dump`) — esta é a única forma de "voltar atrás"; não há script de rollback por migração.
- Depois de restaurar, repita o passo 2 (inspeção) antes de tentar de novo.

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

**Ordem de aplicação no Supabase (nenhuma foi aplicada ainda no projeto remoto):** `schema.sql` → `002` → `003` → `004` → `005` → `006` → `007` → `008` → `009` → `010` → `011` → `012` → `013`.
A 005 depende da 003 (permissões e caixa), a 006 da 005 e a 007 da 005/006 (comprovantes e limpeza). Rode uma por vez no SQL Editor e confira que terminou sem erro antes da próxima.
A ordem foi conferida instalando do zero (schema → 013) numa pilha Supabase local real (veja "Validação contra a pilha real").

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
- **Alerta:** "despesa compartilhada com saldo externo vencido" no painel. Limitações: rateios não entram em "a pagar/receber" dos resumos antigos (têm tela própria) (recorrência: veja a migração 011).

## Rateios nos resumos financeiros (migração 008)

`rateios_resumo` é a fonte única dos números de rateio; `financeiro_resumo` e `painel_resumo` ganharam só a chave nova `rateios` (as chaves antigas não mudaram).
- **Consolidado (cada despesa externa UMA vez):** previsto (valor total das despesas cuja **data prevista** — vencimento, ou a criação se não houver — cai no período), pago (**data do pagamento** externo no período, líquido de estornos),
  saldo externo pendente e vencido (**foto de hoje**, independem do período). Mesmos filtros de período e permissões dos demais registros; cada indicador declara a data que usa (campo `datas`).
- **Por loja, separado:** parcela de responsabilidade (prevista) · pagamentos externos realizados · **acerto entre lojas** (a receber de outras lojas; a reembolsar a outras lojas, só quando o externo já foi quitado) ·
  **parcela ainda não coberta** (externo em aberto: pode ser quitada pagando o fornecedor ou reembolsando outra loja). Posição de rateio **nunca** é apresentada como dívida ao fornecedor; saldo externo e acerto entre lojas são informações diferentes.
- **Sem duplicar:** o pagamento externo entra em entradas/saídas efetivadas uma vez, na loja que pagou. **Reembolsos internos não são receita nem despesa**: aparecem à parte e não alteram entradas, saídas nem saldo.
- `financeiro_resumo` agora abate o **estorno de um pagamento** na própria família (despesa ou receita), em vez de contá-lo como "entrada"; sem estornos de pagamento os números são idênticos aos de antes.
- Telas: cartão "Contas compartilhadas — resumo" no Financeiro (esta loja / todas as minhas lojas; dono: consolidado de todas), cartão no Painel, etiquetas **exclusiva** × **compartilhada**, e os KPIs antigos de a pagar/receber rotulados como "contas exclusivas".
- Limitações: "Este mês" agora abrange o mês inteiro (veja "Períodos"); "Até hoje" é um filtro separado; rateios não entram nos KPIs antigos de a pagar/receber (têm resumo próprio); recorrência não implementada.

## Comunicados (migração 009)

Aba **📣 Comunicados**: editor de comunicados **administrativos** (título, cabeçalho, corpo e rodapé), integrado aos **avisos** existentes — publicar chama o mesmo `publicar_aviso` (prioridade, validade, destaque, leitura individual, "atualizado"), republicar atualiza o **mesmo** aviso e despublicar usa `arquivar_aviso`. Nenhuma tabela de aviso foi duplicada. Não toca em catálogo, produtos, preços, estoque, pedidos nem listas comerciais.
- **Rascunhos por loja** (`comunicados` + `comunicados_versoes`, sem acesso direto às tabelas): cada loja só vê os seus. Salvar sem mudança não cria versão; duas pessoas editando a mesma versão → a segunda é recusada ("alterado por outra pessoa"), nada é sobrescrito em silêncio.
- **Texto puro:** o servidor guarda exatamente o que foi digitado (só `\r\n` → `\n`). A tela escapa tudo e só então aplica a formatação do WhatsApp (`*negrito*`, `_itálico_`, `~tachado~`, ```` ```mono``` ````) com tags fixas; HTML/JS digitado aparece como texto. Quebras de linha e emojis preservados.
- **Prévia** ao vivo, contadores (cabeçalho/rodapé 400, corpo 2000, mensagem composta 2000) e **Copiar texto** (= cabeçalho + corpo + rodapé separados por linha em branco, byte a byte) ou **Copiar com título**.
- **Histórico:** cada gravação/restauração/publicação vira uma versão com autor e data; **restaurar** cria uma versão nova com o conteúdo antigo (nada é apagado). Comunicado publicado e depois editado mostra "alterações não publicadas" até republicar.
- **Aviso antes de sair com alterações não salvas:** ao trocar de aba/loja, voltar à lista, sair da conta, fechar ou recarregar a página.
- **Permissões (no servidor):** dono acessa todas as lojas; gerente edita/publica/despublica só nas lojas que administra; operador cria e edita rascunhos das lojas a que tem acesso, mas **não publica**; sem acesso à loja não lista nem abre. Aviso **global** só o dono (e só o dono o despublica — regra dos avisos).
- Limitações: validade é por data (até 23:59 de Brasília); não há agendamento de publicação nem anexos; editar o texto já publicado só chega às pessoas ao republicar.

## Acessos, períodos, recorrência, calendário e retomada (migrações 010 a 013)

**Acessos (010).** `perfis.ativo`: o dono desativa/reativa pessoas (aba **🔐 Acessos**) e altera as lojas de cada uma, sempre com auditoria (`acessos_auditoria`, imutável). Desativar **bloqueia na hora** todas as funções e leituras (inclusive chamadas diretas à API com token ainda válido) e **preserva o histórico** (vendas, caixas, contas, comunicados continuam apontando para a pessoa). Reativar devolve as mesmas lojas. Ninguém desativa a si mesmo nem o último dono ativo; desativar exige motivo. O login continua existindo (é do Supabase Auth), mas a pessoa não vê nada e a tela avisa "Seu acesso foi desativado". Ao trocar de loja a tela e a memória da loja anterior são limpas.

**Períodos.** "**Este mês**" = o mês **inteiro** (dia 1 ao último dia, inclusive datas futuras, que são previsões); "**Até hoje**" é um filtro à parte (do dia 1º até hoje); "Hoje", "7 dias" e "Tudo" como antes. O intervalo aplicado aparece escrito sob os botões, e cada indicador do Financeiro/rateios continua dizendo qual data usa (pagamento, vencimento, foto de hoje). O Histórico tem "Este mês (mês inteiro)" e "Mês até hoje".

**Contas recorrentes (011 e 013)** — opcionais (conta única é o padrão), para **contas exclusivas** (formulário "+ Conta / lançamento") e para **contas compartilhadas** (formulário "Nova conta compartilhada"), no mesmo mecanismo de séries.
- Frequência semanal, a cada 15 dias, mensal, anual ou personalizada (a cada N dias/semanas/meses/anos). Término sem prazo, até uma data ou após N ocorrências (1–120). **Prévia** dos vencimentos antes de salvar.
- Datas sempre calculadas a partir do 1º vencimento: mensal a partir de 31/01 → 28|29/02, 31/03, 30/04… (dia inexistente vira o último dia do mês; a referência original é preservada em `vencimento_ref`).
- Cada ocorrência é uma conta comum **sempre pendente**, sem pagamentos nem comprovantes copiados, valor exato em centavos. Geração **no servidor**, com **janela futura de 60 dias** (a 1ª ocorrência é sempre criada; no máx. 24 por execução), trava por série e índice único (`serie_id, serie_n`) → sem duplicação com cliques repetidos, abas simultâneas ou agendador + tela. Séries iniciadas no passado geram também as ocorrências já vencidas (aparecem como vencidas).
- Editar **só esta** ou **esta e as próximas** (descrição, categoria, valor, forma, comprovante; a data só na própria ocorrência). Ocorrências com pagamento, parciais, canceladas ou editadas à mão são **preservadas** (a tela diz quantas).
- **Pausar / retomar / encerrar** nunca apagam nada. Encerrar pode cancelar as contas futuras ainda sem movimentação (compartilhadas: só as sem pagamento, reembolso, comprovante nem revisão).
- **Retomar com prévia (013):** o botão "Retomar…" mostra, **antes de confirmar**, quantos vencimentos ficaram sem conta durante a pausa e escolhe o que fazer: **Pular** (não cria contas no passado; os números ficam registrados como pulados) ou **Gerar** (cria as contas desse intervalo, pendentes e já vencidas; máx. 120 por vez — acima disso só "pular"). A prévia lista também o que **já existe** (inclusive cancelado, editado à mão ou movimentado), que **nunca é recriado nem alterado**, e os próximos vencimentos da janela de 60 dias (gerados nos dois casos). Cada número da série tem no máximo um registro (índice único), então repetir/concorrer não duplica.
- **Contas compartilhadas recorrentes (013):** o modelo guarda o valor total, o método de divisão (igual, percentual ou valores) e as lojas; cada ocorrência é um rateio comum (versão 1) calculado pelo mesmo `rateio_calcular` da criação manual (centavos distribuídos de forma determinística; a soma das parcelas é sempre o total), **sem pagamentos externos, reembolsos nem comprovantes**. Só cria/controla quem administra **todas** as lojas envolvidas (ou o dono). Cada ocorrência registra "criado" na auditoria do rateio com a série e se foi automático; a série registra criação, pausa, retomada e encerramento em `series_auditoria`. Ocorrências já pagas, reembolsadas ou revisadas à mão não são alteradas. Para mudar valor/lojas do modelo, encerre a série e crie outra. Se a geração falhar numa série (ex.: loja desativada no rateio), o erro fica na própria série (aviso vermelho no cartão) e as demais séries seguem.
- **Geração das contas — dois caminhos separados** (os dois usam o mesmo gerador e nunca duplicam):

| | Geração **automática agendada** | Geração **ao abrir o Financeiro** |
|---|---|---|
| Quem dispara | o agendador (`pg_cron`) chama `gerar_series_pendentes()` todos os dias | a tela chama `gerar_series_loja(loja)` ao abrir/atualizar o Financeiro |
| Depende do ambiente? | **Sim — precisa ser configurado uma vez no Supabase hospedado** (abaixo); sem configuração **não existe** | Não: já vale após aplicar a migração |
| Alcance | todas as séries ativas, com ou sem alguém logado | séries da loja aberta (e das compartilhadas que a incluem), só com alguém logado |
| Quem pode executar | dono do banco (`pg_cron`) e `service_role`; **nunca** `anon`/`authenticated` | qualquer pessoa logada com acesso à loja |
| Fuso | agenda em UTC; "hoje" calculado em America/Sao_Paulo | idem |

**Calendário administrativo (012)** — aba **📆 Calendário**: vencimentos de contas exclusivas e compartilhadas (um evento por conta/rateio, que abre o **detalhe financeiro existente**; nada é duplicado) + **compromissos internos** (título, data, responsável, observação; versões e histórico com autor). Visão mensal com pontos por situação e lista dos próximos 30 dias; escopo "esta loja" ou "todas as minhas lojas" (dono: todas). Situações: **pendente, vencido, quitado, cancelado** (compromisso: pendente, vencido = passou sem concluir, concluído, cancelado). Respeita o acesso por loja (rateio só aparece para as lojas participantes). Se o período tiver mais de 800 eventos a tela avisa que a lista está incompleta.

**Configurar o agendador (opcional, uma vez, no Supabase hospedado).** Painel do Supabase → Database → Extensions → habilite `pg_cron`; depois, no SQL Editor (papel `postgres`):
```sql
select cron.schedule('series-diarias', '10 6 * * *', $$ select public.gerar_series_pendentes() $$);
-- conferir: select jobname, schedule, active from cron.job where jobname = 'series-diarias';
-- histórico das execuções: select status, return_message, start_time from cron.job_run_details order by start_time desc limit 5;
-- remover: select cron.unschedule('series-diarias');
```
- **Fuso:** o `pg_cron` interpreta o horário em **UTC**. `10 6 * * *` = 06:10 UTC = **03:10 em Brasília** (UTC−3, sem horário de verão desde 2019). Dentro do banco, "hoje" e a janela de 60 dias são calculados **explicitamente em America/Sao_Paulo**, não no fuso do servidor; se o agendador rodar entre 00:00 e 03:00 UTC (noite anterior em Brasília) a janela simplesmente começa um dia antes — sem efeito prático.
- **Permissões da função de geração:** `gerar_series_pendentes()` só é executável pelo dono do banco (onde o `pg_cron` roda) e pelo `service_role` (caso prefira agendar por uma Edge Function com a chave de serviço **guardada como segredo**, nunca no navegador). Para conferir: `select has_function_privilege('anon','public.gerar_series_pendentes()','execute'), has_function_privilege('authenticated','public.gerar_series_pendentes()','execute'), has_function_privilege('service_role','public.gerar_series_pendentes()','execute');` → `false, false, true` (o `conferencia_pos_migracao.sql` já faz isso). As funções internas `serie_gerar`/`serie_gerar_seguro` não são executáveis por ninguém logado.
- A tela informa, no cartão "Contas recorrentes", se o agendador está configurado (`series_agendamento()`); sem ele nada quebra: a geração acontece ao abrir o Financeiro.

### O que ainda depende do ambiente hospedado (não validado localmente)
- [ ] Aplicar as migrações pendentes, na ordem (passo 2/3), com backup feito.
- [ ] Storage ativo com o bucket privado `comprovantes` (criado pela 005) e limites de tamanho/tipo conforme o plano.
- [ ] `pg_cron` habilitado e o job `series-diarias` criado (opcional); conferir `cron.job_run_details` depois da 1ª execução.
- [ ] Usuários criados no Authentication (e-mail `usuario@painel.local`, auto-confirm) e vinculados a perfis/lojas; senhas "1234" trocadas.
- [ ] `SUPABASE_URL` e `SUPABASE_ANON_KEY` corretos no `dashboard.html` publicado; domínio do site permitido no CORS/URLs do projeto (o gateway local não reproduz o Kong).
- [ ] Realtime habilitado para as tabelas usadas pela tela (estoque, vendas, financeiro) — só afeta a atualização automática.
- [ ] Backups automáticos ativos/PITR conforme o plano; teste de restauração fora do horário de uso.
- [ ] Versão do Postgres do projeto (testado em 15 e 17).
- [ ] Rodar `verificar_migracoes.sql` e `conferencia_pos_migracao.sql` no destino e guardar o resultado.

## Roteiro rápido para conferir a interface
1. Entre como gerente (ex.: `luiz`), escolha a Smoke Club → **Financeiro**: confira o texto "Período aplicado" em *Este mês* (mês inteiro) e em *Até hoje*.
2. **+ Conta / lançamento** → "Repetir esta conta" → Mensal, vencimento no dia 31, término "Após 4 ocorrências" → *Ver prévia* (28/02 e 30/04 aparecem como ajustadas) → Salvar. No cartão "Contas recorrentes", pause a série; abra uma ocorrência → ✏️ *Editar conta* → "esta e as próximas".
3. **Nova conta compartilhada** → marque 2 ou 3 lojas, valor 100,01, vencimento daqui a 2 dias → "Repetir esta conta compartilhada" semanal, 20 ocorrências → *Ver prévia* → *Calcular prévia* → Criar. Confira que só ~9 contas nascem (janela de 60 dias), cada uma com a mesma divisão (33,34 + 33,33 + 33,33), sem pagamentos.
4. No cartão de séries, **Pausar** a compartilhada e clique em **Retomar…**: a janela mostra a quantidade de vencimentos do período pausado, as opções **Pular** × **Gerar** (o texto e o botão mudam com a quantidade) e o que já existe. Confirme a opção desejada; nada existente é duplicado, cancelado ou alterado. **Encerrar** com "cancelar futuras" preserva o que já tem pagamento/reembolso.
5. **📆 Calendário**: navegue pelos meses, clique num dia, abra uma conta (abre o detalhe financeiro), crie um compromisso, conclua-o. Alterne "Esta loja" / "Todas as minhas lojas".
6. **Trocar de loja**: a tela anterior desaparece; na Start o calendário não mostra nada da Smoke.
7. Entre como dono (`chefe`) → **🔐 Acessos**: desative uma operadora (motivo obrigatório); ela não consegue entrar ("acesso foi desativado"); reative.
8. Reduza a janela para ~375 px (celular): Financeiro, Calendário e os formulários não têm rolagem horizontal da página.

## Validação contra a pilha real (Docker)

`supabase/tests/stack/` sobe **Postgres do Supabase + Auth (GoTrue) + PostgREST + Storage API** reais em contêineres, instala `schema.sql → 002 → … → 013` do zero como o papel `postgres`
(o mesmo do SQL Editor), cria usuários por SQL direto (como no projeto remoto) e roda: `real_api.test.js` (login, isolamento entre lojas, pagamentos, Storage, limpeza), `real_api_rateios.test.js` (rateios/reembolsos), `real_api_resumos.test.js` (resumos) `real_api_comunicados.test.js` / `real_ui_comunicados.test.js` (comunicados), `real_api_admin.test.js` / `real_ui_admin.test.js` (acessos, recorrência, calendário, períodos), `real_api_series_comp.test.js` (séries compartilhadas e retomada) e `real_ui.test.js` + `real_ui_rateios.test.js` + `real_ui_resumos.test.js` (o `dashboard.html` no Chromium).
Requisitos: Docker com daemon ativo, Node 18+, Playwright. Uso: `supabase/tests/stack/run_all.sh` (`--keep` deixa a pilha de pé). Os segredos são gerados na hora (`.env`, não versionado).
Não valida: o **Kong** (gateway do Supabase hospedado, inclusive CORS) — aqui um mini-gateway (`gateway.js`) o substitui —, Realtime, e e-mails/recuperação de senha. Nada é enviado ao projeto remoto.

## Testes

- `supabase/tests/banco_testes.sql` — 128 verificações do banco (rodam e desfazem tudo).
- `supabase/tests/caixa_testes.sql` — 115 verificações de caixa/histórico/avisos (permissões, isolamento entre lojas, estorno, fechamento, reabertura).
- `supabase/tests/sem_caixa_testes.sql` — 17 verificações dos valores sem caixa (janelas, permissões, somente leitura); tela: `ui/ui_sem_caixa.test.js`.
- `supabase/tests/pagamentos_testes.sql` — 71 verificações de pagamentos parciais, estornos, comprovantes (políticas do bucket), envio confirmado e acesso indevido; tela: `ui/ui.test.js` (104).
- `supabase/tests/rateios_testes.sql` — 83 verificações de rateio/reembolso (arredondamento, exemplo de R$ 900, parcial, estornos após reembolso, permissões, comprovantes); `lab/concorrencia_rateios.sh` — concorrência.
- `supabase/tests/rateios_resumos_testes.sql` — 40 verificações dos resumos de rateio (exemplo de R$ 900, reembolso, parcial, vencimento, estornos, período, uma loja só, dono).
- `supabase/tests/comunicados_testes.sql` — 40 verificações dos comunicados (texto exato, versões, restauração, concorrência otimista, permissões por papel/loja, publicação como aviso, republicação, despublicação, global só dono).
- `supabase/tests/acessos_series_testes.sql` — 47 verificações de acessos (desativar/reativar, API direta, lojas, auditoria) e recorrência (datas, prévia, geração, janela, edição por escopo, pausa/retomada/encerramento, permissões).
- `supabase/tests/calendario_testes.sql` — 26 verificações do calendário e compromissos (situações, rateio, isolamento por loja, versões, permissões). `lab/concorrencia_series.sh` — criação/geração/edição simultâneas, inclusive séries compartilhadas e retomada.
- `supabase/tests/series_compartilhadas_testes.sql` — 34 verificações de séries compartilhadas (centavos, sem movimentação, permissões por loja, movimentadas preservadas, retomada pular × gerar com lacunas, limite de 120, erro isolado, privilégios do gerador).
- `supabase/tests/lab/verificar_ops.sh` — valida os scripts somente leitura de `supabase/ops/` em banco completo, parcial e vazio (e prova que nada muda).
- `supabase/tests/lab/` — banco local + concorrência (`concorrencia.sh` vendas; `concorrencia_caixa.sh` abertura/estorno/fechamento simultâneos; `concorrencia_pagamentos.sh` pagamentos/estornos/repetições simultâneos). As suítes locais acima usam um Storage simulado só nas **políticas**; a API real (limite de 5 MB, tipo MIME, upload, links assinados) é validada em `supabase/tests/stack/`.
- `supabase/tests/ui/` — a tela no Chromium com Supabase simulado e checagem dos
  nomes de parâmetros das funções contra o SQL:
  `NODE_PATH=/opt/node22/lib/node_modules node supabase/tests/ui/ui.test.js`

## Avisos

- Senhas "1234" são fracas; troque quando possível.
- A tabela antiga `sc_data` está aberta ("allow all for now").

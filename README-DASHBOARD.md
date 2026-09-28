# Painel Smoke Club — estoque compartilhado + financeiro (4 lojas)

Este painel é **separado do site público** (`index (23).html`). Ele roda em
`dashboard.html` e usa o [Supabase](https://supabase.com) como banco de dados
compartilhado entre as 4 lojas — é o que garante que uma venda feita em
qualquer loja atualize o estoque das outras 3 na hora, sem erro.

## 1. Criar o projeto Supabase (grátis)

1. Crie uma conta em https://supabase.com e clique em **New project**.
2. Anote a **senha do banco** que você definir (não é a senha de login das lojas).
3. Espere o projeto terminar de provisionar (~2 min).

## 2. Rodar o schema do banco

1. No painel do projeto, abra **SQL Editor** → **New query**.
2. Cole todo o conteúdo do arquivo [`supabase/schema.sql`](supabase/schema.sql) deste repositório.
3. Clique em **Run**. Isso cria todas as tabelas, as regras de segurança (RLS),
   as funções de venda/ajuste de estoque e já cadastra 4 linhas em `lojas`
   (Loja 1 a Loja 4 — edite os nomes depois, veja o passo 4).

## 3. Criar um login para cada loja

1. Vá em **Authentication → Users → Add user** e crie 4 usuários (um por loja),
   por exemplo `loja1@smokeclub.com`, `loja2@smokeclub.com` etc., com uma senha
   para cada um. Marque **Auto Confirm User**.
2. Volta pro **SQL Editor** e rode (trocando os e-mails e IDs pelos que você criou):

   ```sql
   -- veja o id de cada usuário criado:
   select id, email from auth.users;

   -- veja o id de cada loja:
   select id, nome from lojas;

   -- vincule cada usuário à loja dele (repita uma vez por loja):
   insert into perfis (id, loja_id, nome, papel)
   values ('ID_DO_USUARIO_AQUI', 'ID_DA_LOJA_AQUI', 'Nome do funcionário', 'operador');
   ```

   Use `papel` = `'gerente'` ou `'dono'` para quem deve poder cadastrar produtos
   no catálogo (aba **Catálogo**) e ver os dados consolidados das 4 lojas nos
   relatórios (Painel/Financeiro). Use `'operador'` para quem só vai vender.

3. (Opcional) Renomeie as lojas e adicione o WhatsApp de cada uma:

   ```sql
   update lojas set nome = 'Smoke Club - Centro', whatsapp = '5511999999999' where slug = 'loja-1';
   ```

## 4. Conectar o `dashboard.html` ao seu projeto

1. No painel Supabase, vá em **Project Settings → API**.
2. Copie a **Project URL** e a chave **anon public**.
3. Abra `dashboard.html` neste repositório e edite estas duas linhas perto do
   topo do `<script>`:

   ```js
   const SUPABASE_URL = "COLE_AQUI_A_URL_DO_SEU_PROJETO_SUPABASE";
   const SUPABASE_ANON_KEY = "COLE_AQUI_A_ANON_KEY_DO_SEU_PROJETO_SUPABASE";
   ```

4. Suba o arquivo pra sua hospedagem (Netlify/GitHub Pages) junto com o resto
   do site, ou abra localmente — não precisa de build, é um HTML só.

## 5. Primeiro cadastro do catálogo

Faça login com um usuário `gerente` ou `dono` e use a aba **🏷️ Catálogo** para:

1. Criar as marcas (ex: Ignite, Elfbar) e/ou categorias (ex: Essências, Carvão).
2. Criar os modelos/produtos dentro de cada marca/categoria, já com o
   **estoque inicial**.
3. Adicionar os sabores de cada modelo (cada sabor tem estoque próprio).
4. Cada loja (mesmo `operador`) deve entrar e clicar em **"Meu preço"** em
   cada item pra definir o preço da própria loja — o estoque é compartilhado,
   mas o preço é individual, como você pediu.

## Como funciona por baixo dos panos

- **Estoque nunca fica negativo**: a venda é feita por uma função no banco
  (`registrar_venda`) que trava a linha do item, confere se há saldo
  suficiente e só então debita — se 2 lojas tentarem vender a última unidade
  ao mesmo tempo, só uma consegue e a outra recebe um aviso de "estoque
  insuficiente" na hora, sem gerar venda fantasma nem erro financeiro.
- **Tempo real**: assim que uma venda ou ajuste de estoque acontece em
  qualquer loja, as outras 3 telas abertas recebem a atualização sozinhas
  (usa o Realtime do Supabase), sem precisar dar F5.
- **Lista de WhatsApp**: a aba **📋 Lista WhatsApp** monta o texto na hora,
  buscando o estoque atual — um produto que zerou ou foi desativado
  simplesmente não entra na lista da próxima vez que ela for gerada.
- **Financeiro**: toda venda já lança uma entrada automática no financeiro.
  Despesas (compra de mercadoria, aluguel, etc.) e contas a pagar/receber são
  lançadas manualmente na aba **💰 Financeiro**, com status pago/pendente/atrasado
  e saldo calculado automaticamente.
- **Segurança**: cada loja só vê os próprios clientes, vendas e financeiro
  (linha de RLS por `loja_id`); o catálogo e o estoque são compartilhados e
  visíveis para todos os funcionários logados; usuários `dono`/`gerente`
  enxergam os dados consolidados das 4 lojas nas telas de Painel e Financeiro.

## Limitações desta primeira versão (fácil de evoluir depois)

- Não há upload de fotos de produto no painel (só emoji) — se quiser fotos,
  dá pra reaproveitar o editor de imagens que já existe no site público.
- Cancelamento de venda existe no banco (`cancelar_venda`) mas ainda não tem
  botão na tela — pode ser adicionado rapidamente se for necessário.
- Relatórios são simples (KPIs do dia + lista); gráficos e filtros por período
  podem ser adicionados depois.

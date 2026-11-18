/* Navegador (Chromium) contra a PILHA REAL — rateios e reembolsos. O dashboard.html do repositório, só com URL, chave anon e <script> trocados. */
const { chromium } = require("playwright"); const fs = require("fs"), path = require("path"), cp = require("child_process"), crypto = require("crypto");
const env = Object.fromEntries(fs.readFileSync(path.join(__dirname, ".env"), "utf8").trim().split("\n").map(l => l.split(/=(.*)/s).slice(0, 2)));
let html = fs.readFileSync(path.join(path.resolve(__dirname, "../../.."), "dashboard.html"), "utf8");
html = html.replace(/https:\/\/viqgnzppazhcvthaknzi\.supabase\.co/, "http://127.0.0.1:54321").replace(/const SUPABASE_ANON_KEY = "[^"]+"/, `const SUPABASE_ANON_KEY = "${env.ANON_KEY}"`)
  .replace(/https:\/\/cdn\.jsdelivr\.net\/npm\/@supabase\/supabase-js@2\.45\.4\/dist\/umd\/supabase\.min\.js/, "http://127.0.0.1:54321/__painel/supabase.js");
if (!html.includes("__painel") || !html.includes("127.0.0.1:54321")) { console.error("troca de URL/script falhou"); process.exit(2); }
const supaJs = fs.readFileSync(path.join(__dirname, "node/node_modules/@supabase/supabase-js/dist/umd/supabase.js"), "utf8");
const sql = q => cp.execFileSync("docker", ["compose", "--env-file", ".env", "exec", "-T", "db", "psql", "-w", "-U", "postgres", "-d", "postgres", "-At", "-c", q], { cwd: __dirname, encoding: "utf8" }).trim();
let pass = 0, fail = 0; const falhas = []; const check = (n, c, x) => { if (c) pass++; else { fail++; falhas.push(n + (x !== undefined ? " → " + String(x).slice(0, 250) : "")); } };
const TAG = "RT" + Date.now(), pdf = Buffer.concat([Buffer.from("%PDF-1.4\n"), crypto.randomBytes(2500)]);
const L = Object.fromEntries(sql("select slug||'|'||id from lojas").split("\n").map(l => l.split("|"))), S = L["smoke-club"], T = L["start-br01"], E = L["ez-store"];

async function abrir(browser, user, opts = {}) {
  const ctx = await browser.newContext({ viewport: opts.viewport || { width: 1100, height: 900 } }), page = await ctx.newPage(); page.on("dialog", d => d.accept());
  const erros = []; page.on("pageerror", e => erros.push(e.message));
  const falhar = { upload: 0, registro: 0 }; page.__falhar = falhar;
  await page.route("**/*", route => {
    const u = route.request().url(), m = route.request().method();
    if (u === "http://127.0.0.1:54321/__painel/dashboard.html") return route.fulfill({ contentType: "text/html", body: html });
    if (u === "http://127.0.0.1:54321/__painel/supabase.js") return route.fulfill({ contentType: "application/javascript", body: supaJs });
    if (u.startsWith("http://127.0.0.1:54321/storage/v1/object/comprovantes/") && m === "POST" && falhar.upload > 0) { falhar.upload--; return route.abort("connectionfailed"); }
    if (u.includes("/rest/v1/rpc/registrar_comprovante_rateio") && m === "POST" && falhar.registro > 0) { falhar.registro--; return route.abort("connectionfailed"); }
    if (u.startsWith("http://127.0.0.1:54321/")) return route.continue();
    return route.abort();
  });
  await page.goto("http://127.0.0.1:54321/__painel/dashboard.html");
  await page.fill("#loginUsuario", user); await page.fill("#loginSenha", "1234"); await page.press("#loginSenha", "Enter");
  if (opts.loja) { await page.waitForSelector(".loja-card"); await page.click(`.loja-card:has-text("${opts.loja}")`); }
  await page.waitForSelector("#app.show");
  return { page, erros, ctx };
}
const toast = p => p.textContent("#toast");
const esperaToast = async (p, re) => { try { await p.waitForFunction(r => new RegExp(r).test(document.getElementById("toast").textContent), re.source, { timeout: 8000 }); return true; } catch (e) { return false; } };
const modal = p => p.textContent(".modal-box");

(async () => {
  const browser = await chromium.launch();
  let { page, erros } = await abrir(browser, "luiz", { loja: "Smoke Club" });
  await page.click("#tab-financeiro"); await page.waitForSelector("#ratCard");
  check("seção 'Contas compartilhadas' aparece no Financeiro, com o botão para criar (gerente)", /Contas compartilhadas/.test(await page.textContent("#ratCard")) && await page.locator("[data-a=ratNovo]").count() === 1);

  /* ---- assistente: prévia com arredondamento R$ 100 / 3 ---- */
  await page.click("[data-a=ratNovo]"); await page.waitForSelector("#rtDesc");
  await page.fill("#rtDesc", `Divisão ${TAG}`); await page.fill("#rtValor", "100");
  check("o botão Criar fica desabilitado até calcular a prévia", await page.isDisabled("#rtCriar"));
  await page.click("[data-a=ratPrevia]");
  check("prévia exige pelo menos 2 lojas (conta exclusiva é o padrão)", /pelo menos 2 lojas/.test(await toast(page)));
  await page.check(`#rtl-${T}`); await page.check(`#rtl-${E}`); await page.click("[data-a=ratPrevia]"); await page.waitForSelector("#rtPrevia .tt-row");
  const prev = await page.textContent("#rtPrevia");
  check("prévia do servidor: 33,34 + 33,33 + 33,33 = 100,00 com explicação do centavo distribuído", /33,34/.test(prev) && (prev.match(/33,33/g) || []).length === 2 && /100,00/.test(prev) && /arredondamento/i.test(prev), prev);
  check("o centavo extra vai para a 1ª loja pela ordem alfabética (EZ Store)", /EZ Store[\s\S]*?33,34/.test(prev));
  check("assistente: conta exclusiva segue sendo o padrão e o aviso explícito de que não movimenta o caixa", /exclusiva<\/b> continua sendo o padrão|exclusiva continua sendo o padrão/.test(await modal(page)) && /não movimenta o caixa automaticamente/.test(await modal(page)));
  check("após a prévia o botão Criar habilita; mudar um valor invalida a prévia", !(await page.isDisabled("#rtCriar")));
  await page.fill("#rtValor", "101"); check("alterar o valor desabilita o Criar e limpa a prévia", await page.isDisabled("#rtCriar") && (await page.textContent("#rtPrevia")).trim() === "");
  await page.fill("#rtValor", "100"); await page.click("[data-a=ratPrevia]"); await page.waitForSelector("#rtPrevia .tt-row"); await page.dblclick("#rtCriar");
  await page.waitForSelector("#ratAviso"); await page.waitForTimeout(300);
  check("rateio criado UMA vez (clique duplo) com as parcelas do servidor no banco", sql(`select count(*) from rateios where descricao='Divisão ${TAG}'`) === "1" && sql(`select string_agg(l.nome||'='||p.valor, '|' order by l.nome) from rateio_parcelas p join lojas l on l.id=p.loja_id join rateios r on r.id=p.rateio_id where r.descricao='Divisão ${TAG}'`) === "EZ Store=33.34|Smoke Club=33.33|Start BR01=33.33");
  await page.click("[data-a=fechar]");

  /* ---- percentual e valores no assistente ---- */
  await page.click("[data-a=ratNovo]"); await page.waitForSelector("#rtDesc"); await page.fill("#rtDesc", `Percentual ${TAG}`); await page.fill("#rtValor", "1000,01"); await page.selectOption("#rtMetodo", "percentual");
  await page.check(`#rtl-${T}`); await page.fill(`.rtEntrada[data-loja="${S}"]`, "50"); await page.fill(`.rtEntrada[data-loja="${T}"]`, "50"); await page.click("[data-a=ratPrevia]"); await page.waitForSelector("#rtPrevia .tt-row");
  check("percentual 50/50 de 1000,01: soma exata 1000,01 (500,01 + 500,00)", /500,01/.test(await page.textContent("#rtPrevia")) && /1\.000,01/.test(await page.textContent("#rtPrevia")));
  await page.selectOption("#rtMetodo", "valores"); await page.fill(`.rtEntrada[data-loja="${S}"]`, "600"); await page.fill(`.rtEntrada[data-loja="${T}"]`, "400"); await page.click("[data-a=ratPrevia]");
  check("valores que não fecham o total são recusados pelo servidor com a mensagem", await esperaToast(page, /difere do total/));
  await page.click("[data-a=fechar]");

  /* ---- EXEMPLO OBRIGATÓRIO: R$ 900 entre Smoke (A), Start (B) e EZ (C) ---- */
  await page.click("[data-a=ratNovo]"); await page.waitForSelector("#rtDesc"); await page.fill("#rtDesc", `Fachada ${TAG}`); await page.fill("#rtValor", "900"); await page.check(`#rtl-${T}`); await page.check(`#rtl-${E}`);
  await page.click("[data-a=ratPrevia]"); await page.waitForSelector("#rtPrevia .tt-row"); await page.click("#rtCriar"); await page.waitForSelector("#ratAviso");
  const R1 = sql(`select id from rateios where descricao='Fachada ${TAG}'`);
  check("rateio de R$ 900 criado: três parcelas de R$ 300 e nenhuma movimentação", sql(`select count(*) from rateio_parcelas where rateio_id='${R1}' and valor=300`) === "3" && /R\$ 900,00/.test(await page.textContent(".modal-box .kpi")));
  check("o detalhe explicita que NÃO movimenta o caixa e que reembolso não quita nem é receita/despesa", /não movimentam o caixa automaticamente/.test(await page.textContent("#ratAviso")) && /não quita de novo/.test(await page.textContent("#ratAviso")) && /não é receita nem despesa/.test(await page.textContent("#ratAviso")));
  await page.click("[data-a=ratPagForm]"); await page.waitForSelector("#rpValor");
  check("formulário de pagamento externo avisa que não movimenta o caixa", /não movimenta o caixa automaticamente/.test(await page.textContent("#ratPagAviso")));
  await page.fill("#rpValor", "901"); await page.click("[data-a=ratPagSalvar]"); check("pagamento acima do saldo externo barrado na tela", /passa do saldo externo/.test(await toast(page)));
  await page.fill("#rpValor", "900"); await page.dblclick("[data-a=ratPagSalvar]"); await page.waitForSelector("#ratAviso"); await page.waitForTimeout(400);
  check("A paga tudo (clique duplo): 1 pagamento externo gravado, saldo externo 0", sql(`select count(*) from rateio_pagamentos where rateio_id='${R1}'`) === "1" && /R\$ 0,00/.test(await page.textContent(".modal-box .kpi:nth-child(3)")));
  let cards = await page.textContent(".modal-box"); 
  check("Smoke (A): parcela 300, pagou 900, a recuperar R$ 600,00; Start e EZ devem R$ 300,00", /Smoke Club[\s\S]{0,40}a recuperar R\$ 600,00/.test(cards) && (cards.match(/deve R\$ 300,00/g) || []).length === 2);
  check("parcela (responsabilidade) separada de quem pagou: campos 'Parcela' e 'Pagou ao externo'", /Parcela \(responsabilidade\)/.test(cards) && /Pagou ao externo/.test(cards));
  await page.click("[data-a=ratReembForm]"); await page.waitForSelector("#rbValor");
  check("formulário de reembolso avisa: não movimenta o caixa, não é receita/despesa", /não movimenta o caixa automaticamente/.test(await page.textContent("#ratReembAviso")) && /não é receita nem despesa/i.test(await page.textContent("#ratReembAviso")));
  await page.selectOption("#rbOrigem", T); await page.selectOption("#rbDestino", S); await page.fill("#rbValor", "350"); await page.click("[data-a=ratReembSalvar]");
  check("reembolso acima do que a origem deve é barrado na tela", /passa do que Start BR01 deve/.test(await toast(page)));
  await page.fill("#rbValor", "100"); await page.fill("#rbObs", "devolução parcial"); await page.dblclick("[data-a=ratReembSalvar]"); await page.waitForSelector("#ratAviso"); await page.waitForTimeout(400);
  cards = await page.textContent(".modal-box");
  check("B reembolsa R$ 100 (clique duplo → 1 registro): Start deve R$ 200,00; EZ deve R$ 300,00; Smoke a recuperar R$ 500,00", sql(`select count(*) from rateio_reembolsos where rateio_id='${R1}'`) === "1" && /Start BR01[\s\S]{0,40}deve R\$ 200,00/.test(cards) && /Smoke Club[\s\S]{0,40}a recuperar R\$ 500,00/.test(cards) && /EZ Store[\s\S]{0,40}deve R\$ 300,00/.test(cards));
  check("despesa consolidada segue R$ 900,00 e o saldo externo R$ 0,00 depois do reembolso", /R\$ 900,00/.test(await page.textContent(".modal-box .kpi.good")) && /R\$ 0,00/.test(await page.textContent(".modal-box .kpi:nth-child(3)")));
  check("seções separadas: pagamentos externos × reembolsos entre lojas", /Pagamentos externos \(quem pagou o fornecedor\)/.test(cards) && /Reembolsos entre lojas \(internos\)/.test(cards) && /Start BR01 → Smoke Club/.test(cards));
  check("nada foi para o caixa e o consolidado tem um único pagamento de −900", sql("select count(*) from caixa_movimentos") === "0" && sql(`select coalesce(sum(efeito),0)||'/'||count(*) from fluxo_pago_itens() where lancamento_id='${R1}'`) === "-900.00/1");

  /* ---- comprovantes: falha de upload, falha de registro, nova tentativa; opcional no reembolso ---- */
  const pagId = sql(`select id from rateio_pagamentos where rateio_id='${R1}' and tipo='pagamento'`), reeId = sql(`select id from rateio_reembolsos where rateio_id='${R1}' and tipo='reembolso'`);
  page.__falhar.upload = 1;
  await page.setInputFiles(`#arqr-${pagId}`, { name: "nf.pdf", mimeType: "application/pdf", buffer: pdf });
  await page.waitForFunction(() => /Falha no envio/.test(document.getElementById("toast").textContent));
  check("upload interrompido: orientação clara; nada registrado; o pagamento externo continua único", sql(`select count(*) from comprovantes_rateio where rateio_id='${R1}'`) === "0" && sql(`select count(*) from rateio_pagamentos where rateio_id='${R1}'`) === "1");
  page.__falhar.registro = 1;
  await page.setInputFiles(`#arqr-${pagId}`, { name: "nf.pdf", mimeType: "application/pdf", buffer: pdf }); await page.waitForSelector("[data-a=ratTentar]");
  check("arquivo subiu, registro falhou: botão 'Tentar registrar de novo'", sql(`select count(*) from storage.objects where name like 'rateio/${R1}/${pagId}/%'`) === "1" && sql(`select count(*) from comprovantes_rateio where rateio_id='${R1}'`) === "0");
  await page.click("[data-a=ratTentar]"); await page.waitForSelector("[data-a=finBaixar]");
  check("nova tentativa vincula sem reenviar o arquivo e sem duplicar o pagamento", sql(`select count(*) from storage.objects where name like 'rateio/${R1}/${pagId}/%'`) === "1" && sql(`select count(*) from comprovantes_rateio where pagamento_id='${pagId}'`) === "1" && sql(`select count(*) from rateio_pagamentos where rateio_id='${R1}'`) === "1");
  await page.evaluate(() => { window.__abertos = []; window.open = u => { window.__abertos.push(u); }; });
  await page.click("[data-a=finBaixar]"); await page.waitForFunction(() => window.__abertos.length === 1);
  const link = await page.evaluate(() => window.__abertos[0]), rr = await fetch(link);
  check("download do comprovante do rateio por link assinado (anexo)", rr.status === 200 && Buffer.from(await rr.arrayBuffer()).equals(pdf) && /attachment/i.test(rr.headers.get("content-disposition") || ""));
  check("comprovante do reembolso é OPCIONAL (rótulo e nenhum anexado)", /Comprovante \(opcional\)/.test(await page.textContent(".modal-box")) && sql(`select count(*) from comprovantes_rateio where reembolso_id='${reeId}'`) === "0");
  await page.setInputFiles(`#arqr-${reeId}`, { name: "pix.pdf", mimeType: "application/pdf", buffer: pdf }); await page.waitForFunction(() => document.querySelectorAll("[data-a=finBaixar]").length === 2);
  check("anexar comprovante ao reembolso funciona", sql(`select count(*) from comprovantes_rateio where reembolso_id='${reeId}'`) === "1");

  /* ---- estornos ---- */
  await page.click(`.card:has([data-a=ratEstPagForm][data-id="${pagId}"]) [data-a=ratEstPagForm]`); await page.fill("#reMotivo", "pagamento lançado errado"); await page.click("[data-a=ratEstPagOk]");
  check("estorno do pagamento externo é recusado enquanto houver reembolso que depende dele", await esperaToast(page, /reembolsos registrados dependem/));
  await page.click("[data-a=ratVoltar]"); await page.waitForSelector("#ratAviso");
  await page.click(`[data-a=ratEstReembForm][data-id="${reeId}"]`); await page.fill("#reMotivo", "abc"); await page.click("[data-a=ratEstReembOk]"); check("estorno sem motivo suficiente é barrado", /motivo/.test(await toast(page)));
  await page.fill("#reMotivo", "valor devolvido errado"); await page.click("[data-a=ratEstReembOk]"); await page.waitForSelector(".tag:has-text('estornado')");
  cards = await page.textContent(".modal-box");
  check("estorno do reembolso: original preservado, estorno ao lado, Start volta a dever R$ 300,00 e Smoke a recuperar R$ 600,00", sql(`select count(*) from rateio_reembolsos where rateio_id='${R1}'`) === "2" && sql(`select count(*) from rateio_reembolsos where rateio_id='${R1}' and tipo='reembolso' and valor=100`) === "1" && /Start BR01[\s\S]{0,40}deve R\$ 300,00/.test(cards) && /Smoke Club[\s\S]{0,40}a recuperar R\$ 600,00/.test(cards));
  await page.click(`[data-a=ratEstPagForm][data-id="${pagId}"]`); await page.fill("#reMotivo", "pagamento externo lançado errado"); await page.click("[data-a=ratEstPagOk]"); await page.waitForSelector(".tag:has-text('estornado')");
  check("depois dos reembolsos estornados o pagamento externo pode ser estornado: despesa consolidada R$ 0,00 e saldo externo R$ 900,00", /R\$ 0,00/.test(await page.textContent(".modal-box .kpi.good")) && /R\$ 900,00/.test(await page.textContent(".modal-box .kpi:nth-child(3)")));
  check("rateio com tudo estornado oferece revisar/cancelar; histórico mostra os estornos com motivo", await page.locator("[data-a=ratRevisar]").count() === 1 && /Pagamento externo estornado — pagamento externo lançado errado/.test(await page.textContent(".modal-box")));

  /* ---- revisão explícita (nova versão) ---- */
  await page.click("[data-a=ratRevisar]"); await page.waitForSelector("#rtMotivo");
  await page.selectOption("#rtMetodo", "valores"); await page.fill(`.rtEntrada[data-loja="${S}"]`, "500"); await page.fill(`.rtEntrada[data-loja="${T}"]`, "250"); await page.fill(`.rtEntrada[data-loja="${E}"]`, "150");
  await page.fill("#rtMotivo", "divisão combinada com a contabilidade"); await page.click("[data-a=ratPrevia]"); await page.waitForSelector("#rtPrevia .tt-row"); await page.click("#rtCriar"); await page.waitForSelector("#ratAviso");
  check("revisão cria a versão 2 e preserva a anterior; versão exibida", sql(`select versao from rateios where id='${R1}'`) === "2" && sql(`select count(*) from rateio_parcelas where rateio_id='${R1}' and versao=1 and not ativa`) === "3" && /versão 2/.test(await page.textContent(".modal-box")));
  await page.click("[data-a=fechar]");
  check("a lista do Financeiro mostra o rateio com a posição da loja", new RegExp(`Fachada ${TAG}`).test(await page.textContent("#ratCard")) && /Smoke Club: parcela R\$ 500,00/.test(await page.textContent("#ratCard")));
  check("a lista de contas exclusivas continua funcionando junto", await page.locator("#finLista").count() === 1);

  /* ---- responsividade: celular ---- */
  await page.context().close();
  ({ page, erros } = await abrir(browser, "luiz", { loja: "Smoke Club", viewport: { width: 390, height: 844 } }));
  await page.click("#tab-financeiro"); await page.waitForSelector("#ratCard"); await page.click(`.list-row:has-text("Fachada ${TAG}")`); await page.waitForSelector("#ratAviso");
  const sem = await page.evaluate(() => ({ doc: document.documentElement.scrollWidth <= document.documentElement.clientWidth + 1, box: document.getElementById("modalBox").scrollWidth <= document.getElementById("modalBox").clientWidth + 1 }));
  check("celular (390 px): sem rolagem horizontal na tela nem no detalhe do rateio", sem.doc && sem.box, JSON.stringify(sem));
  await page.screenshot({ path: path.join(process.env.SHOT_DIR || "/tmp", "rateio-celular.png") });
  check("sem erros de JavaScript no fluxo do luiz", erros.length === 0, erros.join("|"));
  await page.context().close();

  /* ---- operador da Start (enzo): vê a própria parcela, sem acesso às outras lojas ---- */
  const R2 = sql(`select r.id from rateios r where descricao='Percentual ${TAG}'`) || "";
  ({ page, erros } = await abrir(browser, "enzo"));
  await page.click("#tab-financeiro"); await page.waitForSelector("#ratCard");
  check("enzo (operador, só Start) não vê o botão '+ Conta compartilhada'", await page.locator("[data-a=ratNovo]").count() === 0);
  const lista = await page.textContent("#ratCard");
  check("enzo vê só a posição da própria loja na lista (Start BR01) e nenhuma parcela de outras lojas", /Start BR01: parcela/.test(lista) && !/Smoke Club: parcela/.test(lista) && !/EZ Store: parcela/.test(lista), lista.slice(0, 300));
  await page.click(`.list-row:has-text("Fachada ${TAG}")`); await page.waitForSelector("#ratAviso");
  const d = await modal(page);
  check("no detalhe, enzo confere parcelas, pagamentos e reembolsos do rateio, sem botões de estorno/revisão/cancelamento", /Smoke Club/.test(d) && /EZ Store/.test(d) && await page.locator("[data-a=ratEstPagForm], [data-a=ratEstReembForm], [data-a=ratRevisar], [data-a=ratCancelarForm]").count() === 0);
  const iso = await page.evaluate(async rid => {
    const key = document.documentElement.innerHTML.match(/SUPABASE_ANON_KEY = "([^"]+)"/)[1], c = window.supabase.createClient("http://127.0.0.1:54321", key);
    await c.auth.signInWithPassword({ email: "enzo@painel.local", password: "1234" });
    const a = await c.rpc("listar_contas", { p_loja_id: rid, p_inicio: null, p_fim: null, p_situacao: null }), b = await c.from("rateios").select("*");
    return { a: a.error && a.error.message, b: !!b.error };
  }, S);
  check("na API real, o navegador do enzo não lê o financeiro da Smoke nem as tabelas do rateio", /permiss/i.test(iso.a || "") && iso.b, JSON.stringify(iso));
  check("sem erros de JavaScript no fluxo do enzo", erros.length === 0, erros.join("|"));
  await page.context().close();

  /* ---- rafael (Streaks): nada de rateios alheios ---- */
  ({ page, erros } = await abrir(browser, "rafael"));
  await page.click("#tab-financeiro"); await page.waitForSelector("#ratCard");
  const listaR = await page.textContent("#ratCard");
  check("rafael (Streaks) não vê os rateios das outras lojas (só os que a Streaks integra) e só a posição da própria loja", !new RegExp(TAG).test(listaR) && !/Smoke Club: parcela|Start BR01: parcela|EZ Store: parcela/.test(listaR), listaR.slice(0, 300));
  await page.context().close();

  await browser.close();
  console.log(`\nVALIDAÇÃO DE RATEIOS NO NAVEGADOR (pilha real): ${pass} ok, ${fail} falhas`); falhas.forEach(f => console.log("  ✗ " + f));
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error("ERRO NO TESTE:", e.stack ? e.stack.split("\n").slice(0, 6).join("\n") : e); process.exit(2); });

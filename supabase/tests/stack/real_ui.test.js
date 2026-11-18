/* Navegador (Chromium) contra a PILHA REAL: o dashboard.html do repositório, com só 3 trocas (URL, chave anon e <script> do supabase-js 2.45.4 local).
   Sem simulação do supabase-js: Auth, PostgREST e Storage são os serviços reais. Rodado por ./run_all.sh */
const { chromium } = require("playwright"); const fs = require("fs"), path = require("path"), cp = require("child_process"), crypto = require("crypto");
const env = Object.fromEntries(fs.readFileSync(path.join(__dirname, ".env"), "utf8").trim().split("\n").map(l => l.split(/=(.*)/s).slice(0, 2)));
const root = path.resolve(__dirname, "../../..");
let html = fs.readFileSync(path.join(root, "dashboard.html"), "utf8");
const antes = html;
html = html.replace(/https:\/\/viqgnzppazhcvthaknzi\.supabase\.co/, "http://127.0.0.1:54321").replace(/const SUPABASE_ANON_KEY = "[^"]+"/, `const SUPABASE_ANON_KEY = "${env.ANON_KEY}"`)
  .replace(/https:\/\/cdn\.jsdelivr\.net\/npm\/@supabase\/supabase-js@2\.45\.4\/dist\/umd\/supabase\.min\.js/, "http://127.0.0.1:54321/__painel/supabase.js");
if (html === antes || !html.includes("__painel") || !html.includes("127.0.0.1:54321")) { console.error("troca de URL/script falhou"); process.exit(2); }
const supaJs = fs.readFileSync(path.join(__dirname, "node/node_modules/@supabase/supabase-js/dist/umd/supabase.js"), "utf8");
const sql = q => cp.execFileSync("docker", ["compose", "--env-file", ".env", "exec", "-T", "db", "psql", "-w", "-U", "postgres", "-d", "postgres", "-At", "-c", q], { cwd: __dirname, encoding: "utf8" }).trim();
let pass = 0, fail = 0; const falhas = []; const check = (n, c, x) => { if (c) pass++; else { fail++; falhas.push(n + (x !== undefined ? " → " + String(x).slice(0, 250) : "")); } };
const pdf = Buffer.concat([Buffer.from("%PDF-1.4\n"), crypto.randomBytes(3000)]);

async function abrir(browser, user, senha = "1234", hooks = {}) {
  const ctx = await browser.newContext({ viewport: { width: 1100, height: 900 } }), page = await ctx.newPage(); page.on("dialog", d => d.accept());
  const erros = []; page.on("pageerror", e => erros.push(e.message));
  await page.route("**/*", route => {
    const u = route.request().url();
    if (u === "http://127.0.0.1:54321/__painel/dashboard.html") return route.fulfill({ contentType: "text/html", body: html });
    if (u === "http://127.0.0.1:54321/__painel/supabase.js") return route.fulfill({ contentType: "application/javascript", body: supaJs });
    if (u.startsWith("http://127.0.0.1:54321/") && !u.includes("/__painel/")) return hooks.rede ? hooks.rede(route, u) : route.continue();
    return route.abort();
  });
  await page.goto("http://127.0.0.1:54321/__painel/dashboard.html");
  await page.fill("#loginUsuario", user); await page.fill("#loginSenha", senha); await page.press("#loginSenha", "Enter");
  return { page, erros, ctx };
}
const TAG = "UI" + Date.now();
const toast = p => p.textContent("#toast");

(async () => {
  const browser = await chromium.launch();
  const SMOKE = sql("select id from lojas where slug='smoke-club'");

  /* ---- login real ---- */
  let { page, erros } = await abrir(browser, "luiz", "errada");
  await page.waitForFunction(() => document.getElementById("loginErr").textContent.length > 0);
  check("login real: senha errada mostra a mensagem e o botão volta ao normal", /inválidos/.test(await page.textContent("#loginErr")) && await page.isEnabled("#btnLogin"));
  await page.fill("#loginSenha", "1234"); await page.press("#loginSenha", "Enter");
  await page.waitForSelector(".loja-card");
  check("login real do luiz (usuário criado por SQL): seletor com as 3 lojas", (await page.locator(".loja-card").count()) === 3);
  await page.click(".loja-card:has-text('Smoke Club')"); await page.waitForSelector("#app.show"); await page.waitForSelector(".kpi");
  check("painel carrega com dados reais (painel_resumo + avisos)", (await page.locator(".kpi").count()) >= 6 && /Avisos e atualiza/.test(await page.textContent("#viewRoot")));
  await page.click("#tab-caixa"); await page.waitForSelector("#cxAviso");
  check("aba Caixa diz que pagamentos de contas NÃO movimentam o caixa automaticamente", /não movimentam o caixa automaticamente/.test(await page.textContent("#cxAviso")));

  /* ---- financeiro: conta, pagamento parcial, clique duplo, estorno ---- */
  await page.click("#tab-financeiro"); await page.waitForSelector(".kpi"); await page.click("[data-a=finForm]");
  check("formulário de conta também avisa que não movimenta o caixa", /não movimenta o caixa automaticamente/.test(await page.textContent(".modal-box")));
  await page.fill("#lDesc", `Compra ${TAG}`); await page.fill("#lValor", "300,50"); await page.fill("#lVenc", "2020-01-01"); await page.check("#lComp"); await page.click("[data-a=finSalvar]");
  await page.waitForSelector(`.list-row:has-text('Compra ${TAG}')`);
  check("conta gravada no banco real (pendente, exige comprovante)", sql(`select count(*) from financeiro_lancamentos where descricao='Compra ${TAG}' and status='pendente' and exige_comprovante and valor=300.50`) === "1");
  await page.click(`.list-row:has-text('Compra ${TAG}')`); await page.waitForSelector("[data-a=finPagForm]");
  const contaId = sql(`select id from financeiro_lancamentos where descricao='Compra ${TAG}'`);
  await page.click("[data-a=finPagForm]");
  check("formulário de pagamento explica: só registra, não transfere dinheiro, não movimenta o caixa", /registra um pagamento já realizado/.test(await page.textContent("#pgAviso")) && /não movimenta o caixa automaticamente/.test(await page.textContent("#pgAviso")));
  await page.fill("#pgValor", "400"); await page.click("[data-a=finPagSalvar]");
  check("pagamento acima do saldo barrado na tela", /passa do saldo/.test(await toast(page)));
  await page.fill("#pgValor", "100,10"); await page.dblclick("[data-a=finPagSalvar]"); await page.waitForSelector(".tag.parcial");
  await page.waitForTimeout(500);
  check("clique duplo no pagamento (servidor real): 1 pagamento gravado, conta parcial", sql(`select count(*) from pagamentos_lancamento where lancamento_id='${contaId}'`) === "1" && sql(`select status from financeiro_lancamentos where id='${contaId}'`) === "parcial");
  check("detalhe mostra original 300,50 · pago 100,10 · saldo 200,40", /300,50/.test(await page.textContent(".modal-box")) && /100,10/.test(await page.textContent(".modal-box .kpi.good")) && /200,40/.test(await page.textContent(".modal-box .kpi.warn")));
  check("aviso de caixa no detalhe da conta", /não movimenta o caixa automaticamente/.test(await page.textContent(".modal-box")));
  const pagId = sql(`select id from pagamentos_lancamento where lancamento_id='${contaId}'`);

  /* ---- comprovantes: falhas e nova tentativa SEM duplicar pagamento ---- */
  let abortarUpload = 1, abortarRegistro = 1;
  await page.unroute("**/*");
  await page.route("**/*", route => {
    const u = route.request().url(), m = route.request().method();
    if (u === "http://127.0.0.1:54321/__painel/dashboard.html") return route.fulfill({ contentType: "text/html", body: html });
    if (u === "http://127.0.0.1:54321/__painel/supabase.js") return route.fulfill({ contentType: "application/javascript", body: supaJs });
    if (u.startsWith("http://127.0.0.1:54321/storage/v1/object/comprovantes/") && m === "POST" && abortarUpload > 0) { abortarUpload--; return route.abort("connectionfailed"); }
    if (u.includes("/rest/v1/rpc/registrar_comprovante") && m === "POST" && abortarRegistro > 0 && abortarUpload === 0) { abortarRegistro--; return route.abort("connectionfailed"); }
    if (u.startsWith("http://127.0.0.1:54321/") && !u.includes("/__painel/")) return route.continue();
    return route.abort();
  });
  await page.setInputFiles(`#arq-${pagId}`, { name: "comprovante.pdf", mimeType: "application/pdf", buffer: pdf });
  await page.waitForFunction(() => /Falha no envio/.test(document.getElementById("toast").textContent));
  check("upload real interrompido: avisa que o pagamento não foi afetado; nada no bucket nem no banco", sql(`select count(*) from storage.objects where bucket_id='comprovantes' and name like '%/${pagId}/%'`) === "0" && sql(`select count(*) from comprovantes_pagamento where pagamento_id='${pagId}'`) === "0" && sql(`select count(*) from pagamentos_lancamento where lancamento_id='${contaId}'`) === "1");
  await page.setInputFiles(`#arq-${pagId}`, { name: "comprovante.pdf", mimeType: "application/pdf", buffer: pdf });
  await page.waitForSelector("[data-a=finTentar]");
  check("arquivo subiu mas o registro falhou: botão 'Tentar registrar de novo' aparece; arquivo está no bucket e NÃO está vinculado", sql(`select count(*) from storage.objects where bucket_id='comprovantes' and name like '%/${pagId}/%'`) === "1" && sql(`select count(*) from comprovantes_pagamento where pagamento_id='${pagId}'`) === "0");
  await page.click("[data-a=finTentar]"); await page.waitForSelector("[data-a=finBaixar]");
  check("nova tentativa vincula SEM reenviar o arquivo e SEM duplicar o pagamento (1 arquivo, 1 vínculo, 1 pagamento)", sql(`select count(*) from storage.objects where bucket_id='comprovantes' and name like '%/${pagId}/%'`) === "1" && sql(`select count(*) from comprovantes_pagamento where pagamento_id='${pagId}'`) === "1" && sql(`select count(*) from pagamentos_lancamento where lancamento_id='${contaId}'`) === "1");
  // download pela interface (link assinado real)
  await page.evaluate(() => { window.__abertos = []; window.open = u => { window.__abertos.push(u); }; });
  await page.click("[data-a=finBaixar]"); await page.waitForFunction(() => window.__abertos.length === 1);
  const link = await page.evaluate(() => window.__abertos[0]), r = await fetch(link);
  check("download pela interface: link assinado do bucket privado, entrega o arquivo exato como ANEXO", /\/object\/sign\/comprovantes\//.test(link) && r.status === 200 && Buffer.from(await r.arrayBuffer()).equals(pdf) && /attachment/i.test(r.headers.get("content-disposition") || ""), link);
  check("pagamento, arquivo e envio aparecem separados; envio ainda pendente", /Arquivo anexado/.test(await page.textContent(".modal-box")) && /Envio manual:\s*pendente/.test(await page.textContent(".modal-box")));
  await page.click("[data-a=finEnvio]"); await page.waitForSelector("text=confirmado por");
  check("envio manual confirmado (banco real): quem e quando", sql(`select count(*) from envios_comprovante where pagamento_id='${pagId}' and confirmado_por is not null and confirmado_em is not null`) === "1");
  await page.click(".card:has-text('100,10') [data-a=finEstornarForm]"); await page.fill("#esPgMotivo", "valor lançado errado"); await page.click("[data-a=finEstornarOk]"); await page.waitForSelector(".tag:has-text('estornado')");
  check("estorno pela interface: original preservado, estorno gravado com motivo, saldo volta a 300,50", sql(`select count(*) from pagamentos_lancamento where lancamento_id='${contaId}'`) === "2" && sql(`select count(*) from pagamentos_lancamento where lancamento_id='${contaId}' and tipo='estorno' and motivo='valor lançado errado'`) === "1" && /300,50/.test(await page.textContent(".modal-box .kpi.warn")));
  await page.click("[data-a=fechar]"); await page.click("#tab-painel"); await page.waitForSelector(".aviso");
  check("alerta de saldo vencido aparece no painel (dados reais)", await page.locator(".aviso.urgente:has-text('vencida')").count() === 1);
  check("sem erros de JavaScript no fluxo do luiz", erros.length === 0, erros.join("|"));
  await page.context().close();

  /* ---- isolamento na interface: enzo (Start BR01) ---- */
  ({ page, erros } = await abrir(browser, "enzo"));
  await page.waitForSelector("#app.show");
  check("enzo (1 loja) entra direto na Start BR01, sem seletor e sem 'Trocar loja'", /Start BR01/.test(await page.textContent("#lojaNomeChip")) && await page.isHidden("#btnTrocarLoja") && await page.isHidden("#seletorLoja"));
  await page.click("#tab-financeiro"); await page.waitForSelector(".kpi");
  check("enzo não vê contas da Smoke na lista", !new RegExp(`Compra ${TAG}`).test(await page.textContent("#finLista")));
  const iso = await page.evaluate(async ([conta, loja, pag]) => {
    const c = window.supabase.createClient("http://127.0.0.1:54321", document.documentElement.innerHTML.match(/SUPABASE_ANON_KEY = "([^"]+)"/)[1]);
    await c.auth.signInWithPassword({ email: "enzo@painel.local", password: "1234" });
    const det = await c.rpc("conta_detalhe", { p_id: conta }), pnl = await c.rpc("painel_resumo", { p_loja_id: loja });
    const obj = (await c.rpc("conta_detalhe", { p_id: conta })); const paths = [];
    return { det: det.error && det.error.message, pnl: pnl.error && pnl.error.message };
  }, [contaId, SMOKE, pagId]);
  check("no navegador do enzo, API real nega conta_detalhe e painel da Smoke", /permiss|sem permiss/i.test(iso.det || "") && /permiss/i.test(iso.pnl || ""), JSON.stringify(iso));
  const caminho = sql(`select storage_path from comprovantes_pagamento where pagamento_id='${pagId}'`);
  const dlEnzo = await page.evaluate(async caminho => {
    const c = window.supabase.createClient("http://127.0.0.1:54321", document.documentElement.innerHTML.match(/SUPABASE_ANON_KEY = "([^"]+)"/)[1]);
    await c.auth.signInWithPassword({ email: "enzo@painel.local", password: "1234" });
    const a = await c.storage.from("comprovantes").download(caminho), b = await c.storage.from("comprovantes").createSignedUrl(caminho, 60);
    return { dl: !!a.error, sign: !!b.error };
  }, caminho);
  check("no navegador do enzo, o Storage real nega download e link assinado do comprovante da Smoke", dlEnzo.dl && dlEnzo.sign, JSON.stringify(dlEnzo));
  check("sem erros de JavaScript no fluxo do enzo", erros.length === 0, erros.join("|"));
  await page.context().close();

  /* ---- operador da mesma loja (carla) ---- */
  ({ page, erros } = await abrir(browser, "carla"));
  await page.waitForSelector("#app.show"); await page.click("#tab-financeiro"); await page.waitForSelector(`.list-row:has-text('Compra ${TAG}')`);
  await page.click(`.list-row:has-text('Compra ${TAG}')`); await page.waitForSelector("[data-a=finPagForm]");
  check("operador (carla) vê a conta da própria loja e pode registrar pagamento, mas NÃO vê Cancelar conta", await page.locator("[data-a=finPagForm]").count() === 1 && await page.locator("[data-a=finCancelarForm]").count() === 0);
  await page.context().close();

  await browser.close();
  console.log(`\nVALIDAÇÃO NO NAVEGADOR (pilha real): ${pass} ok, ${fail} falhas`); falhas.forEach(f => console.log("  ✗ " + f));
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error("ERRO NO TESTE:", e.stack.split("\n").slice(0,6).join("\n")); process.exit(2); });

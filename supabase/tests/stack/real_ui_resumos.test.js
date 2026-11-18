/* Navegador (Chromium) contra a PILHA REAL — integração dos rateios aos resumos. O dashboard.html do repositório (só URL/chave/script trocados).
   O cenário é montado pela API real e a tela é conferida por "antes × depois" lidos da própria interface. */
const { chromium } = require("playwright"); const fs = require("fs"), path = require("path"), cp = require("child_process"), crypto = require("crypto");
const { createClient } = require("./node/node_modules/@supabase/supabase-js");
const env = Object.fromEntries(fs.readFileSync(path.join(__dirname, ".env"), "utf8").trim().split("\n").map(l => l.split(/=(.*)/s).slice(0, 2)));
let html = fs.readFileSync(path.join(path.resolve(__dirname, "../../.."), "dashboard.html"), "utf8");
html = html.replace(/https:\/\/viqgnzppazhcvthaknzi\.supabase\.co/, "http://127.0.0.1:54321").replace(/const SUPABASE_ANON_KEY = "[^"]+"/, `const SUPABASE_ANON_KEY = "${env.ANON_KEY}"`)
  .replace(/https:\/\/cdn\.jsdelivr\.net\/npm\/@supabase\/supabase-js@2\.45\.4\/dist\/umd\/supabase\.min\.js/, "http://127.0.0.1:54321/__painel/supabase.js");
if (!html.includes("__painel")) { console.error("troca de URL/script falhou"); process.exit(2); }
const supaJs = fs.readFileSync(path.join(__dirname, "node/node_modules/@supabase/supabase-js/dist/umd/supabase.js"), "utf8");
const sql = q => cp.execFileSync("docker", ["compose", "--env-file", ".env", "exec", "-T", "db", "psql", "-w", "-U", "postgres", "-d", "postgres", "-At", "-c", q], { cwd: __dirname, encoding: "utf8" }).trim();
let pass = 0, fail = 0; const falhas = []; const check = (n, c, x) => { if (c) pass++; else { fail++; falhas.push(n + (x !== undefined ? " → " + String(x).slice(0, 260) : "")); } };
const TAG = "RS" + Date.now(), uuid = () => crypto.randomUUID();
const hoje = new Date().toLocaleDateString("en-CA", { timeZone: "America/Sao_Paulo" });
const addDias = (iso, d) => { const x = new Date(iso + "T12:00:00Z"); x.setUTCDate(x.getUTCDate() + d); return x.toISOString().slice(0, 10); };
const L = Object.fromEntries(sql("select slug||'|'||id from lojas").split("\n").map(l => l.split("|"))), S = L["smoke-club"], T = L["start-br01"], E = L["ez-store"];
const api = async u => { const c = createClient("http://127.0.0.1:54321", env.ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false } }); const r = await c.auth.signInWithPassword({ email: u + "@painel.local", password: "1234" }); if (r.error) throw new Error("login " + u); return c; };
const num = t => Number(String(t).replace(/[^\d,-]/g, "").replace(",", "."));
const n2 = v => Math.round(v * 100) / 100;

async function abrir(browser, user, opts = {}) {
  const ctx = await browser.newContext({ viewport: opts.viewport || { width: 1100, height: 1000 } }), page = await ctx.newPage(); page.on("dialog", d => d.accept());
  const erros = []; page.on("pageerror", e => erros.push(e.message));
  await page.route("**/*", route => { const u = route.request().url();
    if (u === "http://127.0.0.1:54321/__painel/dashboard.html") return route.fulfill({ contentType: "text/html", body: html });
    if (u === "http://127.0.0.1:54321/__painel/supabase.js") return route.fulfill({ contentType: "application/javascript", body: supaJs });
    if (u.startsWith("http://127.0.0.1:54321/") && !u.includes("/__painel/")) return route.continue(); return route.abort(); });
  await page.goto("http://127.0.0.1:54321/__painel/dashboard.html"); await page.fill("#loginUsuario", user); await page.fill("#loginSenha", "1234"); await page.press("#loginSenha", "Enter");
  if (opts.loja) { await page.waitForSelector(".loja-card"); await page.click(`.loja-card:has-text("${opts.loja}")`); }
  await page.waitForSelector("#app.show"); return { page, erros, ctx };
}
// lê a tela: KPIs do consolidado, linhas do "por loja" e os KPIs de entradas/saídas efetivadas
async function ler(page) {
  await page.click("#tab-painel"); await page.click("#tab-financeiro"); await page.waitForSelector("#ratResumo"); await page.waitForSelector("#finResumo .kpi");
  return page.evaluate(() => {
    const t = e => e.textContent, kp = [...document.querySelectorAll("#ratResumo > .kpi-grid .kpi .v")].map(t), eff = [...document.querySelectorAll("#finResumo .kpi .v")].map(t), lojas = {};
    document.querySelectorAll("#ratResumo > .card").forEach(c => { const nome = (c.querySelector(":scope > b") || c.querySelector("b")).textContent, sp = [...c.querySelectorAll("span")].map(t); const g = re => (sp.find(x => re.test(x)) || ""); lojas[nome] = { parcela: g(/Parcela de responsabilidade/), pago: g(/Pagamentos externos realizados/), receber: g(/A receber de outras/), reembolsar: g(/A reembolsar a outras/), nao: g(/ainda não coberta/), reemb: g(/Reembolsos no período/) }; });
    return { kp, eff, lojas, texto: document.getElementById("ratResumo").textContent, itens: [...document.querySelectorAll("#ratResumo .list-row")].map(r => r.textContent) };
  });
}
const recebidos = (st, nome) => num((((st.lojas[nome] || {}).reemb || "").match(/recebidos (R\$[^·]*)/) || ["", "0"])[1]);
const L_ = (st, nome, campo) => { const t = (st.lojas[nome] || {})[campo] || ""; return num((t.match(/R\$[^·]*/) || ["0"])[0]); };

(async () => {
  const browser = await chromium.launch(), luiz = await api("luiz"), enzo = await api("enzo");
  let { page, erros } = await abrir(browser, "luiz", { loja: "Smoke Club" });
  await page.click("#tab-financeiro"); await page.waitForSelector("#ratResumo");
  await page.click("[data-a=finPeriodo][data-id=tudo]"); await page.waitForSelector("#ratResumo");
  const B = await ler(page);
  check("cartão 'Contas compartilhadas — resumo' aparece, com o consolidado (cada despesa uma vez), datas explicadas e a distinção saldo externo × acerto entre lojas", /resumo/.test(B.texto) && /única vez/.test(B.texto) && /Datas:/.test(B.texto) && /previsto<?|previsto =/.test(B.texto) && /informações diferentes/.test(B.texto) && /não é dívida ao fornecedor/.test(B.texto));
  check("os KPIs antigos de contas exclusivas foram rotulados ('Contas exclusivas — a pagar/receber') e a nota explica a data usada", /Contas exclusivas — a pagar/.test(await page.textContent("#finResumo")) && /data do pagamento/.test(await page.textContent("#viewRoot")) && /reembolsos entre lojas não entram/.test(await page.textContent("#viewRoot")));

  /* ---- conta exclusiva (rótulo) + R$ 900 compartilhados ---- */
  const C1 = (await luiz.rpc("criar_conta", { p_loja_id: S, p_tipo: "saida", p_categoria: "aluguel", p_descricao: `Exclusiva ${TAG}`, p_valor: 200, p_vencimento: addDias(hoje, 3), p_forma: null, p_exige_comprovante: false, p_chave: uuid() })).data;
  const itens = [{ loja_id: S }, { loja_id: T }, { loja_id: E }];
  const R1 = (await luiz.rpc("criar_rateio", { p_descricao: `Fachada ${TAG}`, p_categoria: "manutenção", p_valor_total: 900, p_vencimento: addDias(hoje, 5), p_exige_comprovante: false, p_metodo: "igual", p_itens: itens, p_chave: uuid() })).data;
  let st = await ler(page);
  check("conta EXCLUSIVA e COMPARTILHADA identificadas na tela (etiquetas)", await page.locator(`#finLista .list-row:has-text("Exclusiva ${TAG}") .tag:has-text("exclusiva")`).count() === 1 && st.itens.some(t => t.includes(`Fachada ${TAG}`) && t.includes("compartilhada")));
  check("antes de pagar: previsto +900; pago +0; Smoke: parcela +300, nada pago, parcela ainda não coberta +300 (não é 'a reembolsar')", n2(num(st.kp[0]) - num(B.kp[0])) === 900 && n2(num(st.kp[1]) - num(B.kp[1])) === 0 && n2(L_(st, "Smoke Club", "parcela") - L_(B, "Smoke Club", "parcela")) === 300
    && n2(L_(st, "Smoke Club", "nao") - L_(B, "Smoke Club", "nao")) === 300 && n2(L_(st, "Smoke Club", "reembolsar") - L_(B, "Smoke Club", "reembolsar")) === 0, JSON.stringify(st.kp));
  await luiz.rpc("registrar_pagamento_rateio", { p_rateio_id: R1, p_loja_id: S, p_valor: 900, p_data: hoje, p_forma: "Pix", p_observacao: null, p_chave: uuid() });
  const A = await ler(page);
  const linhaR1 = A.itens.find(t => t.includes(`Fachada ${TAG}`)) || "";
  check("A paga tudo: despesa consolidada +900 (uma linha só: total 900 · pago 900 · saldo externo R$ 0,00)", A.itens.filter(t => t.includes(`Fachada ${TAG}`)).length === 1 && /total R\$ 900,00 · pago R\$ 900,00/.test(linhaR1) && /R\$ 0,00\s*saldo externo/.test(linhaR1) && n2(num(A.kp[1]) - num(B.kp[1])) === 900, linhaR1);
  check("saldo externo pendente do consolidado não ficou com os 900 (+0 vs antes de existir o rateio)", n2(num(A.kp[2]) - num(B.kp[2])) === 0);
  check("Smoke: pagou 900 ao externo e tem R$ 600 a receber de outras lojas", n2(L_(A, "Smoke Club", "pago") - L_(B, "Smoke Club", "pago")) === 900 && n2(L_(A, "Smoke Club", "receber") - L_(B, "Smoke Club", "receber")) === 600);
  check("entradas/saídas efetivadas: Smoke tem +900 de saída (o pagamento externo, uma vez)", n2(num(A.eff[1]) - num(B.eff[1])) === 900, JSON.stringify([B.eff, A.eff]));

  /* ---- B reembolsa R$ 100 ---- */
  await enzo.rpc("registrar_reembolso", { p_rateio_id: R1, p_loja_origem: T, p_loja_destino: S, p_valor: 100, p_data: hoje, p_observacao: null, p_chave: uuid() });
  const Rb = await ler(page);
  check("B reembolsa R$ 100: despesa permanece (+900 pagos), A passa a receber R$ 500, e o reembolso aparece só como informação (recebidos 100)", n2(num(Rb.kp[1]) - num(B.kp[1])) === 900 && n2(L_(Rb, "Smoke Club", "receber") - L_(B, "Smoke Club", "receber")) === 500 && n2(recebidos(Rb, "Smoke Club") - recebidos(B, "Smoke Club")) === 100, JSON.stringify(Rb.lojas["Smoke Club"]));
  check("reembolso não alterou entradas, saídas nem saldo efetivado exibidos", JSON.stringify(Rb.eff.slice(0, 4)) === JSON.stringify(A.eff.slice(0, 4)), JSON.stringify([A.eff, Rb.eff]));
  check("a nota diz que reembolsos entre lojas não são receita nem despesa", /não são receita nem despesa/.test(Rb.texto));

  /* ---- escopo "todas as minhas lojas": acerto entre lojas ---- */
  await page.click('[data-a=ratEscopo][data-id=todas]'); await page.waitForFunction(() => /todas as minhas lojas/.test((document.getElementById("ratResumo") || {}).textContent || ""));
  const Tt = await page.evaluate(() => document.getElementById("ratResumo").textContent);
  check("'Todas as minhas lojas': aparecem Smoke, Start e EZ no 'por loja'", /Smoke Club/.test(Tt) && /Start BR01/.test(Tt) && /EZ Store/.test(Tt));
  await page.click('[data-a=ratEscopo][data-id=loja]'); await page.waitForFunction(() => /\(Smoke Club\)/.test((document.getElementById("ratResumo") || {}).textContent || ""));

  /* ---- parcial + vencimento + estornos ---- */
  const R2 = (await luiz.rpc("criar_rateio", { p_descricao: `Internet ${TAG}`, p_categoria: "serviços", p_valor_total: 1000, p_vencimento: addDias(hoje, -3), p_exige_comprovante: false, p_metodo: "igual", p_itens: itens, p_chave: uuid() })).data;
  const p2 = (await luiz.rpc("registrar_pagamento_rateio", { p_rateio_id: R2, p_loja_id: S, p_valor: 400, p_data: hoje, p_forma: "Pix", p_observacao: null, p_chave: uuid() })).data.pagamento_id;
  const P = await ler(page), linhaR2 = P.itens.find(t => t.includes(`Internet ${TAG}`)) || "";
  check("pagamento externo parcial vencido: linha única com total 1.000 · pago 400 · saldo externo 600, 'parcialmente paga' e 'saldo externo vencido'", /total R\$ 1\.000,00 · pago R\$ 400,00/.test(linhaR2) && /R\$ 600,00\s*saldo externo/.test(linhaR2) && /parcialmente paga/.test(linhaR2) && /saldo externo vencido/.test(linhaR2), linhaR2);
  check("saldo externo vencido do consolidado sobe +600; pendente sobe +600 (R2), sem tocar no R1", n2(num(P.kp[3]) - num(Rb.kp[3])) === 600 && n2(num(P.kp[2]) - num(Rb.kp[2])) === 600);
  await luiz.rpc("estornar_pagamento_rateio", { p_pagamento_id: p2, p_motivo: "pagamento lançado em duplicidade" });
  const Q = await ler(page);
  check("estorno do pagamento parcial: saldo externo de R2 volta a 1.000 (pendente +400 em relação ao parcial) e as saídas efetivadas voltam ao valor anterior", n2(num(Q.kp[2]) - num(P.kp[2])) === 400 && Q.eff[1] === Rb.eff[1], JSON.stringify([Rb.eff, P.eff, Q.eff]));
  const rbId = sql(`select id from rateio_reembolsos where rateio_id='${R1}' and tipo='reembolso'`);
  await luiz.rpc("estornar_reembolso", { p_reembolso_id: rbId, p_motivo: "reembolso lançado errado" });
  const Z = await ler(page);
  check("estorno do reembolso: Smoke volta a receber R$ 600; despesa e entradas/saídas inalteradas", n2(L_(Z, "Smoke Club", "receber") - L_(B, "Smoke Club", "receber")) === 600 && n2(num(Z.kp[1]) - num(Q.kp[1])) === 0 && Z.eff[1] === Q.eff[1]);
  await page.screenshot({ path: path.join(process.env.SHOT_DIR || "/tmp", "resumo-desktop.png"), fullPage: false });

  /* ---- Painel ---- */
  await page.click("#tab-painel"); await page.waitForSelector(".kpi");
  check("Painel: cartão 'Despesas compartilhadas do mês' (previsto, pago, saldo externo) e distinção acerto entre lojas × saldo externo", /Despesas compartilhadas do mês/.test(await page.textContent("#viewRoot")) && /acerto entre lojas ≠ saldo externo/.test(await page.textContent("#viewRoot")));
  check("sem erros de JavaScript no fluxo do luiz", erros.length === 0, erros.join("|"));
  await page.context().close();

  /* ---- usuário com acesso a UMA loja (enzo) ---- */
  ({ page, erros } = await abrir(browser, "enzo")); await page.click("#tab-financeiro"); await page.waitForSelector("#ratResumo"); await page.click("[data-a=finPeriodo][data-id=tudo]"); await page.waitForSelector("#ratResumo");
  const En = await ler(page);
  check("enzo (só Start): 'por loja' mostra só a Start; nenhum dado das outras lojas; o botão de escopo é 'Todas as minhas lojas'", Object.keys(En.lojas).length === 1 && Object.keys(En.lojas)[0] === "Start BR01" && !/Smoke Club: |EZ Store: /.test(En.texto) && /Todas as minhas lojas/.test(await page.textContent("#ratResumo")));
  check("enzo vê a parcela de R$ 300 de R1 como 'a reembolsar' (externo quitado) e R2 como 'parcela ainda não coberta' (externo em aberto)", L_(En, "Start BR01", "reembolsar") >= 300 && L_(En, "Start BR01", "nao") >= 333.33);
  await page.click('[data-a=ratEscopo][data-id=todas]'); await page.waitForFunction(() => /todas as minhas lojas/.test((document.getElementById("ratResumo") || {}).textContent || ""));
  check("mesmo com 'todas as minhas lojas', enzo continua vendo só a Start", (await page.locator("#ratResumo > .card > b").allTextContents()).every(t => t === "Start BR01"));
  await page.context().close();

  /* ---- dono: consolidado de todas as lojas + celular ---- */
  ({ page, erros } = await abrir(browser, "chefe", { viewport: { width: 390, height: 900 } })); await page.click("#tab-financeiro"); await page.waitForSelector("#ratResumo");
  check("dono: botão 'Consolidado (todas as lojas)'", /Consolidado \(todas as lojas\)/.test(await page.textContent("#ratResumo")));
  await page.click('[data-a=ratEscopo][data-id=todas]'); await page.waitForFunction(() => /todas as minhas lojas/.test((document.getElementById("ratResumo") || {}).textContent || ""));
  const nomes = await page.locator("#ratResumo > .card > b").allTextContents();
  check("dono (vinculado só à Start) enxerga Smoke, Start e EZ no consolidado", ["Smoke Club", "Start BR01", "EZ Store"].every(x => nomes.includes(x)), nomes.join(","));
  const sem = await page.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth + 1);
  check("celular (390 px): sem rolagem horizontal no resumo", sem);
  await page.locator("#ratResumo").screenshot({ path: path.join(process.env.SHOT_DIR || "/tmp", "resumo-celular.png") });
  check("sem erros de JavaScript no fluxo do dono", erros.length === 0, erros.join("|"));
  await page.context().close();

  await browser.close();
  console.log(`\nVALIDAÇÃO DOS RESUMOS DE RATEIOS NO NAVEGADOR (pilha real): ${pass} ok, ${fail} falhas`); falhas.forEach(f => console.log("  ✗ " + f));
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error("ERRO NO TESTE:", e.stack ? e.stack.split("\n").slice(0, 6).join("\n") : e); process.exit(2); });

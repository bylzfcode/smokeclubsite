/* Teste focado: seção "Valores não vinculados a caixa" no Histórico. Uso: NODE_PATH=/opt/node22/lib/node_modules node ui_sem_caixa.test.js */
const { chromium } = require("playwright"); const fs = require("fs"), path = require("path");
const root = path.resolve(__dirname, "../../..");
const html = fs.readFileSync(path.join(root, "dashboard.html"), "utf8"), fake = fs.readFileSync(path.join(__dirname, "fake-supabase.js"), "utf8");
const sql = ["002_melhorias.sql", "003_caixa_avisos.sql", "004_entradas_sem_caixa.sql"].map(f => fs.readFileSync(path.join(root, "supabase", f), "utf8")).join("\n");
const CONTRACT = {}; for (const m of sql.matchAll(/create or replace function (\w+)\(([^)]*)\)\s*returns/gi)) { const ps = m[2].split(",").map(s => s.trim()).filter(Boolean).map(s => ({ n: s.split(/\s+/)[0], d: /\bdefault\b/i.test(s) })); CONTRACT[m[1]] = { all: ps.map(p => p.n), required: ps.filter(p => !p.d).map(p => p.n) }; }
let pass = 0, fail = 0; const falhas = []; const check = (n, c, x) => { if (c) pass++; else { fail++; falhas.push(n + (x ? " → " + x : "")); } };
async function abrir(browser, user) {
  const page = await (await browser.newContext({ viewport: { width: 1100, height: 900 } })).newPage(); const erros = []; page.on("pageerror", e => erros.push(e.message));
  await page.route("**/*", r => { const u = r.request().url(); if (u.endsWith("/dashboard.html")) return r.fulfill({ contentType: "text/html", body: html }); if (u.includes("supabase.min.js")) return r.fulfill({ contentType: "application/javascript", body: `window.__CONTRACT=${JSON.stringify(CONTRACT)};\n` + fake }); return r.abort(); });
  await page.goto("http://painel.test/dashboard.html"); await page.fill("#loginUsuario", user); await page.fill("#loginSenha", "1234"); await page.press("#loginSenha", "Enter");
  if (user === "luiz") { await page.waitForSelector(".loja-card"); await page.click(".loja-card:has-text('Smoke Club')"); }
  await page.waitForSelector("#app.show"); return { page, erros };
}
const venda = (page, forma, total, st = "concluida") => page.evaluate(([f, t, s]) => window.__db.vendas.push({ id: "v" + Math.random(), loja_id: "loja-1", status: s, forma_pagamento: f, total: t, criado_em: new Date().toISOString() }), [forma, total, st]);
(async () => {
  const browser = await chromium.launch();
  let { page, erros } = await abrir(browser, "luiz");
  await venda(page, "Dinheiro", 50); await venda(page, "Pix", 30); await venda(page, "Dinheiro", 99, "cancelada");
  await page.click("#tab-historico"); await page.waitForSelector("#hSemCaixa .card");
  const txt = async () => await page.textContent("#hSemCaixa");
  check("seção aparece no histórico com título e aviso de não vinculação", /não vinculados a caixa/i.test(await txt()) && /não são vinculadas automaticamente/.test(await txt()));
  check("total = só dinheiro sem caixa (50,00); Pix e cancelada fora", /50,00/.test(await page.textContent("#hSemCaixa .kpi.warn")) && !/30,00|99,00/.test(await txt()));
  check("mostra data e quantidade por dia e a lista de vendas", /1 venda/.test(await txt()) && (await page.locator("#hSemCaixa .list-row").count()) === 2);
  // abrir caixa depois cobre vendas do período dele; as anteriores continuam sem caixa
  await page.evaluate(() => window.__db.caixas.push({ id: "cx", loja_id: "loja-1", status: "aberto", saldo_inicial: 0, aberto_em: new Date(Date.now() - 60000).toISOString() }));
  await page.selectOption("#hPeriodo", "7d"); await page.waitForTimeout(300);
  check("com caixa aberto cobrindo a venda, a seção fica vazia", /Nenhum valor sem caixa/.test(await txt()));
  check("nada foi alterado: venda e caixa continuam como estavam", await page.evaluate(() => window.__db.vendas.length === 3 && window.__db.caixas.length === 1 && window.__db.caixa_movs.length === 0));
  check("a lista de dias do histórico continua funcionando", await page.locator(".dia-row").count() === 1);
  // função ausente no servidor: aviso claro, histórico segue
  await page.evaluate(() => { window.__missing = "entradas_sem_caixa"; }); await page.selectOption("#hPeriodo", "30d"); await page.waitForTimeout(300);
  check("migração 004 ausente: aviso claro e histórico intacto", /migração 004/.test(await txt()) && await page.locator(".dia-row").count() === 1);
  // permissões: operador da Smoke não consulta outra loja
  ({ page, erros } = await abrir(browser, "enzo"));
  const perm = await page.evaluate(async () => { const r = await window.supabase.createClient().rpc("entradas_sem_caixa", { p_loja_id: "loja-2", p_inicio: null, p_fim: null, p_responsavel: null }); return r.error && r.error.message; });
  check("usuário sem acesso à loja é recusado", /permissão/.test(perm || ""), perm);
  await venda(page, "Dinheiro", 10); await page.click("#tab-historico"); await page.waitForSelector("#hSemCaixa .card");
  check("operador vê a seção só da própria loja", /10,00/.test(await page.textContent("#hSemCaixa .kpi.warn")));
  check("sem erros de JavaScript", erros.length === 0, erros.join("|"));
  await browser.close();
  console.log(`\nTESTE FOCADO (valores sem caixa): ${pass} ok, ${fail} falhas`); falhas.forEach(f => console.log("  ✗ " + f)); process.exit(fail ? 1 : 0);
})().catch(e => { console.error("ERRO NO TESTE:", e.message); process.exit(2); });

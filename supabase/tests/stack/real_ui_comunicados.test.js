/* Navegador (Chromium) contra a PILHA REAL — área Comunicados do dashboard.html (só URL/chave/script trocados). */
const { chromium } = require("playwright"); const fs = require("fs"), path = require("path"), cp = require("child_process");
const env = Object.fromEntries(fs.readFileSync(path.join(__dirname, ".env"), "utf8").trim().split("\n").map(l => l.split(/=(.*)/s).slice(0, 2)));
let html = fs.readFileSync(path.join(path.resolve(__dirname, "../../.."), "dashboard.html"), "utf8");
html = html.replace(/https:\/\/viqgnzppazhcvthaknzi\.supabase\.co/, "http://127.0.0.1:54321").replace(/const SUPABASE_ANON_KEY = "[^"]+"/, `const SUPABASE_ANON_KEY = "${env.ANON_KEY}"`)
  .replace(/https:\/\/cdn\.jsdelivr\.net\/npm\/@supabase\/supabase-js@2\.45\.4\/dist\/umd\/supabase\.min\.js/, "http://127.0.0.1:54321/__painel/supabase.js");
if (!html.includes("__painel")) { console.error("troca de URL/script falhou"); process.exit(2); }
const supaJs = fs.readFileSync(path.join(__dirname, "node/node_modules/@supabase/supabase-js/dist/umd/supabase.js"), "utf8");
const sql = q => cp.execFileSync("docker", ["compose", "--env-file", ".env", "exec", "-T", "db", "psql", "-w", "-U", "postgres", "-d", "postgres", "-At", "-c", q], { cwd: __dirname, encoding: "utf8" }).trim();
let pass = 0, fail = 0; const falhas = []; const check = (n, c, x) => { if (c) pass++; else { fail++; falhas.push(n + (x !== undefined ? " → " + String(x).slice(0, 260) : "")); } };
const TAG = "UC" + Date.now();

async function abrir(browser, user, opts = {}) {
  const ctx = await browser.newContext({ viewport: opts.viewport || { width: 1100, height: 1000 }, permissions: ["clipboard-read", "clipboard-write"] }), page = await ctx.newPage();
  const dialogs = [], erros = []; page.dialogs = dialogs; page.modo = "accept";
  page.on("dialog", d => { dialogs.push({ tipo: d.type(), msg: d.message() }); page.modo === "accept" ? d.accept() : d.dismiss(); });
  page.on("pageerror", e => erros.push(e.message));
  await page.route("**/*", route => { const u = route.request().url();
    if (u === "http://127.0.0.1:54321/__painel/dashboard.html") return route.fulfill({ contentType: "text/html", body: html });
    if (u === "http://127.0.0.1:54321/__painel/supabase.js") return route.fulfill({ contentType: "application/javascript", body: supaJs });
    if (u.startsWith("http://127.0.0.1:54321/") && !u.includes("/__painel/")) return route.continue(); return route.abort(); });
  await page.goto("http://127.0.0.1:54321/__painel/dashboard.html"); await page.fill("#loginUsuario", user); await page.fill("#loginSenha", "1234"); await page.press("#loginSenha", "Enter");
  if (opts.loja) { await page.waitForSelector(".loja-card"); await page.click(`.loja-card:has-text("${opts.loja}")`); }
  await page.waitForSelector("#app.show"); return { page, erros, ctx };
}
const toastTxt = async page => { await page.waitForSelector("#toast.show"); return page.textContent("#toast"); };
const CAB = "📣 *AVISO IMPORTANTE*", COR = `Pessoal,\n\n• Reunião _sexta_ às 18h ✅\n• ~Cancelado~ o plantão\n    (recuo preservado)\n<script>window.__xss=1</script> <img src=x onerror="window.__xss=2"> & "aspas"\n\`\`\`codigo *não negrito*\`\`\``, ROD = "— Equipe 💬";

(async () => {
  const browser = await chromium.launch();
  let { page, erros } = await abrir(browser, "luiz", { loja: "Smoke Club" });
  check("aba 📣 Comunicados existe para o gerente", await page.locator("#tab-comunicados").count() === 1);
  await page.click("#tab-comunicados"); await page.waitForSelector("[data-a=cmNovo]");
  await page.click("[data-a=cmNovo]"); await page.waitForSelector("#cmTitulo");
  await page.fill("#cmTitulo", `Escala ${TAG}`); await page.fill("#cmCab", CAB); await page.fill("#cmCor", COR); await page.fill("#cmRod", ROD);
  check("contadores de caracteres e da mensagem atualizam", /\d+\/2000/.test(await page.textContent("#cmN-o")) && /Mensagem: \d+\/2000/.test(await page.textContent("#cmNT")));
  const prev = await page.evaluate(() => ({ html: document.getElementById("cmPrev").innerHTML, txt: document.getElementById("cmPrev").textContent, xss: window.__xss, scripts: document.querySelectorAll("#cmPrev script, #cmPrev img").length,
    b: [...document.querySelectorAll("#cmPrev b")].map(e => e.textContent), i: [...document.querySelectorAll("#cmPrev i")].map(e => e.textContent), s: [...document.querySelectorAll("#cmPrev s")].map(e => e.textContent), mono: [...document.querySelectorAll("#cmPrev .wa-mono")].map(e => e.textContent) }));
  check("prévia: *negrito*, _itálico_, ~tachado~ e ```mono``` viram formatação; marcadores dentro do mono ficam como texto", prev.b.includes("AVISO IMPORTANTE") && prev.i.includes("sexta") && prev.s.includes("Cancelado") && prev.mono[0] === "codigo *não negrito*" && prev.b.length === 1, JSON.stringify(prev));
  check("prévia: HTML/JS digitado aparece como TEXTO (nada executa, nenhuma tag injetada)", prev.xss === undefined && prev.scripts === 0 && prev.txt.includes("<script>window.__xss=1</script>") && prev.txt.includes('<img src=x onerror="window.__xss=2">'), JSON.stringify(prev).slice(0, 200));
  check("indicador 'alterações não salvas' aparece", !(await page.locator("#cmSujo").getAttribute("class")).includes("hidden"));
  // copiar exatamente o texto editado
  const esperado = [CAB, COR, ROD].join("\n\n");
  await page.click("[data-a=cmCopiar]"); await toastTxt(page);
  check("Copiar texto: área de transferência = EXATAMENTE cabeçalho + corpo + rodapé (emojis, quebras, espaços, HTML literal)", (await page.evaluate(() => navigator.clipboard.readText())) === esperado);
  await page.click("[data-a=cmCopiarT]"); await page.waitForTimeout(150);
  check("Copiar com título: título em negrito + linha em branco + texto", (await page.evaluate(() => navigator.clipboard.readText())) === `*Escala ${TAG}*\n\n${esperado}`);
  // salvar
  await page.click("#cmBtnSalvar"); await page.waitForFunction(() => /Rascunho salvo/.test(document.getElementById("toast").textContent));
  check("salvar rascunho: versão 1, status rascunho, sem 'alterações não salvas'", /Versão 1/.test(await page.textContent("#viewRoot")) && (await page.locator("#cmSujo").getAttribute("class")).includes("hidden") && /rascunho/.test(await page.textContent(".page-h h2")));
  const row = sql(`select cabecalho||'|'||rodape||'|'||status||'|'||versao from comunicados where titulo='Escala ${TAG}'`);
  check("persistiu no banco exatamente como digitado", sql(`select corpo from comunicados where titulo='Escala ${TAG}'`) === COR && row === `${CAB}|${ROD}|rascunho|1`, row);
  check("aviso NÃO foi criado ao salvar o rascunho", sql(`select count(*) from avisos where titulo='Escala ${TAG}'`) === "0");
  // persistência após recarregar a página
  await page.close(); ({ page, erros } = await abrir(browser, "luiz", { loja: "Smoke Club" }));
  await page.click("#tab-comunicados"); await page.waitForSelector(`.list-row:has-text("Escala ${TAG}")`);
  check("lista mostra o rascunho com status e autor", /rascunho/.test(await page.textContent(`.list-row:has-text("Escala ${TAG}")`)) && /Luiz/.test(await page.textContent(`.list-row:has-text("Escala ${TAG}")`)));
  await page.click(`.list-row:has-text("Escala ${TAG}")`); await page.waitForSelector("#cmTitulo");
  check("depois de recarregar, os campos voltam idênticos", await page.inputValue("#cmCor") === COR && await page.inputValue("#cmCab") === CAB && await page.inputValue("#cmRod") === ROD && await page.inputValue("#cmTitulo") === `Escala ${TAG}`);
  // edição -> proteção contra sair sem salvar
  await page.fill("#cmCor", COR + "\nlinha nova");
  page.modo = "dismiss"; page.dialogs.length = 0; await page.click("#tab-painel"); await page.waitForTimeout(250);
  check("sair da aba com alterações não salvas: pede confirmação e, ao recusar, fica no editor com o texto", page.dialogs.length === 1 && /não salvas/.test(page.dialogs[0].msg) && await page.locator("#cmTitulo").count() === 1 && (await page.inputValue("#cmCor")).endsWith("linha nova"));
  page.dialogs.length = 0; await page.click("[data-a=cmVoltar]"); await page.waitForTimeout(200);
  check("voltar à lista também pergunta", page.dialogs.length === 1 && await page.locator("#cmTitulo").count() === 1);
  const antesBU = await page.evaluate(() => { const ev = new Event("beforeunload", { cancelable: true }); window.dispatchEvent(ev); return ev.defaultPrevented; });
  check("fechar/recarregar a página com alterações dispara o aviso do navegador (beforeunload)", antesBU === true);
  page.modo = "accept"; page.dialogs.length = 0;
  await page.click("[data-a=cmSalvar]"); await page.waitForFunction(() => /Rascunho salvo \(versão 2\)/.test(document.getElementById("toast").textContent));
  const semAviso = await page.evaluate(() => { const ev = new Event("beforeunload", { cancelable: true }); window.dispatchEvent(ev); return ev.defaultPrevented; });
  check("salvo: sem aviso ao sair; agora a versão é 2", semAviso === false && /Versão 2/.test(await page.textContent("#viewRoot")));
  await page.click("#tab-painel"); check("sair sem alterações não pergunta nada", page.dialogs.length === 0);
  // histórico + restaurar
  await page.click("#tab-comunicados"); await page.click(`.list-row:has-text("Escala ${TAG}")`); await page.waitForSelector("#cmTitulo");
  await page.click("[data-a=cmHistorico]"); await page.waitForSelector(".modal-box .cm-ver");
  const hist = await page.textContent(".modal-box");
  check("histórico mostra versões 1 e 2 com autor e data", /Versão 2/.test(hist) && /Versão 1/.test(hist) && (hist.match(/Luiz/g) || []).length >= 2);
  await page.click(`.modal-box [data-a=cmRestaurar][data-id="1"]`); await page.waitForFunction(() => /restaurada como nova versão/.test(document.getElementById("toast").textContent));
  check("restaurar versão 1: cria a versão 3 com o conteúdo da 1; histórico preservado", await page.inputValue("#cmCor") === COR && /Versão 3/.test(await page.textContent("#viewRoot")) && sql(`select count(*) from comunicados_versoes v join comunicados c on c.id=v.comunicado_id where c.titulo='Escala ${TAG}'`) === "3");
  // publicar como aviso
  await page.click("[data-a=cmPublicarForm]"); await page.waitForSelector("#cmPrio");
  await page.selectOption("#cmPrio", "urgente"); const amanha = new Date(Date.now() + 2 * 86400000).toLocaleDateString("en-CA", { timeZone: "America/Sao_Paulo" }); await page.fill("#cmValido", amanha);
  await page.check("#cmDestaque"); await page.click("[data-a=cmPublicarOk]"); await page.waitForFunction(() => /publicado como aviso/.test(document.getElementById("toast").textContent));
  check("aviso criado: prioridade urgente, validade, destaque, só a Smoke, texto exato", sql(`select prioridade||'|'||destaque||'|'||(valido_ate is not null)||'|'||tipo from avisos where titulo='Escala ${TAG}' and ativo`) === "urgente|true|true|comunicado" && sql(`select descricao from avisos where titulo='Escala ${TAG}' and ativo`) === esperado.trim());
  check("status passa a 'publicado' no editor", /publicado/.test(await page.textContent(".page-h h2")));
  await page.click("#tab-painel"); await page.waitForSelector(".aviso");
  const av = await page.evaluate(t => { const a = [...document.querySelectorAll(".aviso")].find(x => x.textContent.includes(t)); const m = a && a.querySelector(".msg"); return a ? { cls: a.className, txt: m.textContent, ws: getComputedStyle(m).whiteSpace, imgs: a.querySelectorAll("img,script").length, xss: window.__xss } : null; }, `Escala ${TAG}`);
  check("no Painel o aviso aparece (urgente/destaque), com quebras preservadas e HTML como texto", !!av && /urgente/.test(av.cls) && /destaque/.test(av.cls) && av.ws === "pre-wrap" && av.txt === esperado.trim() && av.imgs === 0 && av.xss === undefined, JSON.stringify(av).slice(0, 200));
  // editar publicado -> não publicadas
  await page.click("#tab-comunicados"); await page.click(`.list-row:has-text("Escala ${TAG}")`); await page.waitForSelector("#cmTitulo");
  await page.fill("#cmRod", ROD + " (rev)"); await page.click("[data-a=cmSalvar]"); await page.waitForFunction(() => /Rascunho salvo/.test(document.getElementById("toast").textContent));
  check("editar publicado: etiqueta 'alterações não publicadas' e o aviso segue com o texto antigo", /alterações não publicadas/.test(await page.textContent(".page-h h2")) && sql(`select descricao like '%(rev)%' from avisos where titulo='Escala ${TAG}' and ativo`) === "f");
  await page.click("[data-a=cmPublicarForm]"); await page.waitForSelector("#cmPrio"); await page.click("[data-a=cmPublicarOk]"); await page.waitForFunction(() => /publicado como aviso/.test(document.getElementById("toast").textContent));
  check("republicar atualiza o mesmo aviso (1 só)", sql(`select count(*) from avisos where titulo='Escala ${TAG}'`) === "1" && sql(`select descricao like '%(rev)%' from avisos where titulo='Escala ${TAG}'`) === "t");
  check("sem erros de JavaScript na página (gerente)", erros.length === 0, erros.join(" | "));

  /* ---- operadora: edita, não publica ---- */
  let c = await abrir(browser, "carla");
  await c.page.click("#tab-comunicados"); await c.page.click(`.list-row:has-text("Escala ${TAG}")`); await c.page.waitForSelector("#cmTitulo");
  check("operadora vê o rascunho da própria loja, sem botão de publicar/despublicar", await c.page.locator("[data-a=cmPublicarForm]").count() === 0 && await c.page.locator("[data-a=cmDespublicar]").count() === 0 && await c.page.locator("[data-a=cmSalvar]").count() === 1);
  await c.page.fill("#cmCor", "texto da Carla"); await c.page.click("[data-a=cmSalvar]"); await c.page.waitForFunction(() => /Rascunho salvo/.test(document.getElementById("toast").textContent));
  check("operadora salva e fica registrada como autora", /Carla/.test(await c.page.textContent("#viewRoot")) && sql(`select por_nome from (select (select nome from perfis where id=v.por) por_nome from comunicados_versoes v join comunicados k on k.id=v.comunicado_id where k.titulo='Escala ${TAG}' order by v.em desc limit 1) q`) === "Carla");
  await c.ctx.close();

  /* ---- outra loja não vê ---- */
  c = await abrir(browser, "enzo");
  await c.page.click("#tab-comunicados"); await c.page.waitForSelector("[data-a=cmNovo]");
  check("operador da Start não vê rascunhos da Smoke", !(await c.page.textContent("#viewRoot")).includes(`Escala ${TAG}`));
  await c.ctx.close();

  /* ---- celular ---- */
  c = await abrir(browser, "luiz", { loja: "Smoke Club", viewport: { width: 375, height: 760 } });
  await c.page.click("#tab-comunicados"); await c.page.click(`.list-row:has-text("Escala ${TAG}")`); await c.page.waitForSelector("#cmTitulo");
  const m = await c.page.evaluate(() => ({ sw: document.documentElement.scrollWidth, cw: document.documentElement.clientWidth, cols: getComputedStyle(document.getElementById("cmForm")).gridTemplateColumns.split(" ").length, f: document.getElementById("cmCor").getBoundingClientRect().width }));
  check("celular (375px): sem rolagem horizontal, editor e prévia empilhados, campos com largura útil", m.sw <= m.cw && m.cols === 1 && m.f > 250, JSON.stringify(m));
  await c.ctx.close();
  await browser.close();
  console.log(`\nCOMUNICADOS (navegador, pilha real): ${pass} ok, ${fail} falhas`); if (fail) { falhas.forEach(f => console.log(" ✗ " + f)); process.exit(1); }
})().catch(e => { console.error("ERRO", e); process.exit(1); });

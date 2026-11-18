/* Navegador (Chromium) contra a PILHA REAL — períodos, recorrência, calendário e acessos do dashboard.html (só URL/chave/script trocados). */
const { chromium } = require("playwright"); const fs = require("fs"), path = require("path"), cp = require("child_process");
const env = Object.fromEntries(fs.readFileSync(path.join(__dirname, ".env"), "utf8").trim().split("\n").map(l => l.split(/=(.*)/s).slice(0, 2)));
let html = fs.readFileSync(path.join(path.resolve(__dirname, "../../.."), "dashboard.html"), "utf8");
html = html.replace(/https:\/\/viqgnzppazhcvthaknzi\.supabase\.co/, "http://127.0.0.1:54321").replace(/const SUPABASE_ANON_KEY = "[^"]+"/, `const SUPABASE_ANON_KEY = "${env.ANON_KEY}"`)
  .replace(/https:\/\/cdn\.jsdelivr\.net\/npm\/@supabase\/supabase-js@2\.45\.4\/dist\/umd\/supabase\.min\.js/, "http://127.0.0.1:54321/__painel/supabase.js");
if (!html.includes("__painel")) { console.error("troca de URL/script falhou"); process.exit(2); }
const supaJs = fs.readFileSync(path.join(__dirname, "node/node_modules/@supabase/supabase-js/dist/umd/supabase.js"), "utf8");
const sql = q => cp.execFileSync("docker", ["compose", "--env-file", ".env", "exec", "-T", "db", "psql", "-w", "-U", "postgres", "-d", "postgres", "-At", "-c", q], { cwd: __dirname, encoding: "utf8" }).trim();
let pass = 0, fail = 0; const falhas = []; const check = (n, c, x) => { if (c) pass++; else { fail++; falhas.push(n + (x !== undefined ? " → " + String(x).slice(0, 260) : "")); } };
const TAG = "UA" + Date.now();
const hoje = new Date().toLocaleDateString("en-CA", { timeZone: "America/Sao_Paulo" });
const addDias = (iso, d) => { const x = new Date(iso + "T12:00:00Z"); x.setUTCDate(x.getUTCDate() + d); return x.toISOString().slice(0, 10); };
const fmtBR = iso => iso.slice(8) + "/" + iso.slice(5, 7) + "/" + iso.slice(0, 4);
const ultimo = iso => new Date(Date.UTC(+iso.slice(0, 4), +iso.slice(5, 7), 0)).toISOString().slice(0, 10);

async function abrir(browser, user, opts = {}) {
  const ctx = await browser.newContext({ viewport: opts.viewport || { width: 1100, height: 1000 } }), page = await ctx.newPage();
  const dialogs = []; page.dialogs = dialogs; page.on("dialog", d => { dialogs.push(d.message()); d.accept(); });
  const erros = []; page.on("pageerror", e => erros.push(e.message));
  await page.route("**/*", route => { const u = route.request().url();
    if (u === "http://127.0.0.1:54321/__painel/dashboard.html") return route.fulfill({ contentType: "text/html", body: html });
    if (u === "http://127.0.0.1:54321/__painel/supabase.js") return route.fulfill({ contentType: "application/javascript", body: supaJs });
    if (u.startsWith("http://127.0.0.1:54321/") && !u.includes("/__painel/")) return route.continue(); return route.abort(); });
  await page.goto("http://127.0.0.1:54321/__painel/dashboard.html"); await page.fill("#loginUsuario", user); await page.fill("#loginSenha", "1234"); await page.press("#loginSenha", "Enter");
  if (opts.loja) { await page.waitForSelector(".loja-card"); await page.click(`.loja-card:has-text("${opts.loja}")`); }
  if (!opts.semEntrar) await page.waitForSelector("#app.show"); return { page, erros, ctx };
}
const toastOk = (page, re) => page.waitForFunction(r => new RegExp(r).test(document.getElementById("toast").textContent), re.source);
const semRolagem = page => page.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth + 1);

(async () => {
  const browser = await chromium.launch();
  let { page, erros } = await abrir(browser, "luiz", { loja: "Smoke Club" });

  /* ---- períodos ---- */
  await page.click("#tab-financeiro"); await page.waitForSelector("#finResumo .kpi");
  const mesIni = hoje.slice(0, 8) + "01";
  check("'Este mês' abrange o mês INTEIRO (do dia 1º ao último dia) e o texto diz isso", (await page.textContent("#finPeriodoTxt")).includes(`${fmtBR(mesIni)} a ${fmtBR(ultimo(hoje))}`) && /mês inteiro/.test(await page.textContent("#finPeriodoTxt")));
  await page.click("[data-a=finPeriodo][data-id=ate]"); await page.waitForFunction(h => document.getElementById("finPeriodoTxt").textContent.includes(h), `a ${fmtBR(hoje)}`);
  check("'Até hoje' é um filtro separado: do dia 1º até hoje", (await page.textContent("#finPeriodoTxt")).includes(`${fmtBR(mesIni)} a ${fmtBR(hoje)}`) && /até hoje/.test(await page.textContent("#finPeriodoTxt")) && await page.locator("[data-a=finPeriodo][data-id=mes]").count() === 1);
  await page.click("[data-a=finPeriodo][data-id=tudo]"); await page.waitForFunction(() => /sem filtro/.test(document.getElementById("finPeriodoTxt").textContent));
  check("'Tudo' avisa que não há filtro de data", /sem filtro/.test(await page.textContent("#finPeriodoTxt")));
  await page.click("[data-a=finPeriodo][data-id=mes]");

  /* ---- recorrência: formulário, prévia, criação ---- */
  await page.click("[data-a=finForm]"); await page.waitForSelector("#lRep");
  check("conta única é o padrão (recorrência desligada, caixa de opções oculta)", !(await page.isChecked("#lRep")) && await page.locator("#lRepBox").isHidden());
  await page.fill("#lDesc", `Aluguel ${TAG}`); await page.fill("#lValor", "1234,56"); await page.fill("#lVenc", "2031-01-31");
  await page.check("#lRep"); await page.selectOption("#lFreq", "mensal"); await page.selectOption("#lFim", "quantidade"); await page.fill("#lFimQtd", "4");
  check("ao repetir, 'já foi paga' fica desabilitado (ocorrências nascem pendentes)", await page.locator("#lJaPaga").isDisabled());
  await page.click("[data-a=serPrevia]"); await page.waitForSelector("#lPrev .list-row");
  const pv = await page.textContent("#lPrev");
  check("prévia: 31/01, 28/02, 31/03, 30/04 de 2031, com 28/02 e 30/04 marcadas como ajustadas", ["31/01/2031", "28/02/2031", "31/03/2031", "30/04/2031"].every(d => pv.includes(d)) && (pv.match(/ajustada ao último dia do mês/g) || []).length === 2, pv.slice(0, 200));
  await page.fill("#lVenc", addDias(hoje, 2)); await page.selectOption("#lFreq", "personalizada"); await page.fill("#lInt", "3"); await page.selectOption("#lUni", "dia"); await page.selectOption("#lFim", "sem_prazo");
  check("mudar a regra limpa a prévia antiga (não mostra datas desatualizadas)", (await page.textContent("#lPrev")).trim() === "");
  await page.selectOption("#lFreq", "semanal"); await page.selectOption("#lFim", "quantidade"); await page.fill("#lFimQtd", "20");
  await page.click("[data-a=finSalvar]"); await toastOk(page, /Série criada/);
  await page.waitForSelector(`#finLista .list-row:has-text("Aluguel ${TAG}")`);
  const nCont = Number(sql(`select count(*) from financeiro_lancamentos f join contas_series s on s.id=f.serie_id where s.descricao='Aluguel ${TAG}'`));
  check("série semanal de 20: gera só as contas da janela de 60 dias (não as 20), todas pendentes, com valor exato", nCont >= 8 && nCont <= 10 && sql(`select count(*) from financeiro_lancamentos f join contas_series s on s.id=f.serie_id where s.descricao='Aluguel ${TAG}' and f.valor=1234.56 and f.status='pendente'`) === String(nCont), nCont);
  check("lista marca as ocorrências como recorrentes e o cartão de séries aparece com o aviso do agendador", await page.locator(`#finLista .list-row:has-text("Aluguel ${TAG}"):has-text("↻")`).count() === nCont && /Contas recorrentes/.test(await page.textContent("#finSeries")) && /agendador/i.test(await page.textContent("#finSeries")));
  // editar esta e as próximas
  await page.click(`#finLista .list-row:has-text("Aluguel ${TAG}") >> nth=1`); await page.waitForSelector("[data-a=finEditar]"); await page.click("[data-a=finEditar]"); await page.waitForSelector("#ceProx");
  await page.check("#ceProx"); await page.fill("#ceValor", "1500"); await page.click("[data-a=ceSalvar]"); await toastOk(page, /alterada\(s\); \d+ preservada/);
  const nAlt = Number((await page.textContent("#toast")).match(/^(\d+) conta/)[1]);
  check("editar 'esta e as próximas' altera o modelo e só as ocorrências intocadas a partir da escolhida (as anteriores permanecem)", nAlt >= 1 && sql(`select count(*) from financeiro_lancamentos f join contas_series s on s.id=f.serie_id where s.descricao='Aluguel ${TAG}' and f.valor=1500`) === String(nAlt) && sql(`select valor from contas_series where descricao='Aluguel ${TAG}'`) === "1500.00", nAlt);
  await page.waitForSelector("[data-a=serPausar]"); await page.click("[data-a=serPausar]"); await toastOk(page, /pausada/); await page.waitForSelector("[data-a=serRetomar]");
  check("pausar: série marcada como pausada e com opção de retomar", /pausada/.test(await page.textContent("#finSeries")));
  await page.click("[data-a=serRetomar]"); await toastOk(page, /retomada/);
  await page.click("[data-a=serEncerrarForm]"); await page.waitForSelector("#serCanc"); await page.check("#serCanc"); await page.click("[data-a=serEncerrarOk]"); await toastOk(page, /encerrada/);
  check("encerrar cancelando as futuras sem movimentação; nada é apagado", sql(`select status from contas_series where descricao='Aluguel ${TAG}'`) === "encerrada" && Number(sql(`select count(*) from financeiro_lancamentos f join contas_series s on s.id=f.serie_id where s.descricao='Aluguel ${TAG}'`)) === nCont);

  /* ---- calendário ---- */
  const contaUnica = sql(`select id from financeiro_lancamentos where serie_id is null and loja_id=(select id from lojas where slug='smoke-club') and vencimento is not null and status='pendente' order by criado_em desc limit 1`);
  await page.click("#tab-calendario"); await page.waitForSelector(".cal-g");
  check("calendário mensal e lista de próximos eventos aparecem, com legenda das situações", await page.locator(".cal-c:not(.vazio)").count() >= 28 && /Próximos 30 dias/.test(await page.textContent("#viewRoot")) && /vencido/.test(await page.textContent(".cal-leg")));
  const ev = await page.locator(".list-row[data-a=calAbrir]").count();
  check("eventos do mês listados (contas exclusivas e compartilhadas)", ev >= 1, ev);
  if (!(await page.locator(`.list-row[data-a=calAbrir]:has-text("Aluguel ${TAG}")`).count())) { await page.click("[data-a=calMes][data-id='1']"); await page.waitForTimeout(600); }
  check("ocorrências recorrentes aparecem no calendário marcadas como recorrentes e canceladas quando encerradas", await page.locator(`.list-row[data-a=calAbrir]:has-text("Aluguel ${TAG}"):has-text("recorrente")`).count() >= 1);
  await page.click(`.list-row[data-a=calAbrir]:has-text("Aluguel ${TAG}") >> nth=0`); await page.waitForSelector("#modalOv.show .kpi-grid");
  check("clicar numa conta abre o detalhe financeiro existente (mesmo registro, sem duplicar)", await page.locator("#modalOv.show .kpi-grid").count() === 1);
  await page.click("[data-a=fechar]");
  if (await page.locator("[data-a=calMes][data-id='-1']").count() && !(await page.locator(".cal-c.hoje").count())) { await page.click("[data-a=calMes][data-id='-1']"); await page.waitForSelector(".cal-c.hoje"); }
  // compromisso
  await page.click("[data-a=calNovo]"); await page.waitForSelector("#cpTitulo"); await page.fill("#cpTitulo", `Reunião ${TAG}`); await page.fill("#cpData", addDias(hoje, 1)); await page.selectOption("#cpResp", { label: "Luiz" }); await page.fill("#cpObs", "levar notas");
  await page.click("[data-a=calCompSalvar]"); await toastOk(page, /Compromisso criado/);
  await page.waitForSelector(`.list-row:has-text("Reunião ${TAG}")`);
  check("compromisso aparece no calendário com responsável e situação 'pendente'", /resp\.: Luiz/.test(await page.textContent(`.list-row:has-text("Reunião ${TAG}")`)) && /pendente/.test(await page.textContent(`.list-row:has-text("Reunião ${TAG}")`)) && sql(`select count(*) from compromissos where titulo='Reunião ${TAG}'`) === "1");
  await page.click(`.list-row:has-text("Reunião ${TAG}") >> nth=0`); await page.waitForSelector("#cpTitulo"); await page.click("[data-a=calCompStatus][data-id=concluido]"); await toastOk(page, /Compromisso atualizado/);
  await page.waitForSelector(`.list-row:has-text("Reunião ${TAG}"):has-text("concluído")`);
  check("concluir: situação 'concluído' e histórico com 2 versões", sql(`select status||'/'||versao from compromissos where titulo='Reunião ${TAG}'`) === "concluido/2");
  await page.click("[data-a=calMes][data-id='1']"); await page.waitForFunction(() => /de \d{4}/.test(document.querySelector(".cal-g").parentElement.textContent));
  check("navegar de mês funciona e o dia selecionado é limpo", await page.locator(".cal-c.sel").count() === 0);
  await page.click("[data-a=calMes][data-id='-1']"); await page.waitForSelector(".cal-g");
  await page.click(".cal-c:not(.vazio) >> nth=0"); check("selecionar um dia filtra a lista e oferece voltar ao mês todo", await page.locator("[data-a=calDia][data-id='']").count() === 1);
  check("sem erros de JavaScript (gerente)", erros.length === 0, erros.join(" | "));

  /* ---- troca de loja: nada da anterior fica na tela ---- */
  await page.click("[data-a=trocarLoja]"); await page.waitForSelector(".loja-card");
  check("ao trocar de loja a tela da anterior é limpa (nenhum evento da Smoke visível)", (await page.textContent("#viewRoot")).trim() === "" && !(await page.locator("#modalOv.show").count()));
  await page.click('.loja-card:has-text("Start")'); await page.waitForSelector("#app.show"); await page.click("#tab-calendario"); await page.waitForSelector(".cal-g");
  check("na Start o calendário não mostra contas nem compromissos da Smoke", !(await page.textContent("#viewRoot")).includes(`Reunião ${TAG}`) && !(await page.textContent("#viewRoot")).includes(`Aluguel ${TAG}`));
  await page.click("[data-a=calEscopo][data-id=todas]"); await page.waitForFunction(t => document.getElementById("viewRoot").textContent.includes(t), `Reunião ${TAG}`);
  check("'Todas as minhas lojas' (consolidado do gerente com acesso às duas) mostra a Smoke", true);
  await page.context().close();

  /* ---- operadora: edita compromisso, sem Acessos, sem editar conta ---- */
  let c = await abrir(browser, "carla");
  await c.page.click("#tab-calendario"); await c.page.waitForSelector(".cal-g");
  check("operadora vê o calendário da loja e a aba Acessos não existe para ela", await c.page.locator("#tab-acessos").count() === 0 && await c.page.locator("[data-a=calNovo]").count() === 1);
  await c.page.click("#tab-financeiro"); await c.page.waitForSelector("#finLista"); await c.page.click("[data-a=finPeriodo][data-id=tudo]"); await c.page.waitForSelector(`#finLista .list-row:has-text("Aluguel ${TAG}")`); await c.page.click(`#finLista .list-row:has-text("Aluguel ${TAG}") >> nth=0`); await c.page.waitForSelector(".modal-box .kpi-grid");
  check("operadora não vê 'Editar conta' nem controles de série", await c.page.locator("[data-a=finEditar]").count() === 0 && await c.page.locator("[data-a=serPausar], [data-a=serEncerrarForm]").count() === 0);
  await c.ctx.close();

  /* ---- acessos (dono) ---- */
  c = await abrir(browser, "chefe");
  await c.page.click("#tab-acessos"); await c.page.waitForSelector(".list-row:has-text('Carla')");
  check("dono vê a lista de pessoas com papel, lojas e situação; não pode desativar a si mesmo", /operador/.test(await c.page.textContent(".list-row:has-text('Carla')")) && await c.page.locator(".list-row:has-text('Chefe') [data-a=acDesativar]").count() === 0);
  await c.page.click(".list-row:has-text('Carla') [data-a=acDesativar]"); await c.page.waitForSelector("#acMotivo");
  await c.page.click("[data-a=acDesativarOk]"); check("desativar sem motivo é recusado na tela", await c.page.locator("#acMotivo").count() === 1);
  await c.page.fill("#acMotivo", "saiu da equipe"); await c.page.click("[data-a=acDesativarOk]"); await toastOk(c.page, /Acesso desativado/);
  check("pessoa desativada aparece como 'desativado' com o motivo; histórico preservado no banco", /desativado/.test(await c.page.textContent(".list-row:has-text('Carla')")) && /saiu da equipe/.test(await c.page.textContent(".list-row:has-text('Carla')")) && sql(`select count(*) from financeiro_lancamentos where criado_por=(select id from auth.users where email='carla@painel.local')`) !== "0");
  const dsb = await abrir(browser, "carla", { semEntrar: true }); await dsb.page.waitForFunction(() => document.getElementById("loginErr").textContent.length > 0);
  check("a pessoa desativada não entra: mensagem clara na tela de login", /desativado/.test(await dsb.page.textContent("#loginErr")), await dsb.page.textContent("#loginErr"));
  await dsb.ctx.close();
  await c.page.click(".list-row:has-text('Carla') [data-a=acReativar]"); await toastOk(c.page, /Acesso reativado/);
  const ok2 = await abrir(browser, "carla"); check("reativada: entra normalmente", await ok2.page.locator("#app.show").count() === 1); await ok2.ctx.close();
  await c.page.click(".list-row:has-text('Carla') [data-a=acLojas]"); await c.page.waitForSelector(".acLoja"); for (const b of await c.page.locator(".acLoja:checked").all()) await b.uncheck(); await c.page.click("[data-a=acLojasOk]");
  check("lojas: tentar salvar com todas desmarcadas é recusado na tela (mantém o modal, nada muda no banco)", await c.page.locator(".acLoja").count() > 0 && /pelo menos uma loja/.test(await c.page.textContent("#toast")) && sql(`select count(*) from perfis_lojas where perfil_id=(select id from auth.users where email='carla@painel.local')`) === "1");
  await c.ctx.close();

  /* ---- celular ---- */
  c = await abrir(browser, "luiz", { loja: "Smoke Club", viewport: { width: 375, height: 800 } });
  for (const [tab, sel] of [["financeiro", "#finLista"], ["calendario", ".cal-g"]]) { await c.page.click("#tab-" + tab); await c.page.waitForSelector(sel); await c.page.waitForTimeout(500); check(`celular (375 px): sem rolagem horizontal em ${tab}`, await semRolagem(c.page)); }
  await c.page.click("#tab-financeiro"); await c.page.click("[data-a=finForm]"); await c.page.waitForSelector("#lRep"); await c.page.check("#lRep"); await c.page.selectOption("#lFreq", "personalizada"); await c.page.fill("#lVenc", addDias(hoje, 3)); await c.page.click("[data-a=serPrevia]"); await c.page.waitForSelector("#lPrev .list-row");
  check("celular: formulário de recorrência com prévia cabe na tela (sem rolagem horizontal na página nem no modal)", await semRolagem(c.page) && await c.page.evaluate(() => { const m = document.getElementById("modalBox"); return m.scrollWidth <= m.clientWidth + 1; }));
  await c.page.click("[data-a=fechar]"); await c.page.click("#tab-calendario"); await c.page.waitForSelector(".cal-g"); await c.page.click("[data-a=calNovo]"); await c.page.waitForSelector("#cpTitulo");
  check("celular: formulário de compromisso sem rolagem horizontal", await semRolagem(c.page) && await c.page.evaluate(() => { const m = document.getElementById("modalBox"); return m.scrollWidth <= m.clientWidth + 1; }));
  await c.ctx.close(); await browser.close();
  console.log(`\nADMINISTRAÇÃO (navegador, pilha real): ${pass} ok, ${fail} falhas`); if (fail) { falhas.forEach(f => console.log(" ✗ " + f)); process.exit(1); }
})().catch(e => { console.error("ERRO", e); process.exit(1); });

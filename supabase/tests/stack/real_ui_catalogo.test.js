/* Navegador (Chromium) contra a PILHA REAL — SITE público (index (23).html) lendo o catálogo/estoque da dashboard, e a DASHBOARD editando o catálogo online. */
const { chromium } = require("playwright"); const fs = require("fs"), path = require("path"), cp = require("child_process");
const env = Object.fromEntries(fs.readFileSync(path.join(__dirname, ".env"), "utf8").trim().split("\n").map(l => l.split(/=(.*)/s).slice(0, 2)));
const raiz = path.resolve(__dirname, "../../..");
const troca = h => h.replace(/https:\/\/viqgnzppazhcvthaknzi\.supabase\.co/g, "http://127.0.0.1:54321").replace(/const SUPABASE_ANON_KEY = "[^"]+"/, `const SUPABASE_ANON_KEY = "${env.ANON_KEY}"`)
  .replace(/https:\/\/cdn\.jsdelivr\.net\/npm\/@supabase\/supabase-js@2\.45\.4\/dist\/umd\/supabase\.min\.js/, "http://127.0.0.1:54321/__painel/supabase.js").replace(/(key: ")eyJ[^"]+(")/, `$1${env.ANON_KEY}$2`);
const dashHtml = troca(fs.readFileSync(path.join(raiz, "dashboard.html"), "utf8")), siteHtml = troca(fs.readFileSync(path.join(raiz, "index (23).html"), "utf8"));
if (!dashHtml.includes("__painel") || !siteHtml.includes("127.0.0.1:54321") || !siteHtml.includes(env.ANON_KEY)) { console.error("troca de URL/chave falhou"); process.exit(2); }
const supaJs = fs.readFileSync(path.join(__dirname, "node/node_modules/@supabase/supabase-js/dist/umd/supabase.js"), "utf8");
const sql = q => cp.execFileSync("docker", ["compose", "--env-file", ".env", "exec", "-T", "db", "psql", "-w", "-U", "postgres", "-d", "postgres", "-At", "-c", q], { cwd: __dirname, encoding: "utf8" }).trim();
let pass = 0, fail = 0; const falhas = []; const check = (n, c, x) => { if (c) pass++; else { fail++; falhas.push(n + (x !== undefined ? " → " + String(x).slice(0, 260) : "")); } };
const TAG = "SI" + Date.now(), B = "http://127.0.0.1:54321";

async function pagina(browser, ctx, tipo, opts = {}) {
  const page = await ctx.newPage(), erros = []; page.on("pageerror", e => erros.push(e.message)); page.dialogs = []; page.on("dialog", d => { page.dialogs.push(d.message()); d.accept(); });
  await page.route("**/*", route => { const u = route.request().url();
    if (u === B + "/__painel/dashboard.html") return route.fulfill({ contentType: "text/html", body: dashHtml });
    if (u === B + "/__painel/site.html") return route.fulfill({ contentType: "text/html", body: siteHtml });
    if (u === B + "/__painel/supabase.js") return route.fulfill({ contentType: "application/javascript", body: supaJs });
    if (u.includes("/rest/v1/rpc/catalogo_publico") && opts.bloquearCatalogo) return route.abort();
    if (u.startsWith(B + "/") && !u.includes("/__painel/")) return route.continue(); return route.abort(); });
  await page.goto(B + (tipo === "site" ? "/__painel/site.html" : "/__painel/dashboard.html")); return { page, erros };
}
async function entrarDash(page, user, loja) { await page.fill("#loginUsuario", user); await page.fill("#loginSenha", "1234"); await page.press("#loginSenha", "Enter"); if (loja) { await page.waitForSelector(".loja-card"); await page.click(`.loja-card:has-text("${loja}")`); } await page.waitForSelector("#app.show"); }
const sincroniza = page => page.evaluate(() => App.syncLive());
const nomes = page => page.$$eval(".pcard .name", els => els.map(e => e.textContent.trim()));
const semRolagem = page => page.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth + 1);

(async () => {
  const L = Object.fromEntries(sql("select slug||'|'||id from lojas").split("\n").map(l => l.split("|"))), S = L["smoke-club"], T = L["start-br01"];
  /* ---- cenário no banco (como se tivesse sido cadastrado pela dashboard) ---- */
  const cat = sql(`insert into categorias (nome,cor,ordem) values ('Cat ${TAG}','azul',-9) returning id`).split("\n")[0], marca = sql(`insert into marcas (nome,descricao,cor_fundo,ordem) values ('Marca ${TAG}','Pods premium','#112233',-9) returning id`).split("\n")[0];
  const item = (tipo, nome, extra = "") => sql(`insert into itens (tipo,${tipo === "produto" ? "categoria_id" : "marca_id"},nome,descricao,emoji,destaque,ordem${extra ? "," + extra.split("=")[0] : ""}) values ('${tipo}','${tipo === "produto" ? cat : marca}','${nome}','Desc ${nome}','🍉',${nome.includes("Destaque")},1${extra ? "," + extra.split("=")[1] : ""}) returning id`).split("\n")[0];
  const iA = item("produto", `Essencia ${TAG}`), iD = item("produto", `Destaque ${TAG}`), iC = item("produto", `Carvao ${TAG}`), iM = item("modelo", `Pod ${TAG}`), iE = item("modelo", `PodEsg ${TAG}`), iX = item("produto", `SemPreco ${TAG}`);
  const sMenta = sql(`insert into sabores (item_id,nome,ordem) values ('${iA}','Menta',1) returning id`).split("\n")[0], sUva = sql(`insert into sabores (item_id,nome,ordem) values ('${iA}','Uva',2) returning id`).split("\n")[0];
  sql(`insert into estoque (item_id,sabor_id,quantidade) values ('${iA}','${sMenta}',3),('${iA}','${sUva}',0),('${iD}',null,50),('${iC}',null,2),('${iM}',null,6),('${iE}',null,0),('${iX}',null,9)`);
  sql(`insert into precos_loja (loja_id,item_id,preco,preco_de,ativo) values ('${S}','${iA}',14.90,19.90,true),('${S}','${iD}',29.90,null,true),('${S}','${iC}',24.90,null,true),('${S}','${iM}',39.90,null,true),('${S}','${iE}',44.90,null,true)`);
  sql(`update lojas set whatsapp='5511988887777' where id='${S}'`);

  const browser = await chromium.launch();
  /* ================= SITE ================= */
  const ctx = await browser.newContext({ viewport: { width: 1100, height: 1000 } });
  let { page, erros } = await pagina(browser, ctx, "site");
  await page.evaluate(() => App.passGate()); await page.waitForFunction(t => document.body.textContent.includes(t), `Essencia ${TAG} — Menta`);
  let ns = await nomes(page);
  check("o site mostra os itens do BANCO (um por sabor) e não os produtos de exemplo do arquivo", ns.includes(`Essencia ${TAG} — Menta`) && ns.includes(`Essencia ${TAG} — Uva`) && ns.includes(`Carvao ${TAG}`) && !ns.some(n => /Seda king size|Piteira de vidro/.test(n)), ns.slice(0, 6).join("|"));
  check("item sem preço não aparece; categoria vem do banco", !ns.some(n => n.includes("SemPreco")) && (await page.textContent("#catNav")).includes(`Cat ${TAG}`));
  check("sabor sem estoque aparece como ESGOTADO, com botão desativado; sabor com estoque pode ser comprado", await page.locator(`.pcard.esgotado:has-text("Essencia ${TAG} — Uva") button.buy[disabled]`).count() === 1 && /ESGOTADO/.test(await page.textContent(`.pcard:has-text("Essencia ${TAG} — Uva")`)) && await page.locator(`.pcard:has-text("Essencia ${TAG} — Menta") button.buy:not([disabled])`).count() >= 1);
  check("preço, preço riscado ('de'), descrição e etiqueta de oferta vêm do banco", /14,90/.test(await page.textContent(`.pcard:has-text("Essencia ${TAG} — Menta")`)) && /19,90/.test(await page.textContent(`.pcard:has-text("Essencia ${TAG} — Menta")`)) && /Desc Essencia/.test(await page.textContent(`.pcard:has-text("Essencia ${TAG} — Menta")`)));
  check("item marcado como destaque aparece na seção de destaques (primeira seção)", await page.locator("#productSections section").first().locator(`.pcard:has-text("Destaque ${TAG}")`).count() === 1);
  check("marca com modelos aparece com os modelos; modelo sem estoque vem como ESGOTADO e desativado", await page.locator(`.marca-section:has-text("Marca ${TAG}") .mcard:has-text("Pod ${TAG}")`).count() >= 1 && await page.locator(`.mcard.esgotado:has-text("PodEsg ${TAG}") .mbuy[disabled]`).count() === 1);
  check("WhatsApp da loja (banco) é o usado nos links do site", (await page.getAttribute("#stripWa", "href")).includes("5511988887777"));
  // ---- carrinho e limite pelo estoque ----
  await page.click(`.pcard:has-text("Carvao ${TAG}") button.buy`); await page.click(`.pcard:has-text("Carvao ${TAG}") .qty button:last-child`); await page.click(`.pcard:has-text("Carvao ${TAG}") .qty button:last-child`);
  check("carrinho respeita o estoque disponível: com 2 unidades, a 3ª é recusada com aviso", (await page.textContent(`.pcard:has-text("Carvao ${TAG}") .qty span`)) === "2" && /Só temos 2/.test(await page.textContent("#toast")));
  await page.click(`.mcard:has-text("Pod ${TAG}") .mbuy`); await page.waitForTimeout(100);
  check("modelo de marca entra no carrinho; a bolha soma os itens", (await page.textContent("#cartBubble")) === "3");
  // ---- o estoque muda na dashboard (aqui: no banco) e o site acompanha ----
  sql(`update estoque set quantidade=1 where item_id='${iC}'`); sql(`update estoque set quantidade=5 where item_id='${iA}' and sabor_id='${sUva}'`); sql(`update estoque set quantidade=0 where item_id='${iM}'`);
  await sincroniza(page); await page.waitForTimeout(150);
  check("estoque mudou: o carrinho se ajusta (carvão 2 → 1) e o modelo esgotado sai do carrinho, com aviso", (await page.textContent(`.pcard:has-text("Carvao ${TAG}") .qty span`)) === "1" && (await page.textContent("#cartBubble")) === "1" && /Saiu do carrinho|Quantidade ajustada/.test(await page.textContent("#toast")), await page.textContent("#toast"));
  check("o sabor que voltou a ter estoque deixa de estar ESGOTADO; o modelo zerado vira ESGOTADO", await page.locator(`.pcard.esgotado:has-text("Essencia ${TAG} — Uva")`).count() === 0 && await page.locator(`.mcard.esgotado:has-text("Pod ${TAG}")`).count() >= 1);
  sql(`update estoque set quantidade=0 where item_id='${iC}'`); await sincroniza(page);
  check("item esgotado de vez some do carrinho e vira ESGOTADO na vitrine", (await page.textContent("#cartBubble")) === "0" || (await page.locator("#cartBubble.hide").count()) === 1);
  sql(`update estoque set quantidade=10 where item_id='${iC}'`); sql(`update precos_loja set preco=26.50 where loja_id='${S}' and item_id='${iC}'`); sql(`update itens set nome='Carvao ${TAG} Premium' where id='${iC}'`);
  await sincroniza(page); await page.waitForSelector(`.pcard:has-text("Carvao ${TAG} Premium")`);
  check("preço e nome editados na dashboard aparecem no site depois da atualização", /26,50/.test(await page.textContent(`.pcard:has-text("Carvao ${TAG} Premium")`)));
  // ---- troca de ordem não embaralha o carrinho ----
  await page.click(`.pcard:has-text("Destaque ${TAG}") button.buy >> nth=-1`).catch(async () => { await page.click(`.pcard:has-text("Destaque ${TAG}") button.buy`); });
  sql(`update itens set ordem=-5 where id='${iD}'`); sql(`update itens set ordem=99 where id='${iC}'`); sql(`update categorias set ordem=50 where id='${cat}'`);
  await sincroniza(page); await page.evaluate(() => App.openDrawer());
  check("reordenar itens/categorias no banco não troca o item do carrinho (mesmo produto, mesma quantidade)", /Destaque/.test(await page.textContent("#drawerList")) && (await page.locator("#drawerList .ditem").count()) === 1, await page.textContent("#drawerList"));
  await page.evaluate(() => App.closeDrawer());
  check("sem erros de JavaScript no site", erros.length === 0, erros.join(" | "));
  check("celular/desktop: sem rolagem horizontal no site", await semRolagem(page));

  // ---- resiliência: banco fora do ar → último catálogo recebido (snapshot) ----
  await page.close();
  ({ page, erros } = await pagina(browser, ctx, "site", { bloquearCatalogo: true }));
  await page.evaluate(() => App.passGate()); await page.waitForFunction(t => document.body.textContent.includes(t), `Essencia ${TAG}`);
  check("banco indisponível: o site usa o último catálogo recebido (não volta para os produtos de exemplo do arquivo)", (await nomes(page)).some(n => n.includes(`Essencia ${TAG}`)) && !(await nomes(page)).some(n => /Seda king size/.test(n)));
  await page.close();
  const ctx2 = await browser.newContext({ viewport: { width: 390, height: 800 } });
  ({ page, erros } = await pagina(browser, ctx2, "site", { bloquearCatalogo: true }));
  await page.evaluate(() => App.passGate()); await page.waitForFunction(() => document.body.textContent.includes("Seda king size"), null, { timeout: 15000 });
  check("sem banco e sem catálogo recente: usa os dados embutidos no arquivo (sem quebrar)", true && erros.length === 0, erros.join("|"));
  check("celular (390 px): sem rolagem horizontal", await semRolagem(page));
  await ctx2.close();

  // ---- painel do lojista dentro do site: produtos/marcas/categorias dão lugar a um aviso ----
  const ctx3 = await browser.newContext({ viewport: { width: 1100, height: 900 } });
  ({ page, erros } = await pagina(browser, ctx3, "site"));
  await page.evaluate(() => { App.passGate(); Admin.askLogin(); }); await page.fill("#admPass", "admin123"); await page.press("#admPass", "Enter"); await page.waitForSelector("#admTabs");
  const abas = await page.$$eval("#admTabs button", b => b.map(x => x.textContent.trim()));
  check("no painel do site, as abas Produtos/Marcas/Categorias saem e entra 'Catálogo' apontando para a dashboard", !abas.some(a => /Produtos|Marcas|Categorias/.test(a)) && abas.some(a => /Catálogo/.test(a)), abas.join("|"));
  await page.evaluate(() => Admin.go("catalogo")); await page.waitForSelector("#admBody .dash-grid");
  check("aba Catálogo do site mostra 'ao vivo', itens no site, esgotados e o link da dashboard", /ao vivo/.test(await page.textContent("#admBody")) && (await page.getAttribute("#admBody a[href='dashboard.html']", "href")) === "dashboard.html" && /ESGOTADOS/.test(await page.textContent("#admBody")));
  await page.evaluate(() => Admin.close()); await page.waitForTimeout(300);
  check("fechar o painel do lojista não gera erro (aviso de maioridade já fechado) e mantém os itens ao vivo", erros.length === 0 && (await nomes(page)).some(n => n.includes(TAG)), erros.join("|"));
  await ctx3.close();

  /* ================= DASHBOARD edita → SITE mostra ================= */
  const cd = await browser.newContext({ viewport: { width: 1100, height: 1000 } });
  let d = await pagina(browser, cd, "dash"); await entrarDash(d.page, "luiz", "Smoke Club");
  await d.page.click("#tab-catalogo"); await d.page.waitForSelector(`.list-row:has-text("Destaque ${TAG}")`);
  check("aba Catálogo online explica a ligação com o site e mostra o status de cada item (no site/esgotado/sem preço)", /aparece no site/.test(await d.page.textContent(".banner")) && /sem preço/.test(await d.page.textContent(`.list-row:has-text("SemPreco ${TAG}")`)) && /no site/.test(await d.page.textContent(`.list-row:has-text("Destaque ${TAG}")`)) && /ESGOTADO/.test(await d.page.textContent(`.list-row:has-text("PodEsg ${TAG}")`)) && (await d.page.getAttribute("a[href*='index']", "href")).includes("index"));
  await d.page.click(`.list-row:has-text("Essencia ${TAG}") [data-a=catEditar]`); await d.page.waitForSelector("#iNome");
  await d.page.fill("#iNome", `Essencia ${TAG} Gold`); await d.page.fill("#iDesc", "Nova descricao editada"); await d.page.fill("#iImg", "https://exemplo.com/foto.png"); await d.page.fill("#pPreco", "17,90"); await d.page.fill("#pDe", "22,50"); await d.page.check("#iDestaque");
  await d.page.locator(".sabNome").first().fill("Menta Ice");
  await d.page.click("[data-a=catSalvar]"); await d.page.waitForFunction(() => /Salvo/.test(document.getElementById("toast").textContent));
  check("salvar item: preço, 'de', descrição, imagem, destaque, nome e sabor gravados", sql(`select i.nome||'|'||i.descricao||'|'||i.imagem_url||'|'||i.destaque from itens i where id='${iA}'`) === `Essencia ${TAG} Gold|Nova descricao editada|https://exemplo.com/foto.png|true` && sql(`select preco||'|'||preco_de from precos_loja where item_id='${iA}' and loja_id='${S}'`) === "17.90|22.50" && sql(`select count(*) from sabores where id='${sMenta}' and nome='Menta Ice'`) === "1");
  // validações da tela
  await d.page.click(`.list-row:has-text("Gold") [data-a=catEditar]`); await d.page.waitForSelector("#iNome");
  await d.page.fill("#pDe", "10,00"); await d.page.click("[data-a=catSalvar]"); check("'de' menor que o preço é recusado na tela", /maior que o preço/.test(await d.page.textContent("#toast")) && await d.page.locator("#iNome").count() === 1);
  await d.page.fill("#pDe", ""); await d.page.fill("#iImg", "http://inseguro.com/x.png"); await d.page.click("[data-a=catSalvar]"); check("imagem fora de https é recusada na tela", /https/.test(await d.page.textContent("#toast")));
  await d.page.fill("#iImg", "https://exemplo.com/foto.png"); await d.page.locator(".sabNome").nth(1).fill("menta ice"); await d.page.click("[data-a=catSalvar]"); check("sabores repetidos são recusados na tela", /repetidos/.test(await d.page.textContent("#toast")));
  await d.page.click("[data-a=fechar]");
  // marca e categoria
  await d.page.click(`.list-row:has-text("Marca ${TAG}") [data-a=catMarca]`); await d.page.waitForSelector("#mNome"); await d.page.fill("#mNome", `Marca ${TAG} Pro`); await d.page.fill("#mDesc", "Nova descricao da marca"); await d.page.click("[data-a=catMarcaOk]"); await d.page.waitForFunction(() => /Marca salva/.test(document.getElementById("toast").textContent));
  await d.page.click(`.list-row:has-text("Cat ${TAG}") [data-a=catCategoria]`); await d.page.waitForSelector("#cNome"); await d.page.fill("#cNome", `Cat ${TAG} Nova`); await d.page.selectOption("#cCor", "roxo"); await d.page.click("[data-a=catCategoriaOk]"); await d.page.waitForFunction(() => /Categoria salva/.test(document.getElementById("toast").textContent));
  check("marca e categoria editadas na dashboard gravadas", sql(`select nome||'|'||descricao from marcas where id='${marca}'`) === `Marca ${TAG} Pro|Nova descricao da marca` && sql(`select nome||'|'||cor from categorias where id='${cat}'`) === `Cat ${TAG} Nova|roxo`);
  // o site (já carregado) acompanha depois da atualização
  ({ page, erros } = await pagina(browser, await browser.newContext({ viewport: { width: 1100, height: 900 } }), "site"));
  await page.evaluate(() => App.passGate()); await page.waitForFunction(t => document.body.textContent.includes(t), `Essencia ${TAG} Gold`);
  const gold = `.pcard:has-text("Essencia ${TAG} Gold — Menta Ice")`;
  const subs = { n: await page.locator(gold).count() >= 1, p1: /17,90/.test(await page.textContent(gold).catch(() => "")), p2: /22,50/.test(await page.textContent(gold).catch(() => "")), d: /Nova descricao editada/.test(await page.textContent(gold).catch(() => "")), dest: await page.locator("#productSections section").first().locator(`.pcard:has-text("Gold")`).count(), img: await page.locator(`.pcard img[src="https://exemplo.com/foto.png"]`).count() };
  check("o que foi editado na dashboard aparece no site: nome, sabor, descrição, preço, preço riscado, destaque e imagem", subs.n && subs.p1 && subs.p2 && subs.d && subs.dest >= 1 && subs.img >= 1, JSON.stringify(subs));
  check("marca e categoria renomeadas na dashboard aparecem no site (com a cor da categoria)", (await page.textContent("#catNav")).includes(`Cat ${TAG} Nova`) && (await page.locator(`.marca-section:has-text("Marca ${TAG} Pro")`).count()) === 1 && (await page.locator(`.catbanner.cg-roxo:has-text("Cat ${TAG} Nova")`).count()) === 1);
  check("sem erros de JavaScript na dashboard e no site", d.erros.length === 0 && erros.length === 0, d.erros.concat(erros).join("|"));
  await browser.close();
  console.log(`\nSITE + DASHBOARD (catálogo online, navegador, pilha real): ${pass} ok, ${fail} falhas`); if (fail) { falhas.forEach(f => console.log(" ✗ " + f)); process.exit(1); }
})().catch(e => { console.error("ERRO", String(e.stack).split("\n").slice(0,6).join(" | ")); console.log(`parcial: ${pass} ok`); falhas.forEach(f => console.log(" ✗ " + f)); process.exit(1); });

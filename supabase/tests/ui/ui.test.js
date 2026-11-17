/* Teste da tela no Chromium com Supabase falso (fake-supabase.js). Uso: NODE_PATH=/opt/node22/lib/node_modules node ui.test.js */
const { chromium } = require("playwright");
const fs = require("fs"), path = require("path");
const root = path.resolve(__dirname, "../../..");
const html = fs.readFileSync(path.join(root, "dashboard.html"), "utf8");
const fake = fs.readFileSync(path.join(__dirname, "fake-supabase.js"), "utf8");
const sql = ["002_melhorias.sql", "003_caixa_avisos.sql"].map(f => fs.readFileSync(path.join(root, "supabase", f), "utf8")).join("\n");

// contrato: nomes de parâmetros reais das funções (obrigatório = sem "default")
const CONTRACT = {};
for (const m of sql.matchAll(/create or replace function (\w+)\(([^)]*)\)\s*returns/gi)) {
  const ps = m[2].split(",").map(s => s.trim()).filter(Boolean).map(s => ({ n: s.split(/\s+/)[0], d: /\bdefault\b/i.test(s) }));
  CONTRACT[m[1]] = { all: ps.map(p => p.n), required: ps.filter(p => !p.d).map(p => p.n) };
}

let pass = 0, fail = 0; const falhas = [];
const check = (nome, cond, extra) => { if (cond) pass++; else { fail++; falhas.push(nome + (extra ? " → " + extra : "")); } };

async function novaPagina(browser) {
  const ctx = await browser.newContext({ viewport: { width: 1100, height: 900 } });
  const page = await ctx.newPage(); page.on('dialog', d => d.accept());
  const erros = []; page.on("pageerror", e => erros.push(e.message)); page.on("console", m => { if (m.type() === "error" && !/Failed to load resource/.test(m.text())) erros.push("console: " + m.text()); });
  await page.route("**/*", route => {
    const u = route.request().url();
    if (u.endsWith("/dashboard.html")) return route.fulfill({ contentType: "text/html", body: html });
    if (u.includes("supabase.min.js")) return route.fulfill({ contentType: "application/javascript", body: `window.__CONTRACT=${JSON.stringify(CONTRACT)};\n` + fake });
    return route.abort();
  });
  await page.goto("http://painel.test/dashboard.html");
  return { page, erros, ctx };
}
const login = async (page, u, s = "1234") => { await page.fill("#loginUsuario", u); await page.fill("#loginSenha", s); await page.press("#loginSenha", "Enter"); };
const toastTxt = page => page.textContent("#toast");

(async () => {
  const browser = await chromium.launch();
  let { page, erros } = await novaPagina(browser);

  /* LOGIN */
  await login(page, "luiz", "errada");
  await page.waitForFunction(() => document.getElementById("loginErr").textContent.length > 0);
  check("login errado mostra mensagem", /inválidos/.test(await page.textContent("#loginErr")));
  check("botão volta ao normal após erro", await page.isEnabled("#btnLogin") && (await page.textContent("#btnLogin")) === "Entrar");
  await page.evaluate(() => { window.__netDown = true; });
  await login(page, "luiz");
  await page.waitForFunction(() => /conex|fetch/i.test(document.getElementById("loginErr").textContent));
  check("sem internet: mensagem clara", /Sem conexão/.test(await page.textContent("#loginErr")));
  await page.evaluate(() => { window.__netDown = false; });
  await login(page, " LUIZ ");   // espaços/maiúsculas
  await page.waitForSelector("#seletorLoja:not(.hidden)");
  check("2 lojas → seletor de loja", (await page.locator(".loja-card").count()) === 2);
  await page.click(".loja-card:has-text('Smoke Club')");
  await page.waitForSelector("#app.show");
  await page.waitForSelector(".kpi");
  check("dono vê aba Catálogo", await page.locator("#tab-catalogo").count() === 1);
  check("botão trocar de loja visível", await page.isVisible("#btnTrocarLoja"));
  check("indicador de tempo real ligado", await page.evaluate(() => document.getElementById("liveDot").classList.contains("on")));
  check("sem XSS no painel", !(await page.evaluate(() => window.__xss)));

  /* ESTOQUE: busca não perde foco; atualização em tempo real preserva o campo */
  await page.click("#tab-estoque");
  await page.focus("#estBusca"); await page.keyboard.type("ignite");
  check("busca filtra", (await page.locator("#estLista .item-row").count()) === 3);
  await page.evaluate(() => window.__emit("estoque")); await page.waitForTimeout(900);
  check("busca mantém foco e texto após tempo real", await page.evaluate(() => document.activeElement.id === "estBusca" && document.activeElement.value === "ignite"));
  await page.keyboard.type("x");   // continua digitando sem perder
  check("continua digitando após digitar", (await page.inputValue("#estBusca")) === "ignitex");
  await page.fill("#estBusca", "");
  check("estoque baixo/zerado aparece no filtro", await (async () => { await page.click("[data-id=zero]"); return (await page.locator("#estLista .item-row").count()) === 1; })());
  await page.click("[data-id=inativo]");
  check("filtro inativos", (await page.locator("#estLista .item-row").count()) === 1);
  check("sem XSS no estoque", !(await page.evaluate(() => window.__xss)));
  await page.click("[data-id=todos]");
  await page.click("#estLista .item-row:has-text('Menta')");
  await page.waitForSelector("#adjQtd");
  await page.fill("#adjQtd", "-2"); await page.fill("#adjObs", "quebrou"); await page.click("[data-a=estAjustar]");
  await page.waitForFunction(() => window.__db.estoque.find(e => e.id === "e1").quantidade === 3);
  check("ajuste de estoque vai pela RPC e entra no histórico", await page.locator(".modal-box:has-text('quebrou')").count() === 1);
  await page.fill("#adjQtd", "-99"); await page.click("[data-a=estAjustar]");
  await page.waitForFunction(() => /negativo/.test(document.getElementById("toast").textContent));
  check("ajuste negativo recusado e botão reabilita", await page.isEnabled("[data-a=estAjustar]"));
  await page.fill("#cntQtd", "7"); await page.click("[data-a=estContar]");
  await page.waitForFunction(() => window.__db.estoque.find(e => e.id === "e1").quantidade === 7);
  check("contagem física define total", true);
  await page.click("[data-a=fechar]");

  /* NOVA VENDA */
  await page.click("#tab-venda");
  check("item sem preço fica desabilitado", await page.locator(".sel-result.off:has-text('Sem preço')").count() === 1);
  check("item sem estoque fica desabilitado", await page.locator(".sel-result.off:has-text('Esgotado')").count() === 1);
  check("item inativo não aparece para venda", await page.locator(".sel-result:has-text('inativo')").count() === 0);
  await page.focus("#vBusca"); await page.keyboard.type("menta");
  check("busca de venda mantém foco", await page.evaluate(() => document.activeElement.id === "vBusca"));
  await page.click(".sel-result:has-text('Menta')");
  for (let i = 0; i < 9; i++) await page.click("[data-a=vMais]");
  check("carrinho respeita estoque", (await page.textContent(".qty span")) === "7");
  await page.click("[data-a=vMenos]"); await page.click("[data-a=vMenos]");
  check("botões +/-", (await page.textContent(".qty span")) === "5");
  await page.fill("#vBusca", "carv");
  await page.click(".sel-result:has-text('Carvão')");
  check("nome com HTML é escapado (sem XSS)", !(await page.evaluate(() => window.__xss)));
  await page.fill("#vCliNome", "Ana");
  check("autocompleta telefone do cliente", (await page.inputValue("#vCliTel")) === "11999990000");
  await page.fill("#vDesc", "10,50");
  check("desconto digitado mantém foco", await page.evaluate(() => document.activeElement.id === "vDesc" && document.activeElement.value === "10,50"));
  const totalTxt = await page.textContent(".tt-row.big");
  check("total = 5×100 + 12,50 − 10,50 = 502,00", /502,00/.test(totalTxt), totalTxt);
  await page.selectOption("#vForma", "Dinheiro");
  // falha de servidor: botão reabilita, carrinho mantido, mesma chave no reenvio
  await page.evaluate(() => { window.__failNext = "Estoque insuficiente para Menta"; });
  await page.click("[data-a=vConfirmar]"); await page.click("[data-a=vEnviar]");
  await page.waitForFunction(() => /insuficiente/.test(document.getElementById("toast").textContent));
  check("erro da venda: carrinho preservado", await page.locator(".cart-item").count() === 2);
  check("erro da venda: botão confirmar reabilita", await page.isEnabled("[data-a=vEnviar]"));
  await page.click("[data-a=vEnviar]");
  await page.waitForSelector("text=Venda registrada");
  const chamadas = await page.evaluate(() => window.__rpcLog.filter(l => l.name === "registrar_venda"));
  check("reenvio idêntico usa a MESMA chave de idempotência", chamadas.length === 2 && chamadas[0].args.p_chave === chamadas[1].args.p_chave && /^[0-9a-f-]{36}$/.test(chamadas[0].args.p_chave));
  check("RPC recebe só item/sabor/quantidade (preço é do servidor)", JSON.stringify(Object.keys(chamadas[1].args.p_itens[0]).sort()) === '["item_id","quantidade","sabor_id"]');
  const est = await page.evaluate(() => ({ menta: window.__db.estoque.find(e => e.id === "e1").quantidade, carvao: window.__db.estoque.find(e => e.id === "e4").quantidade, vendas: window.__db.vendas.length }));
  check("estoque baixou 1× só (7−5=2, 10−1=9) e 1 venda", est.menta === 2 && est.carvao === 9 && est.vendas === 1, JSON.stringify(est));
  await page.click("[data-a=vCancelarUltima]");
  await page.waitForFunction(() => window.__db.vendas[0].status === "cancelada");
  check("desfazer venda devolve estoque", await page.evaluate(() => window.__db.estoque.find(e => e.id === "e1").quantidade === 7));
  check("venda com desconto > subtotal é barrada na tela", await (async () => {
    await page.click("#tab-venda"); await page.fill("#vBusca", ""); await page.click(".sel-result:has-text('Menta')"); await page.fill("#vDesc", "999"); await page.click("[data-a=vConfirmar]");
    return /desconto/i.test(await toastTxt(page)); })());
  await page.click("[data-a=vLimpar]");

  /* VENDAS */
  await page.click("#tab-vendas"); await page.waitForSelector("#vendasLista .list-row");
  check("histórico mostra venda cancelada", await page.locator("#vendasLista .tag.cancelada").count() === 1);

  /* FINANCEIRO */
  await page.click("#tab-financeiro"); await page.waitForSelector(".kpi");
  await page.click("[data-a=finForm]");
  await page.selectOption("#lTipo", "saida"); await page.fill("#lDesc", "Compra pods"); await page.fill("#lValor", "300,50");
  await page.selectOption("#lStatus", "pendente"); await page.click("[data-a=finSalvar]");
  check("pendente sem vencimento é barrado", /vencimento/.test(await toastTxt(page)));
  await page.fill("#lVenc", "2020-01-01"); await page.click("[data-a=finSalvar]");
  await page.waitForSelector(".list-row:has-text('Compra pods')");
  check("conta vencida aparece como atrasada", await page.locator(".list-row:has-text('Compra pods') .tag.atrasado").count() === 1);
  await page.click(".list-row:has-text('Compra pods') [data-a=finPagar]");
  await page.waitForSelector(".list-row:has-text('Compra pods') .tag.pago");
  check("pagar vai pela RPC (não update direto)", await page.evaluate(() => window.__rpcLog.some(l => l.name === "pagar_lancamento")));
  const dl = page.waitForEvent("download"); await page.click("[data-a=finCsv]"); const d = await dl;
  const csv = fs.readFileSync(await d.path(), "utf8");
  check("CSV exportado com BOM e ;", csv.startsWith("﻿") && csv.includes(";") && csv.includes("300,5"));

  /* WHATSAPP */
  await page.click("#tab-whats");
  let wa = await page.textContent("#waPreview");
  check("lista: tem item com estoque e preço", wa.includes("Ignite V50") && wa.includes("Menta") && wa.includes("Uva"));
  check("lista: não tem esgotado, inativo nem sem preço", !wa.includes("Esgotado") && !wa.includes("Item inativo") && !wa.includes("Sem preço"));
  await page.uncheck("#waPreco"); wa = await page.textContent("#waPreview");
  check("toggle de preços", !wa.includes("R$"));
  await page.uncheck("#waSabores"); wa = await page.textContent("#waPreview");
  check("toggle de sabores", !wa.includes("Menta"));
  check("botão enviar funciona sem número da loja", await page.isEnabled("[data-a=waEnviar]"));

  /* CATÁLOGO */
  await page.click("#tab-catalogo");
  await page.selectOption("#niGrupo", "m:m1"); await page.fill("#niNome", "Elf Bar"); await page.fill("#niSabores", "Maçã, maçã");
  await page.click("[data-a=catItem]");
  check("sabores repetidos barrados", /repetidos/.test(await toastTxt(page)));
  await page.fill("#niSabores", "Maçã, Limão"); await page.fill("#niQtd", "4"); await page.click("[data-a=catItem]");
  await page.waitForFunction(() => window.__db.itens.some(i => i.nome === "Elf Bar"));
  check("item criado via RPC com 2 sabores × 4 un", await page.evaluate(() => window.__db.estoque.filter(e => window.__db.sabores.find(s => s.id === e.sabor_id && s.item_id === window.__db.itens.find(i => i.nome === "Elf Bar").id)).every(e => e.quantidade === 4)));
  await page.click(".list-row:has-text('Elf Bar') [data-a=catEditar]");
  await page.fill("#pPreco", "49,9"); await page.click("[data-a=catSalvar]");
  await page.waitForFunction(() => window.__db.precos_loja.some(p => p.preco === 49.9));
  check("preço salvo só para a loja atual", await page.evaluate(() => window.__db.precos_loja.filter(p => p.preco === 49.9).every(p => p.loja_id === "loja-1")));
  await page.fill("#lojaWpp", "+55 (11) 99999-0000"); await page.click("[data-a=catWpp]");
  await page.waitForFunction(() => window.__db.lojas[0].whatsapp === "5511999990000");
  check("WhatsApp da loja normalizado", true);


  /* AVISOS (painel) */
  await page.click("#tab-painel"); await page.waitForSelector(".aviso");
  check("avisos: seção aparece com aviso novo (não lido)", (await page.locator(".aviso:not(.lido)").count()) === 1 && (await page.textContent(".card h3")).includes("Avisos"));
  check("avisos: título com HTML é escapado (sem XSS)", !(await page.evaluate(() => window.__xss)) && (await page.locator(".aviso b b").count()) === 0);
  await page.click("[data-a=avisoLido]"); await page.waitForSelector(".aviso.lido");
  check("avisos: marcar lido vai pelo servidor", await page.evaluate(() => window.__db.avisos[0].lido === true));
  await page.evaluate(() => window.__db.financeiro_lancamentos.push({ id: "x1", loja_id: "loja-1", tipo: "saida", categoria: "aluguel", valor: 50, status: "pendente", vencimento: "2020-01-01", criado_em: new Date().toISOString(), data_ref: new Date().toISOString() }));
  await page.click("#tab-caixa"); await page.click("#tab-painel"); await page.waitForSelector(".aviso.urgente");
  check("alerta de conta vencida aparece como URGENTE no topo", /vencida/.test(await page.textContent(".aviso")) && await page.locator(".aviso.urgente").count() === 1);
  await page.click(".aviso.urgente [data-a=avisoLido]"); await page.waitForSelector(".aviso.urgente.lido");
  check("marcar alerta como lido NÃO resolve a pendência", await page.evaluate(() => window.__db.financeiro_lancamentos.filter(l => l.status === "pendente").length === 1));
  await page.evaluate(() => { window.__db.financeiro_lancamentos = window.__db.financeiro_lancamentos.filter(l => l.id !== "x1"); });
  await page.click("[data-a=avisoForm][data-id='']"); await page.fill("#avTitulo", "Comunicado Smoke"); await page.fill("#avDesc", "Fechar o caixa às 22h"); await page.selectOption("#avPrio", "atencao");
  await page.click("[data-a=avisoSalvar]"); await page.waitForSelector(".aviso:has-text('Comunicado Smoke')");
  check("gerente publica aviso para a loja", await page.evaluate(() => { const a = window.__db.avisos.find(x => x.titulo === "Comunicado Smoke"); return a && a.prioridade === "atencao" && a.lojas.includes("Smoke Club") && !a.global; }));

  /* CAIXA */
  await page.click("#tab-caixa"); await page.waitForSelector("#cxSaldo");
  await page.fill("#cxSaldo", "100,505"); await page.click("[data-a=cxAbrir]");
  check("saldo inicial com 3 casas é barrado", /casas/.test(await toastTxt(page)));
  await page.fill("#cxSaldo", "100,50"); await page.click("[data-a=cxAbrir]"); await page.waitForSelector("[data-a=cxFechar]");
  check("abrir caixa: dinheiro esperado = saldo inicial", /100,50/.test(await page.textContent(".kpi.good")));
  check("sem formulário de abertura com caixa aberto (1 por loja)", await page.locator("#cxSaldo").count() === 0);
  const lancar = async (tipo, valor, meio) => { await page.click(`[data-a=cxMov][data-id=${tipo}]`); if (meio) await page.selectOption("#mvMeio", meio); await page.fill("#mvValor", valor); await page.fill("#mvCat", "teste"); await page.click("[data-a=cxMovSalvar]"); };
  await lancar("entrada", "40", "pix"); await page.waitForSelector(".list-row:has-text('Pix')");
  check("Pix de 40 NÃO soma no dinheiro esperado", /100,50/.test(await page.textContent(".kpi.good")));
  await lancar("saida", "1,005", "dinheiro");
  check("valor com 3 casas é barrado na tela", /2 casas/.test(await toastTxt(page)));
  await page.click("[data-a=fechar]");
  await lancar("saida", "500", "dinheiro"); await page.waitForFunction(() => /insuficiente/.test(document.getElementById("toast").textContent));
  check("saída maior que o dinheiro do caixa recusada (e botão reabilita)", await page.isEnabled("[data-a=cxMovSalvar]"));
  await page.click("[data-a=fechar]");
  await lancar("saida", "20,50", "dinheiro"); await page.waitForSelector(".list-row:has-text('20,50')");
  check("saída em dinheiro reduz o esperado (80,00)", /80,00/.test(await page.textContent(".kpi.good")));
  await page.click(".list-row:has-text('20,50') [data-a=cxEstornar]"); await page.fill("#esMotivo", "digitei errado"); await page.click("[data-a=cxEstornarOk]");
  await page.waitForSelector(".tag.cancelada:has-text('estornada')");
  check("estorno preserva o original e devolve o valor (100,50)", /100,50/.test(await page.textContent(".kpi.good")) && await page.evaluate(() => window.__db.caixa_movs.filter(m => m.categoria === "teste" && m.valor === 20.5).length === 1 && window.__db.caixa_movs.some(m => m.tipo === "estorno")));
  check("estornado não oferece estornar de novo", await page.locator(".list-row:has-text('20,50'):has(.tag.cancelada) [data-a=cxEstornar]").count() === 0);
  await page.click("[data-a=cxFechar]"); await page.fill("#fcVal", "90");
  check("fechamento mostra a diferença ao digitar (−10,50)", /10,50/.test(await page.textContent("#fcDif")));
  await page.click("[data-a=cxFecharOk]");
  check("diferença sem justificativa é barrada", /justificativa/.test(await toastTxt(page)));
  await page.fill("#fcJust", "faltou troco"); await page.click("[data-a=cxFecharOk]"); await page.waitForSelector("#cxSaldo");
  check("caixa fechado com diferença registrada", await page.evaluate(() => { const c = window.__db.caixas[0]; return c.status === "fechado" && c.diferenca === -10.5 && c.esperado === 100.5; }));
  check("após fechar: mostra o último fechamento e permite reabrir (gerente)", await page.locator("[data-a=cxReabrir]").count() === 1 && /10,50/.test(await page.textContent(".card:has(h3:has-text('Último'))")));
  await page.click("[data-a=cxReabrir]"); await page.fill("#raMotivo", "abc"); await page.click("[data-a=cxReabrirOk]");
  check("reabrir exige motivo (mín. 5 letras)", /motivo/.test(await toastTxt(page)));
  await page.fill("#raMotivo", "contei errado"); await page.click("[data-a=cxReabrirOk]"); await page.waitForSelector("[data-a=cxFechar]");
  check("caixa reaberto", await page.evaluate(() => window.__db.caixas[0].status === "aberto" && window.__db.caixas[0].reaberturas === 1));
  await page.click("[data-a=cxFechar]"); await page.fill("#fcVal", "100,50"); await page.click("[data-a=cxFecharOk]"); await page.waitForSelector("#cxSaldo");

  /* HISTÓRICO */
  await page.click("#tab-historico"); await page.waitForSelector(".dia-row");
  check("histórico por dia mostra abertura, entradas, saídas e fechamento", /Abertura/.test(await page.textContent(".dia-row")) && /Fechamento/.test(await page.textContent(".dia-row")) && /100,50/.test(await page.textContent(".dia-row")));
  await page.click(".dia-h"); await page.waitForSelector(".dia-det:not(.hidden) >> text=Movimentações do caixa");
  check("expandir o dia mostra os detalhes", /teste/.test(await page.textContent(".dia-det")));
  await page.selectOption("#hSit", "aberto"); await page.waitForFunction(() => document.querySelectorAll(".dia-row").length === 0);
  check("filtro de situação funciona (nenhum caixa aberto)", await page.locator(".dia-row").count() === 0);

  /* TROCAR LOJA sem novo login */
  await page.click("[data-a=trocarLoja]"); await page.waitForSelector("#seletorLoja:not(.hidden)");
  await page.click(".loja-card:has-text('EZ Store')");
  await page.waitForFunction(() => document.getElementById("lojaNomeChip").textContent.includes("EZ Store"));
  await page.click("#tab-venda"); await page.fill("#vBusca", "");
  check("preço é por loja (EZ: 90)", await page.locator(".sel-result:has-text('Menta') b:last-child").first().textContent().then(t => /90,00/.test(t)));
  check("EZ não vê clientes da Smoke Club", await (async () => { await page.click("#tab-clientes"); return (await page.locator("#cliLista .list-row").count()) === 0; })());

  /* OPERADOR */
  await page.evaluate(() => document.querySelector("[data-a=logout]").click()).catch(() => {});
  ({ page, erros } = await novaPagina(browser));
  await login(page, "enzo"); await page.waitForSelector("#app.show");
  check("operador (1 loja) entra direto, sem seletor", await page.isHidden("#seletorLoja"));
  check("operador não vê Catálogo nem Trocar loja", await page.locator("#tab-catalogo").count() === 0 && await page.isHidden("#btnTrocarLoja"));
  await page.click("#tab-estoque"); await page.click("#estLista .item-row:has-text('Menta')");
  check("operador não vê controles de ajuste", await page.locator("#adjQtd").count() === 0);
  await page.click("[data-a=fechar]");
  await page.click("#tab-painel"); await page.waitForSelector(".aviso");
  check("operador não vê '+ Novo aviso'", await page.locator("[data-a=avisoForm]").count() === 0);
  await page.click("#tab-caixa"); await page.fill("#cxSaldo", "50"); await page.click("[data-a=cxAbrir]"); await page.waitForSelector("[data-a=cxFechar]");
  check("operador abre caixa mas não vê Ajuste", await page.locator("[data-a=cxMov][data-id=ajuste]").count() === 0 && await page.locator("[data-a=cxMov][data-id=entrada]").count() === 1);
  await page.click("[data-a=cxMov][data-id=entrada]"); await page.fill("#mvValor", "5"); await page.fill("#mvCat", "gorjeta"); await page.click("[data-a=cxMovSalvar]"); await page.waitForSelector(".list-row:has-text('gorjeta')");
  check("operador não vê Estornar", await page.locator("[data-a=cxEstornar]").count() === 0);

  check("nenhum erro de JavaScript em toda a sessão", erros.length === 0, erros.join(" | "));
  await browser.close();
  console.log(`\nTESTES DE TELA: ${pass} ok, ${fail} falhas`);
  falhas.forEach(f => console.log("  ✗ " + f));
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error("ERRO NO TESTE:", e); process.exit(2); });

/* Teste da tela no Chromium com Supabase falso (fake-supabase.js). Uso: NODE_PATH=/opt/node22/lib/node_modules node ui.test.js */
const { chromium } = require("playwright");
const fs = require("fs"), path = require("path");
const root = path.resolve(__dirname, "../../..");
const html = fs.readFileSync(path.join(root, "dashboard.html"), "utf8");
const fake = fs.readFileSync(path.join(__dirname, "fake-supabase.js"), "utf8");
const sql = ["002_melhorias.sql", "003_caixa_avisos.sql", "004_entradas_sem_caixa.sql", "005_pagamentos_comprovantes.sql", "006_limpeza_comprovantes.sql"].map(f => fs.readFileSync(path.join(root, "supabase", f), "utf8")).join("\n");

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

  /* FINANCEIRO: contas, pagamentos parciais, comprovantes */
  await page.click("#tab-financeiro"); await page.waitForSelector(".kpi");
  await page.click("[data-a=finForm]");
  await page.selectOption("#lTipo", "saida"); await page.fill("#lDesc", "Compra pods"); await page.fill("#lValor", "300,50");
  await page.check("#lComp"); await page.click("[data-a=finSalvar]");
  check("conta em aberto sem vencimento é barrada", /vencimento/.test(await toastTxt(page)));
  await page.fill("#lValor", "1,005"); await page.click("[data-a=finSalvar]");
  check("valor com 3 casas é barrado", /casas/.test(await toastTxt(page)));
  await page.fill("#lValor", "300,50"); await page.fill("#lVenc", "2020-01-01"); await page.click("[data-a=finSalvar]");
  await page.waitForSelector(".list-row:has-text('Compra pods')");
  check("conta nova: pendente, com alerta de saldo vencido", await page.locator(".list-row:has-text('Compra pods') .tag.pendente").count() === 1 && await page.locator(".list-row:has-text('Compra pods') .tag.atrasado").count() === 1);
  await page.click(".list-row:has-text('Compra pods')"); await page.waitForSelector("[data-a=finPagForm]");
  check("detalhe mostra valor original, total pago e saldo", /300,50/.test(await page.textContent(".modal-box")) && (await page.locator(".modal-box .kpi").count()) === 3);
  await page.click("[data-a=finPagForm]"); await page.fill("#pgValor", "400"); await page.click("[data-a=finPagSalvar]");
  check("pagamento acima do saldo é barrado na tela", /passa do saldo/.test(await toastTxt(page)));
  await page.fill("#pgValor", "100,10"); await page.selectOption("#pgForma", "Pix"); await page.fill("#pgObs", "sinal"); await page.click("[data-a=finPagSalvar]");
  await page.waitForSelector(".tag.parcial");
  check("1º pagamento: parcialmente paga, pago 100,10 e saldo 200,40", /100,10/.test(await page.textContent(".modal-box .kpi.good")) && /200,40/.test(await page.textContent(".modal-box .kpi.warn")));
  // clique duplo
  await page.click("[data-a=finPagForm]"); await page.fill("#pgValor", "50"); await page.dblclick("[data-a=finPagSalvar]"); await page.waitForFunction(() => window.__db.pagamentos.length >= 2); await page.waitForTimeout(300);
  check("clique duplo NÃO duplica o pagamento", await page.evaluate(() => window.__db.pagamentos.length === 2 && window.__db.pagamentos.filter(p => p.valor === 50).length === 1));
  // falha do servidor e repetição com a MESMA chave
  await page.click("[data-a=finPagForm]"); await page.fill("#pgValor", "25"); await page.evaluate(() => { window.__failPay = "Erro temporário do servidor"; });
  await page.click("[data-a=finPagSalvar]"); await page.waitForFunction(() => /temporário/.test(document.getElementById("toast").textContent));
  check("erro no pagamento: botão reabilita e o formulário continua", await page.isEnabled("[data-a=finPagSalvar]") && await page.locator("#pgValor").count() === 1);
  await page.click("[data-a=finPagSalvar]"); await page.waitForFunction(() => window.__db.pagamentos.length === 3);
  const chamadas2 = await page.evaluate(() => window.__rpcLog.filter(l => l.name === "registrar_pagamento" && l.args.p_valor === 25));
  check("reenvio idêntico usa a mesma chave de repetição e grava 1 pagamento", chamadas2.length === 2 && chamadas2[0].args.p_chave === chamadas2[1].args.p_chave && /^[0-9a-f-]{36}$/.test(chamadas2[0].args.p_chave));
  const pag1 = await page.evaluate(() => window.__db.pagamentos[0].id);
  // comprovantes
  await page.evaluate(() => { window.__opened = []; window.open = u => { window.__opened.push(u); }; });
  await page.setInputFiles(`#arq-${pag1}`, { name: "virus.exe", mimeType: "application/x-msdownload", buffer: Buffer.from("MZ") });
  check("tipo de arquivo não permitido é barrado antes do envio", /Tipo não permitido/.test(await toastTxt(page)) && (await page.evaluate(() => window.__uploads || 0)) === 0);
  await page.setInputFiles(`#arq-${pag1}`, { name: "grande.pdf", mimeType: "application/pdf", buffer: Buffer.alloc(5 * 1024 * 1024 + 1) });
  check("arquivo acima de 5 MB é barrado antes do envio", /5 MB/.test(await toastTxt(page)) && (await page.evaluate(() => window.__uploads || 0)) === 0);
  await page.evaluate(() => { window.__failUpload = "rede caiu"; });
  await page.setInputFiles(`#arq-${pag1}`, { name: "nota.pdf", mimeType: "application/pdf", buffer: Buffer.from("%PDF-1.4 teste") });
  await page.waitForFunction(() => /Falha no envio/.test(document.getElementById("toast").textContent));
  check("falha no upload: pagamento intacto, nada registrado, dá para tentar de novo", await page.evaluate(() => window.__db.pagamentos.length === 3 && window.__db.comprovantes.length === 0));
  await page.evaluate(() => { window.__failReg = "falha ao registrar"; });
  await page.setInputFiles(`#arq-${pag1}`, { name: "nota.pdf", mimeType: "application/pdf", buffer: Buffer.from("%PDF-1.4 teste") });
  await page.waitForSelector("[data-a=finTentar]");
  check("arquivo enviado mas registro falhou: oferece repetir só o registro", await page.evaluate(() => window.__uploads === 1 && window.__db.comprovantes.length === 0));
  await page.click("[data-a=finTentar]"); await page.waitForSelector("[data-a=finBaixar]");
  check("nova tentativa registra o comprovante SEM reenviar o arquivo nem duplicar o pagamento", await page.evaluate(() => window.__uploads === 1 && window.__db.comprovantes.length === 1 && window.__db.pagamentos.length === 3));
  check("pagamento, arquivo e envio aparecem separados (envio ainda pendente)", /Arquivo anexado/.test(await page.textContent(".modal-box")) && /Envio manual:\s*pendente/.test(await page.textContent(".modal-box")));
  await page.click("[data-a=finBaixar]"); await page.waitForFunction(() => window.__opened.length === 1);
  check("download usa link assinado temporário (bucket privado)", await page.evaluate(() => /signed/.test(window.__opened[0]) && /\.pdf/.test(window.__opened[0])));
  await page.click("[data-a=fechar]"); await page.click("#tab-painel"); await page.waitForSelector(".aviso");
  check("alertas DISTINTOS: saldo vencido (urgente) e comprovante com envio pendente (atenção)", await page.locator(".aviso.urgente:has-text('vencida')").count() === 1 && await page.locator(".aviso.atencao:has-text('comprovante')").count() === 1);
  await page.click("#tab-financeiro"); await page.click(".list-row:has-text('Compra pods')"); await page.waitForSelector("[data-a=finEnvio]");
  while (await page.locator("[data-a=finEnvio]").count()) { await page.locator("[data-a=finEnvio]").first().click(); await page.waitForFunction(n => window.__db.envios.length >= n, 1); await page.waitForTimeout(150); }
  check("confirmar envio é uma informação separada do arquivo e fica registrada", await page.evaluate(() => window.__db.envios.length === 3 && window.__db.comprovantes.length === 1) && /confirmado por/.test(await page.textContent(".modal-box")));
  // estorno
  await page.click(".card:has-text('100,10') [data-a=finEstornarForm]"); await page.fill("#esPgMotivo", "abc"); await page.click("[data-a=finEstornarOk]");
  check("estorno sem motivo suficiente é barrado", /motivo/.test(await toastTxt(page)));
  await page.fill("#esPgMotivo", "valor lançado errado"); await page.click("[data-a=finEstornarOk]"); await page.waitForSelector(".tag:has-text('estornado')");
  check("estorno: original preservado + estorno registrado; total pago 75,00", await page.evaluate(() => window.__db.pagamentos.length === 4 && window.__db.pagamentos.filter(p => p.valor === 100.1).length === 2) && /75,00/.test(await page.textContent(".modal-box .kpi.good")));
  check("pagamento estornado não oferece novo estorno", await page.locator(".card:has-text('estornado') [data-a=finEstornarForm]").count() === 0);
  await page.click("[data-a=finPagForm]"); await page.fill("#pgValor", "225,50"); await page.click("[data-a=finPagSalvar]"); await page.waitForSelector(".tag.pago");
  check("quitação: conta paga, sem botão de novo pagamento", await page.locator("[data-a=finPagForm]").count() === 0 && /0,00/.test(await page.textContent(".modal-box .kpi:nth-child(3)")));
  await page.click("[data-a=fechar]");
  // cancelar conta (sem pagamentos)
  await page.click("[data-a=finForm]"); await page.fill("#lDesc", "Conta a cancelar"); await page.fill("#lValor", "20"); await page.fill("#lVenc", "2030-01-01"); await page.click("[data-a=finSalvar]");
  await page.waitForSelector(".list-row:has-text('Conta a cancelar')"); await page.click(".list-row:has-text('Conta a cancelar')"); await page.click("[data-a=finCancelarForm]"); await page.fill("#caMotivo", "duplicada"); await page.click("[data-a=finCancelarOk]");
  await page.waitForSelector(".modal-box .tag.cancelada"); check("conta cancelada não aceita pagamentos", await page.locator("[data-a=finPagForm]").count() === 0 && /cancelada/.test(await page.textContent(".modal-box")));
  await page.click("[data-a=fechar]");
  // já paga: falha no pagamento depois de criar a conta
  await page.click("[data-a=finForm]"); await page.fill("#lDesc", "Conta ja paga"); await page.fill("#lValor", "40"); await page.check("#lJaPaga"); await page.evaluate(() => { window.__failPay = "indisponível"; });
  await page.click("[data-a=finSalvar]"); await page.waitForFunction(() => /Conta criada, mas o pagamento não foi registrado/.test(document.getElementById("toast").textContent));
  await page.waitForSelector(".modal-box [data-a=finPagForm]");
  check("já paga + falha no pagamento: conta criada UMA vez, pendente, detalhe aberto para tentar de novo", await page.evaluate(() => window.__db.financeiro_lancamentos.filter(l => l.descricao === "Conta ja paga").length === 1) && await page.locator("[data-a=finPagForm]").count() === 1);
  await page.click("[data-a=finPagForm]"); await page.click("[data-a=finPagSalvar]"); await page.waitForSelector(".tag.pago"); await page.click("[data-a=fechar]");
  await page.evaluate(() => { window.__db.pagamentos.filter(p => p.tipo === "pagamento").forEach(p => { if (!window.__db.envios.some(e => e.pagamento_id === p.id)) window.__db.envios.push({ pagamento_id: p.id, confirmado_em: new Date().toISOString() }); }); });
  await page.click("#tab-financeiro"); await page.waitForSelector(".kpi");
  const dl = page.waitForEvent("download"); await page.click("[data-a=finCsv]"); const d = await dl;
  const csv = fs.readFileSync(await d.path(), "utf8");
  check("CSV com BOM, ; e colunas de valor original, pago e saldo", csv.startsWith("﻿") && csv.includes(";") && /Valor original;"?/.test(csv.replace(/"/g, "")) && csv.includes("Saldo") && csv.includes("300,5"));

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
  await page.click("#tab-financeiro"); await page.click("[data-a=finForm]"); await page.fill("#lDesc", "Conta op"); await page.fill("#lValor", "10"); await page.fill("#lVenc", "2030-01-01"); await page.click("[data-a=finSalvar]");
  await page.waitForSelector(".list-row:has-text('Conta op')"); await page.click(".list-row:has-text('Conta op')"); await page.click("[data-a=finPagForm]"); await page.fill("#pgValor", "4"); await page.click("[data-a=finPagSalvar]"); await page.waitForSelector(".tag.parcial");
  check("operador registra pagamento, mas não vê Estornar nem Cancelar conta", await page.locator("[data-a=finEstornarForm]").count() === 0 && await page.locator("[data-a=finCancelarForm]").count() === 0);
  const acesso = await page.evaluate(async () => { const c = window.supabase.createClient(); const r = await c.rpc("conta_detalhe", { p_id: "conta-inexistente" }); const dl = await c.storage.from("comprovantes").createSignedUrl("loja-2/x/y.pdf", 60); return [r.error && r.error.message, dl.error && dl.error.message]; });
  check("acesso indevido a conta/anexo de outra loja é negado", /não encontrada|permissão/i.test(acesso[0] || "") && /not found/i.test(acesso[1] || ""), JSON.stringify(acesso));

  check("nenhum erro de JavaScript em toda a sessão", erros.length === 0, erros.join(" | "));
  await browser.close();
  console.log(`\nTESTES DE TELA: ${pass} ok, ${fail} falhas`);
  falhas.forEach(f => console.log("  ✗ " + f));
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error("ERRO NO TESTE:", e); process.exit(2); });

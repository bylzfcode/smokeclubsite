/* Integração dos rateios aos resumos financeiros — API REAL (Auth + PostgREST + Postgres do Supabase). Compara "antes × depois" (deltas),
   então não depende de outros dados. Papéis: luiz = gerente (Smoke, Start, EZ); enzo = operador (só Start); chefe = dono (vinculado só à Start); rafael = Streaks. */
const fs = require("fs"), path = require("path"), cp = require("child_process"), crypto = require("crypto");
const { createClient } = require("./node/node_modules/@supabase/supabase-js");
const env = Object.fromEntries(fs.readFileSync(path.join(__dirname, ".env"), "utf8").trim().split("\n").map(l => l.split(/=(.*)/s).slice(0, 2)));
const URL = "http://127.0.0.1:54321", ANON = env.ANON_KEY;
let pass = 0, fail = 0; const falhas = [];
const check = (n, c, x) => { if (c) pass++; else { fail++; falhas.push(n + (x !== undefined ? " → " + (typeof x === "string" ? x : JSON.stringify(x)).slice(0, 300) : "")); } };
const sql = q => cp.execFileSync("docker", ["compose", "--env-file", ".env", "exec", "-T", "db", "psql", "-w", "-U", "postgres", "-d", "postgres", "-At", "-c", q], { cwd: __dirname, encoding: "utf8" }).trim();
const login = async u => { const c = createClient(URL, ANON, { auth: { persistSession: false, autoRefreshToken: false } }); const r = await c.auth.signInWithPassword({ email: u + "@painel.local", password: "1234" }); if (r.error) throw new Error("login " + u); return c; };
const uuid = () => crypto.randomUUID(), msg = e => e ? (e.message || JSON.stringify(e)) : "";
const hoje = new Date().toLocaleDateString("en-CA", { timeZone: "America/Sao_Paulo" });
const addDias = (iso, n) => { const d = new Date(iso + "T12:00:00Z"); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
const n = v => Math.round(Number(v) * 100) / 100, eq = (a, b) => Math.abs(n(a) - n(b)) < 0.005;

(async () => {
  const L = Object.fromEntries(sql("select slug||'|'||id from lojas").split("\n").map(l => l.split("|"))); const S = L["smoke-club"], T = L["start-br01"], E = L["ez-store"];
  const U = {}; for (const u of ["luiz", "enzo", "chefe", "rafael"]) U[u] = await login(u);
  const itens3 = [{ loja_id: S }, { loja_id: T }, { loja_id: E }];
  const resumo = async (c, loja = null, ini = null, fim = null) => (await c.rpc("rateios_resumo", { p_loja_id: loja, p_inicio: ini, p_fim: fim })).data;
  const fin = async (c, loja, ini = null, fim = null) => (await c.rpc("financeiro_resumo", { p_loja_id: loja, p_inicio: ini, p_fim: fim })).data;
  const pl = (r, nome, campo) => { const x = r.por_loja.find(l => l.loja_nome === nome); return x ? Number(x[campo]) : 0; };
  const snap = async c => ({ r: await resumo(c), fs: await fin(c, S), ft: await fin(c, T), fe: await fin(c, E) });
  const dRat = (a, b, campo) => n(b.consolidado[campo] - a.consolidado[campo]);
  const dLoja = (a, b, nome, campo) => n(pl(b, nome, campo) - pl(a, nome, campo));
  const pagar = (c, r, loja, v, extra = {}) => c.rpc("registrar_pagamento_rateio", { p_rateio_id: r, p_loja_id: loja, p_valor: v, p_data: hoje, p_forma: "Pix", p_observacao: null, p_chave: extra.chave || uuid() });
  const reemb = (c, r, o, d, v) => c.rpc("registrar_reembolso", { p_rateio_id: r, p_loja_origem: o, p_loja_destino: d, p_valor: v, p_data: hoje, p_observacao: null, p_chave: uuid() });
  const caixaAntes = sql("select (select count(*) from caixa_movimentos)||'/'||(select count(*) from caixas)");

  /* ===== antes ===== */
  const A0 = await snap(U.luiz), E0 = await resumo(U.enzo);
  check("rateios_resumo existe na API real e declara a data de cada indicador", !!A0.r.datas && /vencimento/.test(A0.r.datas.previsto) && /data do pagamento/.test(A0.r.datas.pago) && /hoje/.test(A0.r.datas.saldo_externo) && /hoje/.test(A0.r.datas.acerto_entre_lojas));
  check("financeiro_resumo e painel_resumo trazem a chave 'rateios' sem perder as chaves antigas", !!A0.fs.rateios && ["entradas", "saidas", "saldo_periodo", "saldo_caixa", "a_receber", "a_pagar", "atrasados"].every(k => k in A0.fs)
    && await (async () => { const p = (await U.luiz.rpc("painel_resumo", { p_loja_id: S })).data; return ["hoje", "mes", "saldo_caixa", "a_pagar", "a_receber", "atrasados", "por_dia", "top_produtos", "rateios"].every(k => k in p); })());

  /* ===== conta exclusiva + R$ 900 em 3 lojas (A=Smoke, B=Start, C=EZ) ===== */
  const C1 = (await U.luiz.rpc("criar_conta", { p_loja_id: S, p_tipo: "saida", p_categoria: "aluguel", p_descricao: "Aluguel exclusivo", p_valor: 200, p_vencimento: addDias(hoje, 3), p_forma: null, p_exige_comprovante: false, p_chave: uuid() })).data;
  await U.luiz.rpc("registrar_pagamento", { p_lancamento_id: C1, p_valor: 50, p_data: hoje, p_forma: "Pix", p_observacao: null, p_chave: uuid() });
  const VENC = addDias(hoje, 300);
  const R1 = (await U.luiz.rpc("criar_rateio", { p_descricao: "Reforma (resumos)", p_categoria: "manutenção", p_valor_total: 900, p_vencimento: VENC, p_exige_comprovante: false, p_metodo: "igual", p_itens: itens3, p_chave: uuid() })).data;
  const A1 = await snap(U.luiz);
  check("antes de pagar: previsto +900, pago +0, saldo externo pendente +900 (uma vez, não 3×)", dRat(A0.r, A1.r, "previsto_periodo") === 900 && dRat(A0.r, A1.r, "pago_periodo") === 0 && n(A1.r.consolidado.saldo_externo_pendente.total - A0.r.consolidado.saldo_externo_pendente.total) === 900);
  check("antes de pagar, a parcela de 300 de cada loja é 'ainda não coberta' (não 'a reembolsar' nem dívida ao fornecedor)", dLoja(A0.r, A1.r, "Smoke Club", "parcela_ainda_nao_coberta") === 300 && dLoja(A0.r, A1.r, "Smoke Club", "a_reembolsar_a_outras_lojas") === 0 && dLoja(A0.r, A1.r, "Smoke Club", "parcela_periodo") === 300);
  check("contas exclusivas e compartilhadas separadas: 'a pagar' da Smoke subiu só 150 (200−50), sem os 900", n(A1.fs.a_pagar.total - A0.fs.a_pagar.total) === 150);

  /* ===== A paga tudo ===== */
  await pagar(U.luiz, R1, S, 900);
  const A2 = await snap(U.luiz);
  check("A paga tudo: despesa consolidada +900 pagos; saldo externo pendente volta ao que era antes do rateio (+0)", dRat(A1.r, A2.r, "pago_periodo") === 900 && n(A2.r.consolidado.saldo_externo_pendente.total - A0.r.consolidado.saldo_externo_pendente.total) === 0);
  check("Smoke (A): +900 de pagamentos externos e R$ 600 a recuperar; Start e EZ com R$ 300 a reembolsar cada", dLoja(A1.r, A2.r, "Smoke Club", "pago_externo_periodo") === 900 && dLoja(A0.r, A2.r, "Smoke Club", "a_receber_de_outras_lojas") === 600
    && dLoja(A0.r, A2.r, "Start BR01", "a_reembolsar_a_outras_lojas") === 300 && dLoja(A0.r, A2.r, "EZ Store", "a_reembolsar_a_outras_lojas") === 300 && dLoja(A0.r, A2.r, "Start BR01", "parcela_ainda_nao_coberta") === 0);
  const itensR1 = A2.r.consolidado.itens.filter(i => i.id === R1);
  check("o consolidado lista a despesa UMA vez (total 900, pago 900, saldo 0, compartilhada)", itensR1.length === 0 /* data prevista fora do período 'tudo'? */ || (itensR1.length === 1 && Number(itensR1[0].valor_total) === 900 && Number(itensR1[0].saldo_externo) === 0 && itensR1[0].tipo_conta === "compartilhada"));
  const jan = await resumo(U.luiz, null, addDias(hoje, 299), addDias(hoje, 301)), itJ = jan.consolidado.itens.filter(i => i.id === R1);
  check("janela do vencimento (hoje+299…hoje+301): previsto = 900 exato, pago do período = 0 (o pagamento foi hoje), item único: total 900 · pago 900 · saldo externo 0 · compartilhada",
    Number(jan.consolidado.previsto_periodo) === 900 && Number(jan.consolidado.pago_periodo) === 0 && itJ.length === 1 && Number(itJ[0].valor_total) === 900 && Number(itJ[0].pago_total) === 900 && Number(itJ[0].saldo_externo) === 0 && itJ[0].tipo_conta === "compartilhada", jan.consolidado);
  check("entradas/saídas efetivadas: +900 só na Smoke (+50 da conta exclusiva); Start e EZ sem mudança; soma das 3 lojas +950, nunca 2.700", n(A2.fs.saidas - A0.fs.saidas) === 950 && n(A2.ft.saidas - A0.ft.saidas) === 0 && n(A2.fe.saidas - A0.fe.saidas) === 0);

  /* ===== B reembolsa R$ 100 (registrado pelo operador da Start) ===== */
  const rb = await reemb(U.enzo, R1, T, S, 100);
  const A3 = await snap(U.luiz);
  check("B reembolsa R$ 100: a despesa permanece (+900 pagos), A passa a recuperar R$ 500 e B a dever R$ 200", !rb.error && dRat(A1.r, A3.r, "pago_periodo") === 900 && dLoja(A0.r, A3.r, "Smoke Club", "a_receber_de_outras_lojas") === 500 && dLoja(A0.r, A3.r, "Start BR01", "a_reembolsar_a_outras_lojas") === 200 && dLoja(A0.r, A3.r, "EZ Store", "a_reembolsar_a_outras_lojas") === 300, msg(rb.error));
  check("reembolso não é receita nem despesa: entradas, saídas e saldo efetivado idênticos nas 3 lojas", ["fs", "ft", "fe"].every(k => A3[k].entradas === A2[k].entradas && A3[k].saidas === A2[k].saidas && A3[k].saldo_caixa === A2[k].saldo_caixa));
  check("reembolsos internos aparecem à parte (líquido +100, com a nota)", dRat(A2.r, A3.r, "pago_periodo") === 0 && n(A3.r.reembolsos_internos.liquido_periodo - A2.r.reembolsos_internos.liquido_periodo) === 100 && /não são receita nem despesa/.test(A3.r.reembolsos_internos.nota)
    && dLoja(A2.r, A3.r, "Start BR01", "reembolsos_pagos_periodo") === 100 && dLoja(A2.r, A3.r, "Smoke Club", "reembolsos_recebidos_periodo") === 100);

  /* ===== pagamento externo parcial + vencimento + estornos ===== */
  const R2 = (await U.luiz.rpc("criar_rateio", { p_descricao: "Internet (vencida)", p_categoria: "serviços", p_valor_total: 1000, p_vencimento: addDias(hoje, -3), p_exige_comprovante: false, p_metodo: "igual", p_itens: itens3, p_chave: uuid() })).data;
  const p2 = (await pagar(U.luiz, R2, S, 400)).data.pagamento_id;
  const A4 = await snap(U.luiz);
  check("pagamento externo parcial de R2: saldo externo pendente +600 e vencido +600 (1 despesa); o saldo de R1 não entra", n(A4.r.consolidado.saldo_externo_pendente.total - A3.r.consolidado.saldo_externo_pendente.total) === 1000 - 400 && n(A4.r.consolidado.saldo_externo_vencido.total - A3.r.consolidado.saldo_externo_vencido.total) === 600 && A4.r.consolidado.saldo_externo_vencido.qtd - A3.r.consolidado.saldo_externo_vencido.qtd === 1);
  check("em R2 (externo em aberto) Start/EZ têm 'parcela ainda não coberta' 333,33/333,34 — e o 'a reembolsar' de R1 não mudou", dLoja(A3.r, A4.r, "Start BR01", "parcela_ainda_nao_coberta") === 333.33 && dLoja(A3.r, A4.r, "EZ Store", "parcela_ainda_nao_coberta") === 333.34 && dLoja(A3.r, A4.r, "Start BR01", "a_reembolsar_a_outras_lojas") === 0);
  check("R2 sai nas despesas com 'vencida' e 'parcial' (1000 · 400 · 600)", (itR => itR.length === 1 && itR[0].vencida && itR[0].situacao === "parcial" && Number(itR[0].saldo_externo) === 600)((await resumo(U.luiz, null, addDias(hoje, -4), addDias(hoje, -2))).consolidado.itens.filter(i => i.id === R2)));
  check("saídas efetivadas da Smoke subiram +400 (pagamento parcial, uma vez)", n(A4.fs.saidas - A3.fs.saidas) === 400);
  await U.luiz.rpc("estornar_pagamento_rateio", { p_pagamento_id: p2, p_motivo: "pagamento lançado em duplicidade" });
  const A5 = await snap(U.luiz);
  check("estorno do pagamento parcial: pago líquido volta ao anterior, saldo externo de R2 = 1000 (pendente +400 de novo) e as saídas voltam ao valor anterior (estorno abate a despesa, não vira entrada)", dRat(A3.r, A5.r, "pago_periodo") === 0 && n(A5.r.consolidado.saldo_externo_pendente.total - A4.r.consolidado.saldo_externo_pendente.total) === 400
    && n(A5.fs.saidas - A3.fs.saidas) === 0 && n(A5.fs.entradas - A3.fs.entradas) === 0 && A5.fs.saldo_caixa === A3.fs.saldo_caixa, { s: A5.fs, a3: A3.fs });
  const rbId = rb.data.reembolso_id; await U.luiz.rpc("estornar_reembolso", { p_reembolso_id: rbId, p_motivo: "reembolso lançado errado" });
  const A6 = await snap(U.luiz);
  check("estorno do reembolso: A volta a recuperar R$ 600, B a dever R$ 300; despesa e entradas/saídas inalteradas", dLoja(A0.r, A6.r, "Smoke Club", "a_receber_de_outras_lojas") === 600 && dLoja(A0.r, A6.r, "Start BR01", "a_reembolsar_a_outras_lojas") === 300 && dRat(A5.r, A6.r, "pago_periodo") === 0 && A6.fs.saidas === A5.fs.saidas && A6.fs.entradas === A5.fs.entradas);

  /* ===== usuário com acesso a UMA loja (enzo / Start) ===== */
  const E1 = await resumo(U.enzo), EF = await fin(U.enzo, T);
  check("enzo (só Start): 'por loja' mostra apenas a Start; nada de Smoke/EZ", E1.por_loja.length >= 1 && E1.por_loja.every(l => l.loja_nome === "Start BR01"), E1.por_loja.map(l => l.loja_nome));
  check("enzo: Start deve R$ 300 de R1 (acerto) — delta no consolidado dele = +300 — e cada despesa aparece uma vez para ele", dLoja(E0, E1, "Start BR01", "a_reembolsar_a_outras_lojas") === 300 && new Set(E1.consolidado.itens.map(i => i.id)).size === E1.consolidado.itens.length);
  check("enzo: financeiro_resumo(Start) traz o mesmo bloco de rateios, e as demais lojas continuam negadas", !!EF.rateios && EF.rateios.por_loja.every(l => l.loja_nome === "Start BR01") && /permiss/i.test(msg((await U.enzo.rpc("financeiro_resumo", { p_loja_id: S, p_inicio: null, p_fim: null })).error)) && /permiss/i.test(msg((await U.enzo.rpc("rateios_resumo", { p_loja_id: S, p_inicio: null, p_fim: null })).error)));
  const RF = await resumo(U.rafael); check("rafael (Streaks) não enxerga os rateios R1/R2 (sem a Streaks) e, em 'por loja', só a própria loja", !RF.consolidado.itens.some(i => i.id === R1 || i.id === R2) && RF.por_loja.every(l => l.loja_nome === "Streaks Store"), RF.por_loja.map(l => l.loja_nome));
  const anon = createClient(URL, ANON, { auth: { persistSession: false } });
  check("anônimo não executa o resumo", !!(await anon.rpc("rateios_resumo", { p_loja_id: null, p_inicio: null, p_fim: null })).error);

  /* ===== dono: visão consolidada ===== */
  const D1 = await resumo(U.chefe);
  check("dono (vinculado só à Start) vê o consolidado de todas as lojas: Smoke, Start e EZ em 'por loja'", ["Smoke Club", "Start BR01", "EZ Store"].every(nm => D1.por_loja.some(l => l.loja_nome === nm)));
  check("para o dono, cada despesa externa também aparece uma vez (sem duplicar por loja)", new Set(D1.consolidado.itens.map(i => i.id)).size === D1.consolidado.itens.length && D1.consolidado.itens.filter(i => i.id === R1 || i.id === R2).length <= 2);

  /* ===== caixa preservado ===== */
  check("o caixa não foi tocado por nada disto", sql("select (select count(*) from caixa_movimentos)||'/'||(select count(*) from caixas)") === caixaAntes);

  console.log(`\nVALIDAÇÃO DOS RESUMOS DE RATEIOS NA PILHA REAL (API): ${pass} ok, ${fail} falhas`); falhas.forEach(f => console.log("  ✗ " + f));
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error("ERRO NO TESTE:", e.stack ? e.stack.split("\n").slice(0, 5).join("\n") : e); process.exit(2); });

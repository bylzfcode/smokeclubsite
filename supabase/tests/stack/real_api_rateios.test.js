/* Rateios e reembolsos entre lojas contra a PILHA REAL (Auth + PostgREST + Storage reais). Sem simulação.
   Rodado por ./run_all.sh depois de real_api.test.js. Papéis na pilha: luiz/victor/rafael = gerente; enzo/vinicius/carla = operador; chefe = dono (vinculado só à Start). */
const fs = require("fs"), path = require("path"), cp = require("child_process"), crypto = require("crypto");
const { createClient } = require("./node/node_modules/@supabase/supabase-js");
const env = Object.fromEntries(fs.readFileSync(path.join(__dirname, ".env"), "utf8").trim().split("\n").map(l => l.split(/=(.*)/s).slice(0, 2)));
const URL = "http://127.0.0.1:54321", ANON = env.ANON_KEY, SERVICE = env.SERVICE_KEY, BUCKET = "comprovantes";
let pass = 0, fail = 0; const falhas = [];
const check = (n, c, x) => { if (c) pass++; else { fail++; falhas.push(n + (x !== undefined ? " → " + (typeof x === "string" ? x : JSON.stringify(x)).slice(0, 300) : "")); } };
const dc = (args, e = {}) => cp.execFileSync("docker", ["compose", "--env-file", ".env", "exec", "-T", ...Object.entries(e).flatMap(([k, v]) => ["-e", `${k}=${v}`]), "db", ...args], { cwd: __dirname, encoding: "utf8" });
const sql = q => dc(["psql", "-w", "-U", "postgres", "-d", "postgres", "-At", "-c", q]).trim();
const sqlAdmin = q => dc(["psql", "-w", "-h", "localhost", "-U", "supabase_admin", "-d", "postgres", "-At", "-c", q], { PGPASSWORD: env.POSTGRES_PASSWORD }).trim();
const mk = (key = ANON) => createClient(URL, key, { auth: { persistSession: false, autoRefreshToken: false } });
const login = async u => { const c = mk(); const r = await c.auth.signInWithPassword({ email: u + "@painel.local", password: "1234" }); if (r.error) throw new Error("login " + u + ": " + r.error.message); return c; };
const uuid = () => crypto.randomUUID(), msg = e => e ? (e.message || JSON.stringify(e)) : "";
const hoje = new Date().toLocaleDateString("en-CA", { timeZone: "America/Sao_Paulo" });
const pdf = n => Buffer.concat([Buffer.from("%PDF-1.4\n"), crypto.randomBytes(Math.max(0, n - 9))]);
const up = (c, p, buf, type) => c.storage.from(BUCKET).upload(p, buf, { contentType: type, upsert: false });

(async () => {
  const L = Object.fromEntries(sql("select slug||'|'||id from lojas").split("\n").map(l => l.split("|")));
  const S = L["smoke-club"], T = L["start-br01"], E = L["ez-store"], ST = L["streaks-store"];
  const U = {}; for (const u of ["luiz", "victor", "enzo", "rafael", "carla", "chefe"]) U[u] = await login(u);
  const anon = mk(), svc = mk(SERVICE);
  const itens3 = [{ loja_id: S }, { loja_id: T }, { loja_id: E }];
  const criar = (c, desc, total, metodo, itens, extra = {}) => c.rpc("criar_rateio", { p_descricao: desc, p_categoria: "manutenção", p_valor_total: total, p_vencimento: extra.venc ?? null, p_exige_comprovante: !!extra.comp, p_metodo: metodo, p_itens: itens, p_chave: extra.chave || uuid() });
  const pagar = (c, r, loja, v, extra = {}) => c.rpc("registrar_pagamento_rateio", { p_rateio_id: r, p_loja_id: loja, p_valor: v, p_data: hoje, p_forma: "Pix", p_observacao: extra.obs ?? null, p_chave: extra.chave || uuid() });
  const reemb = (c, r, o, d, v, extra = {}) => c.rpc("registrar_reembolso", { p_rateio_id: r, p_loja_origem: o, p_loja_destino: d, p_valor: v, p_data: hoje, p_observacao: extra.obs ?? null, p_chave: extra.chave || uuid() });
  const det = async (c, r) => (await c.rpc("rateio_detalhe", { p_id: r })).data;
  const pos = (d, nome) => Number(d.posicoes.find(p => p.loja_nome === nome).posicao);

  /* ===== EXEMPLO OBRIGATÓRIO: R$ 900 entre A=Smoke, B=Start, C=EZ ===== */
  const prev = await U.luiz.rpc("rateio_previa", { p_valor_total: 900, p_metodo: "igual", p_itens: itens3 });
  check("prévia pela API real: 300 + 300 + 300 = 900", !prev.error && prev.data.parcelas.every(p => Number(p.valor) === 300) && Number(prev.data.soma) === 900, msg(prev.error));
  const R1 = (await criar(U.luiz, "Reforma da fachada", 900, "igual", itens3)).data;
  check("rateio criado (3 parcelas de 300 no banco)", !!R1 && sql(`select count(*) from rateio_parcelas where rateio_id='${R1}' and valor=300`) === "3");
  const k = uuid(); const pA = await pagar(U.luiz, R1, S, 900, { chave: k });
  const pA2 = await pagar(U.luiz, R1, S, 900, { chave: k });
  let d = await det(U.luiz, R1);
  check("A (Smoke) paga tudo: saldo externo 0; A tem R$ 600 a recuperar; B e C devem R$ 300", !pA.error && Number(d.rateio.saldo_externo) === 0 && pos(d, "Smoke Club") === 600 && pos(d, "Start BR01") === -300 && pos(d, "EZ Store") === -300, d.posicoes);
  check("a mesma requisição repetida não registra o pagamento de novo", pA2.data.repetida === true && sql(`select count(*) from rateio_pagamentos where rateio_id='${R1}'`) === "1");
  check("não há pagamento externo acima do saldo (quitada)", /já está quitada/.test(msg((await pagar(U.luiz, R1, T, 0.01)).error)));
  const rb = await reemb(U.enzo, R1, T, S, 100, { obs: "devolução parcial" });     // enzo = OPERADOR da Start: pode registrar o reembolso da própria loja
  d = await det(U.luiz, R1);
  check("B reembolsa R$ 100 (registrado por operador da Start): B deve R$ 200; C deve R$ 300; A recupera R$ 500", !rb.error && pos(d, "Start BR01") === -200 && pos(d, "EZ Store") === -300 && pos(d, "Smoke Club") === 500, rb.error || d.posicoes);
  check("despesa consolidada permanece R$ 900; reembolso não quita de novo nem altera o total externo", Number(d.rateio.despesa_consolidada) === 900 && Number(d.rateio.pago_externo) === 900 && Number(d.rateio.saldo_externo) === 0);
  check("no consolidado (fluxo) há UM pagamento de −900; o reembolso não gera receita nem despesa", sql(`select coalesce(sum(efeito),0)||'/'||count(*) from fluxo_pago_itens() where lancamento_id='${R1}'`) === "-900.00/1");
  check("não movimentou o caixa automaticamente", sql("select count(*) from caixa_movimentos") === "0");
  check("reembolso acima do saldo devido (B deve 200; 200,01) é recusado", /saldo devido pela loja de origem/.test(msg((await reemb(U.enzo, R1, T, S, 200.01)).error)));
  check("destino sem valor a recuperar (B→C) é recusado", /valor a recuperar da loja de destino/.test(msg((await reemb(U.enzo, R1, T, E, 10)).error)));

  /* ===== ARREDONDAMENTO R$ 100 / 3 (parcelas reais gravadas) ===== */
  const R100 = (await criar(U.luiz, "Divisão de 100", 100, "igual", itens3)).data;
  const parc = sql(`select string_agg(l.nome||'='||p.valor, ' | ' order by l.nome) from rateio_parcelas p join lojas l on l.id=p.loja_id where p.rateio_id='${R100}'`);
  check("R$ 100 entre 3 lojas: 33,34 (1ª por nome) + 33,33 + 33,33 = 100,00", parc === "EZ Store=33.34 | Smoke Club=33.33 | Start BR01=33.33" && sql(`select sum(valor) from rateio_parcelas where rateio_id='${R100}'`) === "100.00", parc);
  const pv = await U.luiz.rpc("rateio_previa", { p_valor_total: 100, p_metodo: "percentual", p_itens: [{ loja_id: S, percentual: 33.3333 }, { loja_id: T, percentual: 33.3333 }, { loja_id: E, percentual: 33.3334 }] });
  check("percentual 33,3333/33,3333/33,3334 de 100 fecha em 100,00", !pv.error && Number(pv.data.soma) === 100);
  check("valores que não fecham o total e percentuais ≠ 100 são recusados pela API", /difere do total/.test(msg((await U.luiz.rpc("rateio_previa", { p_valor_total: 900, p_metodo: "valores", p_itens: [{ loja_id: S, valor: 500 }, { loja_id: T, valor: 399.99 }] })).error))
    && /exatamente 100/.test(msg((await U.luiz.rpc("rateio_previa", { p_valor_total: 900, p_metodo: "percentual", p_itens: [{ loja_id: S, percentual: 60 }, { loja_id: T, percentual: 39.99 }] })).error)));

  /* ===== PAGAMENTOS EXTERNOS PARCIAIS, POR USUÁRIOS DIFERENTES ===== */
  const R2 = (await criar(U.luiz, "Internet das 3 lojas", 1000, "igual", itens3)).data;
  const p1 = await pagar(U.victor, R2, S, 100, { obs: "Smoke paga sua parte parcial" });
  const p2 = await pagar(U.enzo, R2, T, 250);
  check("pagamentos parciais por vários usuários (victor→Smoke, enzo→Start): saldo externo 650", !p1.error && !p2.error && Number(p2.data.saldo_externo) === 650, msg(p1.error) + msg(p2.error));
  check("enzo (só Start) não paga em nome do EZ nem da Smoke", /permiss/i.test(msg((await pagar(U.enzo, R2, E, 10)).error)) && /permiss/i.test(msg((await pagar(U.enzo, R2, S, 10)).error)));
  check("loja que não participa (Streaks) não paga: rafael recebe erro", /permiss|não participa/i.test(msg((await pagar(U.rafael, R2, ST, 10)).error)));
  check("pagamento acima do saldo externo (650,01) recusado", /maior que o saldo externo/.test(msg((await pagar(U.luiz, R2, E, 650.01)).error)));
  const rs = await Promise.all(Array.from({ length: 10 }, () => pagar(U.luiz, R2, E, 325)));
  check("10 pagamentos simultâneos (HTTP real) de R$ 325 com saldo de R$ 650: só 2 passam, total externo = 1000", rs.filter(r => !r.error).length === 2 && sql(`select sum(case tipo when 'pagamento' then valor else -valor end) from rateio_pagamentos where rateio_id='${R2}'`) === "1000.00", rs.map(r => msg(r.error)).join("|"));
  const kk = uuid(), r8 = await Promise.all(Array.from({ length: 8 }, () => reemb(U.luiz, R2, T, E, 10, { chave: kk })));
  check("8 reembolsos idênticos simultâneos (mesma chave): 1 registro, todas as respostas sem erro", r8.every(r => !r.error) && sql(`select count(*) from rateio_reembolsos where rateio_id='${R2}' and chave='${kk}'`) === "1", r8.map(r => msg(r.error)).join("|"));

  /* ===== REEMBOLSOS: concorrência e limites ===== */
  const R3 = (await criar(U.luiz, "Concorrência de reembolsos", 900, "igual", itens3)).data;
  await pagar(U.luiz, R3, S, 900);
  const rr = await Promise.all(Array.from({ length: 10 }, () => reemb(U.luiz, R3, T, S, 100)));
  d = await det(U.luiz, R3);
  check("10 reembolsos simultâneos de R$ 100 de quem deve R$ 300: só 3 passam e a posição de B é exatamente 0", rr.filter(r => !r.error).length === 3 && pos(d, "Start BR01") === 0 && pos(d, "Smoke Club") === 300, rr.map(r => msg(r.error)).join("|"));
  check("o total pago ao externo segue R$ 900 e o consolidado segue −900", Number(d.rateio.pago_externo) === 900 && sql(`select sum(efeito) from fluxo_pago_itens() where lancamento_id='${R3}'`) === "-900.00");

  /* ===== ESTORNOS APÓS REEMBOLSO ===== */
  const idsPag = sql(`select id from rateio_pagamentos where rateio_id='${R1}' and tipo='pagamento'`);
  check("estorno do pagamento externo recusado enquanto houver reembolso que depende dele", /reembolsos registrados dependem/.test(msg((await U.luiz.rpc("estornar_pagamento_rateio", { p_pagamento_id: idsPag, p_motivo: "pagamento lançado errado" })).error)));
  const rbId = rb.data.reembolso_id;
  check("operador da Start (enzo) não estorna; rafael também não", /gerente/.test(msg((await U.enzo.rpc("estornar_reembolso", { p_reembolso_id: rbId, p_motivo: "motivo qualquer" })).error)) && /gerente/.test(msg((await U.rafael.rpc("estornar_reembolso", { p_reembolso_id: rbId, p_motivo: "motivo qualquer" })).error)));
  const ests = await Promise.all(Array.from({ length: 6 }, (_, i) => U.luiz.rpc("estornar_reembolso", { p_reembolso_id: rbId, p_motivo: "estorno simultâneo " + i })));
  check("6 estornos simultâneos do mesmo reembolso: 1 aceito, original preservado", ests.filter(r => !r.error).length === 1 && sql(`select count(*) from rateio_reembolsos where rateio_id='${R1}'`) === "2" && sql(`select count(*) from rateio_reembolsos where id='${rbId}' and tipo='reembolso' and valor=100`) === "1");
  d = await det(U.luiz, R1);
  check("após estornar o reembolso: B volta a dever 300 e A a recuperar 600", pos(d, "Start BR01") === -300 && pos(d, "Smoke Club") === 600);
  const e2 = await U.luiz.rpc("estornar_pagamento_rateio", { p_pagamento_id: idsPag, p_motivo: "pagamento externo lançado errado" });
  d = await det(U.luiz, R1);
  check("agora o estorno do pagamento externo é aceito: despesa consolidada volta a 0, saldo externo 900", !e2.error && Number(d.rateio.despesa_consolidada) === 0 && Number(d.rateio.saldo_externo) === 900, msg(e2.error));
  check("estornar de novo / estorno de estorno recusados", /já foi estornado/.test(msg((await U.luiz.rpc("estornar_pagamento_rateio", { p_pagamento_id: idsPag, p_motivo: "de novo por engano" })).error)));
  check("auditoria completa (criação, pagamento, reembolso, estornos) com motivo e responsável", sql(`select count(*) from rateio_auditoria where rateio_id='${R1}'`) === "5" && sql(`select count(*) from rateio_auditoria where rateio_id='${R1}' and acao='estorno_pagamento' and motivo='pagamento externo lançado errado'`) === "1");

  /* ===== ACESSOS ===== */
  check("gerente (victor: Smoke+EZ) NÃO cria rateio com a Start; cria entre as suas", /administra/.test(msg((await criar(U.victor, "Invasão", 100, "igual", itens3)).error)) && !(await criar(U.victor, "Só minhas", 100, "igual", [{ loja_id: S }, { loja_id: E }])).error);
  check("operadores (enzo, carla) e anônimo não criam rateio", /gerente ou dono/.test(msg((await criar(U.enzo, "x1", 100, "igual", [{ loja_id: T }, { loja_id: E }])).error)) && /gerente ou dono/.test(msg((await criar(U.carla, "x2", 100, "igual", [{ loja_id: S }, { loja_id: E }])).error)) && !!(await criar(anon, "x3", 100, "igual", itens3)).error);
  const RD = (await criar(U.chefe, "Contador (dono)", 600, "igual", [...itens3, { loja_id: ST }])).data;
  check("dono (vinculado só à Start) administra todas as lojas: cria rateio com as 4", !!RD && sql(`select count(*) from rateio_parcelas where rateio_id='${RD}'`) === "4");
  const lEnzo = (await U.enzo.rpc("listar_rateios", { p_loja_id: null, p_situacao: null })).data, idsEnzo = lEnzo.map(x => x.id);
  check("enzo (Start) vê só rateios em que a Start participa, e nas parcelas só a posição da própria loja", idsEnzo.includes(R1) && !idsEnzo.some(id => sql(`select count(*) from rateio_parcelas where rateio_id='${id}' and loja_id='${T}'`) === "0") && lEnzo.every(x => x.minhas.length === 1 && x.minhas[0].loja_nome === "Start BR01"));
  const dEnzo = await det(U.enzo, R1);
  check("enzo, no detalhe, vê todas as parcelas/pagamentos/reembolsos DESTE rateio (para conferir) e só pode pagar pela Start", dEnzo.posicoes.length === 3 && dEnzo.pode_pagar_lojas.length === 1 && dEnzo.pode_pagar_lojas[0].loja_nome === "Start BR01");
  check("…mas não ganha acesso ao financeiro completo das outras lojas", !!(await U.enzo.rpc("listar_contas", { p_loja_id: S, p_inicio: null, p_fim: null, p_situacao: null })).error && !!(await U.enzo.rpc("painel_resumo", { p_loja_id: S })).error && !!(await U.enzo.from("rateio_pagamentos").select("*")).error);
  const R_SE = (await criar(U.victor, "Exclusivo Smoke+EZ", 200, "igual", [{ loja_id: S }, { loja_id: E }])).data;
  check("rateio sem a Start não aparece nem abre para enzo", !idsEnzo.includes(R_SE) && /sem permissão/.test(msg((await U.enzo.rpc("rateio_detalhe", { p_id: R_SE })).error)));
  check("rafael (Streaks) não vê nada além do que participa (nada); dono vê tudo", (await U.rafael.rpc("listar_rateios", { p_loja_id: null, p_situacao: null })).data.every(x => x.id === RD) && (await U.chefe.rpc("listar_rateios", { p_loja_id: null, p_situacao: null })).data.length >= 6);
  check("anônimo: funções e tabelas negadas", !!(await anon.rpc("listar_rateios", { p_loja_id: null, p_situacao: null })).error && !!(await anon.from("rateios").select("*")).error);

  /* ===== REVISÃO / CANCELAMENTO ===== */
  const Rrev = (await criar(U.luiz, "Para revisar", 600, "igual", itens3)).data;
  const v2 = await U.luiz.rpc("revisar_rateio", { p_id: Rrev, p_descricao: "Para revisar (v2)", p_valor_total: 600, p_vencimento: null, p_metodo: "valores", p_itens: [{ loja_id: S, valor: 400 }, { loja_id: T, valor: 200 }], p_motivo: "divisão combinada" });
  check("revisão sem movimento cria a versão 2 e preserva as 3 parcelas antigas inativas", v2.data === 2 && sql(`select count(*) from rateio_parcelas where rateio_id='${Rrev}' and versao=1 and not ativa`) === "3" && sql(`select sum(valor) from rateio_parcelas where rateio_id='${Rrev}' and versao=2 and ativa`) === "600.00");
  check("rateio com movimentação não é revisado nem cancelado (R2 tem pagamentos)", /já tem movimentações/.test(msg((await U.luiz.rpc("revisar_rateio", { p_id: R2, p_descricao: "x", p_valor_total: 1000, p_vencimento: null, p_metodo: "igual", p_itens: itens3, p_motivo: "tentativa com movimento" })).error))
    && /já tem movimentações/.test(msg((await U.luiz.rpc("cancelar_rateio", { p_id: R2, p_motivo: "tentativa com movimento" })).error)));
  check("R1 (tudo estornado) já pode ser cancelado; histórico preservado", !(await U.luiz.rpc("cancelar_rateio", { p_id: R1, p_motivo: "despesa lançada por engano" })).error && sql(`select count(*) from rateio_pagamentos where rateio_id='${R1}'`) === "2");

  /* ===== COMPROVANTES (Storage real) ===== */
  const R5 = (await criar(U.luiz, "Energia com comprovante", 300, "igual", [{ loja_id: S }, { loja_id: E }], { comp: true })).data;
  const P5 = (await pagar(U.luiz, R5, S, 300)).data.pagamento_id;
  const pth = `rateio/${R5}/${P5}/${uuid()}.pdf`, corpo = pdf(2048);
  check("rafael (não participa) não envia comprovante de pagamento do rateio", !!(await up(U.rafael, pth, corpo, "application/pdf")).error);
  check("luiz (pagador) envia o PDF; registra; repetir devolve o mesmo", !(await up(U.luiz, pth, corpo, "application/pdf")).error);
  const cid = (await U.luiz.rpc("registrar_comprovante_rateio", { p_pagamento_id: P5, p_reembolso_id: null, p_path: pth, p_nome: "energia.pdf", p_mime: "application/pdf", p_tamanho: corpo.length })).data;
  check("comprovante do pagamento externo registrado (e idempotente)", !!cid && (await U.luiz.rpc("registrar_comprovante_rateio", { p_pagamento_id: P5, p_reembolso_id: null, p_path: pth, p_nome: "energia.pdf", p_mime: "application/pdf", p_tamanho: corpo.length })).data === cid);
  const dl = async (c, p) => c.storage.from(BUCKET).download(p);
  check("EZ (participante) baixa para conferir; rafael e anônimo NÃO", !(await dl(U.victor, pth)).error && !!(await dl(U.rafael, pth)).error && !!(await dl(anon, pth)).error && !!(await U.rafael.storage.from(BUCKET).createSignedUrl(pth, 60)).error);
  check("dono baixa de qualquer rateio; enzo (Start, não participa do R5) não baixa", !(await dl(U.chefe, pth)).error && !!(await dl(U.enzo, pth)).error);
  const s1 = await U.victor.storage.from(BUCKET).createSignedUrl(pth, 60, { download: true }), r1 = await fetch(s1.data.signedUrl);
  check("link assinado do comprovante de rateio entrega o arquivo como anexo", r1.status === 200 && Buffer.from(await r1.arrayBuffer()).equals(corpo) && /attachment/i.test(r1.headers.get("content-disposition") || ""));
  const big = await up(U.luiz, `rateio/${R5}/${P5}/${uuid()}.pdf`, pdf(5 * 1024 * 1024 + 1), "application/pdf");
  check("arquivo acima de 5 MB e tipo proibido são recusados", !!big.error && !!(await up(U.luiz, `rateio/${R5}/${P5}/${uuid()}.pdf`, Buffer.from("MZ"), "application/x-msdownload")).error && !!(await up(U.luiz, `rateio/${R5}/${P5}/${uuid()}.exe`, Buffer.from("MZ"), "application/pdf")).error);
  // reembolso: comprovante OPCIONAL
  const rb5 = (await reemb(U.victor, R5, E, S, 150)).data.reembolso_id;
  check("reembolso sem comprovante é válido (opcional)", !!rb5 && sql(`select count(*) from comprovantes_rateio where reembolso_id='${rb5}'`) === "0");
  const pth2 = `rateio/${R5}/${rb5}/${uuid()}.png`, c2 = crypto.randomBytes(800);
  check("comprovante opcional do reembolso: sobe e registra", !(await up(U.victor, pth2, c2, "image/png")).error && !(await U.victor.rpc("registrar_comprovante_rateio", { p_pagamento_id: null, p_reembolso_id: rb5, p_path: pth2, p_nome: "pix.png", p_mime: "image/png", p_tamanho: c2.length })).error);
  check("nova tentativa de upload após falha: não duplica reembolso nem pagamento (1 reembolso, 2 comprovantes no total)", !(await up(U.victor, pth2, c2, "image/png")).data && sql(`select count(*) from rateio_reembolsos where rateio_id='${R5}'`) === "1" && sql(`select count(*) from comprovantes_rateio where rateio_id='${R5}'`) === "2");
  check("rafael não registra comprovante em movimento do rateio", /permiss/i.test(msg((await U.rafael.rpc("registrar_comprovante_rateio", { p_pagamento_id: P5, p_reembolso_id: null, p_path: pth, p_nome: "x.pdf", p_mime: "application/pdf", p_tamanho: corpo.length })).error)));

  /* ===== LIMPEZA DE ÓRFÃOS NÃO TOCA EM ARQUIVOS DE RATEIO ===== */
  const orfao = `rateio/${R5}/${P5}/${uuid()}.pdf`; await up(U.luiz, orfao, pdf(300), "application/pdf");
  sqlAdmin(`update storage.objects set created_at = now() - interval '3 days' where bucket_id='comprovantes' and name in ('${pth}','${pth2}','${orfao}')`);
  const ap = cp.spawnSync("node", [path.join(__dirname, "../../ops/limpar_comprovantes_orfaos.js"), "--apply"], { env: { ...process.env, SUPABASE_URL: URL, SUPABASE_SERVICE_KEY: SERVICE }, encoding: "utf8" });
  check("limpeza remove o órfão e PRESERVA os comprovantes vinculados de rateio (pagamento e reembolso)", ap.status === 0 && sql(`select count(*) from storage.objects where name='${orfao}'`) === "0" && sql(`select count(*) from storage.objects where name in ('${pth}','${pth2}')`) === "2" && !(await svc.storage.from(BUCKET).download(pth)).error && !(await svc.storage.from(BUCKET).download(pth2)).error, ap.stdout + ap.stderr);

  console.log(`\nVALIDAÇÃO DE RATEIOS NA PILHA REAL (API): ${pass} ok, ${fail} falhas`); falhas.forEach(f => console.log("  ✗ " + f));
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error("ERRO NO TESTE:", e.stack ? e.stack.split("\n").slice(0, 5).join("\n") : e); process.exit(2); });

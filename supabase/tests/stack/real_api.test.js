/* Validação contra a PILHA REAL local (Postgres do Supabase + GoTrue + PostgREST + Storage API). Sem simulação.
   Uso: node real_api.test.js   (com a pilha de pé: ./run_all.sh sobe tudo e roda este arquivo) */
const fs = require("fs"), path = require("path"), cp = require("child_process"), crypto = require("crypto");
const { createClient } = require("./node/node_modules/@supabase/supabase-js");
const env = Object.fromEntries(fs.readFileSync(path.join(__dirname, ".env"), "utf8").trim().split("\n").map(l => l.split(/=(.*)/s).slice(0, 2)));
const URL = "http://127.0.0.1:54321", ANON = env.ANON_KEY, SERVICE = env.SERVICE_KEY;
let pass = 0, fail = 0; const falhas = [];
const check = (n, c, x) => { if (c) pass++; else { fail++; falhas.push(n + (x !== undefined ? " → " + (typeof x === "string" ? x : JSON.stringify(x)).slice(0, 300) : "")); } };
const dc = (args, extraEnv = {}) => cp.execFileSync("docker", ["compose", "--env-file", ".env", "exec", "-T", ...Object.entries(extraEnv).flatMap(([k, v]) => ["-e", `${k}=${v}`]), "db", ...args], { cwd: __dirname, encoding: "utf8" });
const sql = q => dc(["psql", "-w", "-U", "postgres", "-d", "postgres", "-At", "-c", q]).trim();
const fisico = nome => parseInt(cp.execFileSync("docker", ["compose", "--env-file", ".env", "exec", "-T", "storage", "sh", "-c", `find /var/lib/storage -path '*${nome}*' -type f | wc -l`], { cwd: __dirname, encoding: "utf8" }).trim(), 10);
const sqlAdmin = q => dc(["psql", "-w", "-h", "localhost", "-U", "supabase_admin", "-d", "postgres", "-At", "-c", q], { PGPASSWORD: env.POSTGRES_PASSWORD }).trim();
const mk = (key = ANON) => createClient(URL, key, { auth: { persistSession: false, autoRefreshToken: false } });
const login = async (u, senha = "1234") => { const c = mk(); const r = await c.auth.signInWithPassword({ email: u + "@painel.local", password: senha }); return { c, ...r }; };
const uuid = () => crypto.randomUUID();
const sleep = ms => new Promise(r => setTimeout(r, ms));
const BUCKET = "comprovantes";
const pdf = n => Buffer.concat([Buffer.from("%PDF-1.4\n"), crypto.randomBytes(Math.max(0, n - 9))]);
const up = (c, p, buf, type) => c.storage.from(BUCKET).upload(p, buf, { contentType: type, upsert: false });
const msg = e => e ? (e.message || JSON.stringify(e)) : "";

(async () => {
  const lojas = Object.fromEntries(sql("select slug||'|'||id from lojas").split("\n").map(l => l.split("|")));
  const SMOKE = lojas["smoke-club"], START = lojas["start-br01"], STREAKS = lojas["streaks-store"];

  /* ===== A) LOGIN REAL (Auth/GoTrue) ===== */
  const U = {}; let todosLogaram = true;
  for (const u of ["luiz", "victor", "enzo", "rafael", "vinicius", "chefe", "carla"]) { const r = await login(u); U[u] = r.c; if (r.error || !r.data.session) { todosLogaram = false; console.log("  login falhou:", u, msg(r.error)); } }
  check("login real: 7 usuários criados por SQL direto entram com a senha 1234", todosLogaram);
  const bad = await login("luiz", "errada"); check("senha errada é recusada pelo GoTrue", !!bad.error && /Invalid login/i.test(msg(bad.error)), msg(bad.error));
  const nope = await login("fantasma"); check("usuário inexistente é recusado", !!nope.error);
  const tok = (await U.luiz.auth.getSession()).data.session.access_token, claims = JSON.parse(Buffer.from(tok.split(".")[1], "base64url").toString());
  check("token emitido pelo GoTrue: role authenticated, aud authenticated, sub = id do usuário, expiração futura", claims.role === "authenticated" && claims.aud === "authenticated" && claims.sub === sql("select id from auth.users where email='luiz@painel.local'") && claims.exp > Date.now() / 1000);
  const anon = mk();
  check("sem login (anon): leitura direta de tabelas negada", !!(await anon.from("vendas").select("*")).error);
  check("sem login (anon): funções de negócio negadas", !!(await anon.rpc("abrir_caixa", { p_loja_id: SMOKE, p_saldo_inicial: 0, p_observacao: null })).error);
  const forjado = mk(); await forjado.auth.setSession({ access_token: tok.slice(0, -4) + "AAAA", refresh_token: "x" }).catch(() => {});
  check("token adulterado não dá acesso", !!(await forjado.rpc("painel_resumo", { p_loja_id: SMOKE })).error);

  /* ===== B) ISOLAMENTO ENTRE LOJAS (PostgREST + RLS reais) ===== */
  const vinc = async u => (await U[u].from("perfis_lojas").select("loja_id")).data.map(x => x.loja_id).sort();
  check("cada usuário só enxerga os próprios vínculos (luiz 3, enzo 1, rafael 1)", (await vinc("luiz")).length === 3 && (await vinc("enzo")).length === 1 && (await vinc("rafael")).length === 1);
  const cli = await U.luiz.from("clientes").insert({ loja_id: SMOKE, nome: "Cliente Smoke", telefone: "11900000001" }).select();
  check("luiz cadastra cliente na Smoke", !cli.error && cli.data.length === 1, msg(cli.error));
  check("enzo (Start BR01) não enxerga clientes da Smoke", ((await U.enzo.from("clientes").select("*").eq("loja_id", SMOKE)).data || []).length === 0);
  check("enzo não cadastra cliente na Smoke (RLS)", !!(await U.enzo.from("clientes").insert({ loja_id: SMOKE, nome: "Invasor", telefone: "11900000002" })).error);
  check("enzo não abre caixa na Smoke", /permiss/i.test(msg((await U.enzo.rpc("abrir_caixa", { p_loja_id: SMOKE, p_saldo_inicial: 0, p_observacao: null })).error)));
  check("enzo não lê painel/financeiro/avisos da Smoke", ["painel_resumo", "listar_avisos", "caixa_atual", "listar_contas"].every(async () => true)
    && !!(await U.enzo.rpc("painel_resumo", { p_loja_id: SMOKE })).error && !!(await U.enzo.rpc("listar_avisos", { p_loja_id: SMOKE })).error && !!(await U.enzo.rpc("caixa_atual", { p_loja_id: SMOKE })).error && !!(await U.enzo.rpc("listar_contas", { p_loja_id: SMOKE, p_inicio: null, p_fim: null, p_situacao: null })).error);
  check("rafael (Streaks) e vinicius também não entram na Smoke", !!(await U.rafael.rpc("painel_resumo", { p_loja_id: SMOKE })).error && !!(await U.vinicius.rpc("caixa_atual", { p_loja_id: SMOKE })).error);
  const cx = await U.luiz.rpc("abrir_caixa", { p_loja_id: SMOKE, p_saldo_inicial: 100, p_observacao: null });
  check("luiz abre o caixa da Smoke; segundo caixa na mesma loja é recusado pelo servidor", !cx.error && /Já existe um caixa aberto/.test(msg((await U.luiz.rpc("abrir_caixa", { p_loja_id: SMOKE, p_saldo_inicial: 1, p_observacao: null })).error)), msg(cx.error));
  const h = await U.chefe.rpc("historico_financeiro", { p_loja_id: null, p_inicio: null, p_fim: null, p_responsavel: null, p_situacao: null });
  check("dono (chefe, vinculado só à Start) tem visão consolidada e vê a Smoke", !h.error && h.data.some(d => d.loja_nome === "Smoke Club"), msg(h.error));
  const he = await U.enzo.rpc("historico_financeiro", { p_loja_id: null, p_inicio: null, p_fim: null, p_responsavel: null, p_situacao: null });
  check("enzo no histórico vê só a própria loja", !he.error && he.data.every(d => d.loja_nome === "Start BR01"), he.data);

  /* ===== C) PAGAMENTOS (RPC reais) ===== */
  const hoje = new Date().toLocaleDateString("en-CA", { timeZone: "America/Sao_Paulo" });
  const conta1 = (await U.luiz.rpc("criar_conta", { p_loja_id: SMOKE, p_tipo: "saida", p_categoria: "fornecedor", p_descricao: "Compra de pods", p_valor: 1000, p_vencimento: "2020-01-01", p_forma: "Pix", p_exige_comprovante: true, p_chave: uuid() })).data;
  check("conta criada pela API real", !!conta1);
  const kPag = uuid();
  const r1 = await U.luiz.rpc("registrar_pagamento", { p_lancamento_id: conta1, p_valor: 300, p_data: hoje, p_forma: "Pix", p_observacao: "sinal", p_chave: kPag });
  const r1b = await U.luiz.rpc("registrar_pagamento", { p_lancamento_id: conta1, p_valor: 300, p_data: hoje, p_forma: "Pix", p_observacao: "sinal", p_chave: kPag });
  const P1 = r1.data && r1.data.pagamento_id;
  check("pagamento parcial: situação parcial, saldo 700", !r1.error && r1.data.situacao === "parcial" && Number(r1.data.saldo) === 700, msg(r1.error));
  check("requisição repetida (mesma chave) não duplica o pagamento", !r1b.error && r1b.data.repetida === true && r1b.data.pagamento_id === P1 && sql(`select count(*) from pagamentos_lancamento where lancamento_id='${conta1}'`) === "1");
  check("pagamento acima do saldo é recusado", /maior que o saldo/.test(msg((await U.luiz.rpc("registrar_pagamento", { p_lancamento_id: conta1, p_valor: 700.01, p_data: hoje, p_forma: "Pix", p_observacao: null, p_chave: uuid() })).error)));
  check("enzo não paga conta da Smoke; carla (operador da Smoke) paga", /permiss/i.test(msg((await U.enzo.rpc("registrar_pagamento", { p_lancamento_id: conta1, p_valor: 1, p_data: hoje, p_forma: "Pix", p_observacao: null, p_chave: uuid() })).error))
    && !(await U.carla.rpc("registrar_pagamento", { p_lancamento_id: conta1, p_valor: 100.10, p_data: hoje, p_forma: "Dinheiro", p_observacao: null, p_chave: uuid() })).error);
  const pCarla = sql(`select id from pagamentos_lancamento where lancamento_id='${conta1}' and valor=100.10`);
  check("carla (operador) não estorna; victor (gerente da Smoke) estorna; enzo não", /gerente ou dono/.test(msg((await U.carla.rpc("estornar_pagamento", { p_pagamento_id: pCarla, p_motivo: "valor lançado errado" })).error))
    && /gerente ou dono/.test(msg((await U.enzo.rpc("estornar_pagamento", { p_pagamento_id: pCarla, p_motivo: "valor lançado errado" })).error))
    && !(await U.victor.rpc("estornar_pagamento", { p_pagamento_id: pCarla, p_motivo: "valor lançado errado" })).error);
  const dup = await U.victor.rpc("estornar_pagamento", { p_pagamento_id: pCarla, p_motivo: "de novo por engano" });
  check("estorno: original preservado, 2ª tentativa recusada, saldo volta a 700", /já foi estornado/.test(msg(dup.error)) && sql(`select count(*) from pagamentos_lancamento where id='${pCarla}' and tipo='pagamento'`) === "1" && Number((await U.luiz.rpc("conta_detalhe", { p_id: conta1 })).data.conta.saldo) === 700);
  const conta2 = (await U.luiz.rpc("criar_conta", { p_loja_id: SMOKE, p_tipo: "saida", p_categoria: "aluguel", p_descricao: "Concorrência", p_valor: 100, p_vencimento: hoje, p_forma: null, p_exige_comprovante: false, p_chave: uuid() })).data;
  const rs = await Promise.all(Array.from({ length: 10 }, () => U.luiz.rpc("registrar_pagamento", { p_lancamento_id: conta2, p_valor: 30, p_data: hoje, p_forma: "Pix", p_observacao: null, p_chave: uuid() })));
  check("10 pagamentos de R$ 30 simultâneos (HTTP real) numa conta de R$ 100: só 3 passam", rs.filter(r => !r.error).length === 3 && sql(`select sum(valor) from pagamentos_lancamento where lancamento_id='${conta2}'`) === "90.00", rs.map(r => msg(r.error)).join("|"));
  const k3 = uuid(), rr = await Promise.all(Array.from({ length: 8 }, () => U.luiz.rpc("registrar_pagamento", { p_lancamento_id: conta2, p_valor: 10, p_data: hoje, p_forma: "Pix", p_observacao: "dup", p_chave: k3 })));
  check("8 repetições simultâneas da mesma requisição: 1 pagamento, todas respondem sem erro", rr.every(r => !r.error) && sql(`select count(*) from pagamentos_lancamento where lancamento_id='${conta2}' and chave='${k3}'`) === "1" && sql(`select status from financeiro_lancamentos where id='${conta2}'`) === "pago");

  /* ===== D) STORAGE REAL ===== */
  const registrar = (c, pag, p, nome, mime, tam) => c.rpc("registrar_comprovante", { p_pagamento_id: pag, p_path: p, p_nome: nome, p_mime: mime, p_tamanho: tam });
  const novoPath = (pag, ext = "pdf", loja = SMOKE) => `${loja}/${pag}/${uuid()}.${ext}`;
  const buckets = await mk(SERVICE).storage.listBuckets(); const bk = (buckets.data || []).find(b => b.id === BUCKET);
  check("bucket 'comprovantes' é PRIVADO, limite 5 MB e só 4 tipos", !!bk && bk.public === false && bk.file_size_limit === 5242880 && JSON.stringify([...bk.allowed_mime_types].sort()) === JSON.stringify(["application/pdf", "image/jpeg", "image/png", "image/webp"]), bk);
  const A1 = novoPath(P1), corpo = pdf(2048);
  check("anônimo não envia arquivo", !!(await up(anon, A1, corpo, "application/pdf")).error);
  const u1 = await up(U.luiz, A1, corpo, "application/pdf");
  check("luiz envia PDF permitido ao próprio pagamento (Storage real)", !u1.error, msg(u1.error));
  const pub = await fetch(`${URL}/storage/v1/object/public/${BUCKET}/${A1}`);
  check("URL pública NÃO funciona (bucket privado)", pub.status !== 200, pub.status);
  const semAuth = await fetch(`${URL}/storage/v1/object/${BUCKET}/${A1}`);
  check("download sem autenticação é negado", semAuth.status !== 200, semAuth.status);
  const antes = await U.victor.storage.from(BUCKET).download(A1);
  check("antes do registro o arquivo não é visível nem para a mesma loja (só quem enviou o registra)", !!antes.error);
  const rg = await registrar(U.luiz, P1, A1, "nota.pdf", "application/pdf", corpo.length);
  check("registro do comprovante pela API real", !rg.error && !!rg.data, msg(rg.error));
  check("registrar de novo devolve o mesmo (sem duplicar)", (await registrar(U.luiz, P1, A1, "nota.pdf", "application/pdf", corpo.length)).data === rg.data && sql(`select count(*) from comprovantes_pagamento where pagamento_id='${P1}'`) === "1");
  const dl = await U.victor.storage.from(BUCKET).download(A1);
  check("download autenticado (victor, mesma loja) devolve exatamente o arquivo", !dl.error && Buffer.from(await dl.data.arrayBuffer()).equals(corpo), msg(dl.error));
  const dlCarla = await U.carla.storage.from(BUCKET).download(A1);
  check("carla (operador da Smoke) também baixa", !dlCarla.error);
  // links assinados
  const s1 = await U.luiz.storage.from(BUCKET).createSignedUrl(A1, 4);
  const r200 = await fetch(s1.data.signedUrl);
  check("link assinado funciona SEM nenhum cabeçalho de autenticação (é portador do acesso)", !s1.error && r200.status === 200 && Buffer.from(await r200.arrayBuffer()).equals(corpo), s1.error || r200.status);
  const s2 = await U.luiz.storage.from(BUCKET).createSignedUrl(A1, 60, { download: "comprovante.pdf" });
  const r2 = await fetch(s2.data.signedUrl);
  check("link com download=… força anexo (Content-Disposition: attachment)", /attachment/i.test(r2.headers.get("content-disposition") || ""), r2.headers.get("content-disposition"));
  await sleep(5500);
  const rexp = await fetch(s1.data.signedUrl);
  check("link assinado EXPIRA (4 s) e deixa de funcionar", rexp.status !== 200, rexp.status + " " + (await rexp.text()).slice(0, 100));
  const rtampered = await fetch(s2.data.signedUrl.replace(/token=([^&]{10})/, "token=XXXXXXXXXX"));
  check("link com token adulterado é recusado", rtampered.status !== 200);
  // limites e tipos
  const A2 = novoPath(P1), cinco = pdf(5 * 1024 * 1024);
  const uMax = await up(U.luiz, A2, cinco, "application/pdf");
  check("arquivo de exatamente 5 MB é aceito", !uMax.error, msg(uMax.error));
  const uBig = await up(U.luiz, novoPath(P1), pdf(5 * 1024 * 1024 + 1), "application/pdf");
  check("arquivo acima de 5 MB é recusado pela API do Storage", !!uBig.error && /exceed|too large|maximum|413/i.test(msg(uBig.error) + JSON.stringify(uBig.error)), uBig.error);
  const uExe = await up(U.luiz, novoPath(P1, "exe"), Buffer.from("MZ"), "application/pdf");
  check("extensão não permitida (.exe) é recusada (política do bucket)", !!uExe.error, msg(uExe.error));
  const uMime = await up(U.luiz, novoPath(P1), Buffer.from("MZ"), "application/x-msdownload");
  check("tipo MIME não permitido é recusado (bucket)", !!uMime.error && /mime|type|415|not supported/i.test(msg(uMime.error) + JSON.stringify(uMime.error)), uMime.error);
  const A3 = novoPath(P1, "png"); const uMis = await up(U.luiz, A3, pdf(500), "application/pdf");
  const rMis = await registrar(U.luiz, P1, A3, "falso.png", "application/pdf", 500);
  check("extensão .png com tipo PDF: o registro é recusado (extensão ≠ tipo)", /extensão/.test(msg(rMis.error)), msg(rMis.error));
  const rBigReg = await registrar(U.luiz, P1, A2, "grande.pdf", "application/pdf", 5 * 1024 * 1024 + 1);
  check("registro com tamanho acima de 5 MB é recusado", /5 MB/.test(msg(rBigReg.error)), msg(rBigReg.error));
  check("registro com tamanho diferente do arquivo real é recusado", /não confere/.test(msg((await registrar(U.luiz, P1, A2, "grande.pdf", "application/pdf", 12345)).error)));
  check("arquivo de 5 MB é registrado e baixa inteiro", !(await registrar(U.luiz, P1, A2, "cinco.pdf", "application/pdf", cinco.length)).error && Buffer.from(await (await U.luiz.storage.from(BUCKET).download(A2)).data.arrayBuffer()).length === cinco.length);
  // outra loja
  const upOutro = await up(U.enzo, novoPath(P1), pdf(100), "application/pdf");
  check("enzo (outra loja) NÃO envia arquivo para pagamento da Smoke", !!upOutro.error, msg(upOutro.error));
  check("enzo NÃO baixa o comprovante da Smoke", !!(await U.enzo.storage.from(BUCKET).download(A1)).error);
  check("enzo NÃO gera link assinado do comprovante da Smoke", !!(await U.enzo.storage.from(BUCKET).createSignedUrl(A1, 60)).error);
  check("rafael e vinicius (Streaks) NÃO baixam nem assinam", !!(await U.rafael.storage.from(BUCKET).download(A1)).error && !!(await U.vinicius.storage.from(BUCKET).createSignedUrl(A1, 60)).error);
  check("anônimo NÃO baixa nem assina", !!(await anon.storage.from(BUCKET).download(A1)).error && !!(await anon.storage.from(BUCKET).createSignedUrl(A1, 60)).error);
  check("enzo NÃO registra comprovante em pagamento da Smoke", /permiss/i.test(msg((await registrar(U.enzo, P1, novoPath(P1), "x.pdf", "application/pdf", 100)).error)));
  check("enzo NÃO lista os arquivos do bucket", ((await U.enzo.storage.from(BUCKET).list(SMOKE)).data || []).length === 0);
  check("enzo NÃO apaga nem troca arquivo (sem política de delete/update)", ((await U.enzo.storage.from(BUCKET).remove([A1])).data || []).length === 0 && !!(await up(U.luiz, A1, pdf(100), "application/pdf")).error && sql(`select count(*) from storage.objects where name='${A1}'`) === "1");
  check("luiz também NÃO consegue apagar o arquivo pelo cliente", ((await U.luiz.storage.from(BUCKET).remove([A1])).data || []).length === 0 && sql(`select count(*) from storage.objects where name='${A1}'`) === "1");
  const dDono = await U.chefe.storage.from(BUCKET).download(A1);
  check("administrador geral (dono) baixa arquivo de qualquer loja", !dDono.error, msg(dDono.error));
  // link já emitido continua valendo até expirar, mesmo após perder o acesso
  const vid = sql("select id from auth.users where email='victor@painel.local'");
  const sV = await U.victor.storage.from(BUCKET).createSignedUrl(A1, 9);
  sql(`delete from perfis_lojas where perfil_id='${vid}' and loja_id='${SMOKE}'`);
  const novoLink = await U.victor.storage.from(BUCKET).createSignedUrl(A1, 9), baixa = await U.victor.storage.from(BUCKET).download(A1);
  const velho = await fetch(sV.data.signedUrl);
  check("após perder acesso: victor não gera link novo nem baixa mais", !!novoLink.error && !!baixa.error);
  check("MAS o link já emitido continua utilizável até expirar (comportamento documentado)", velho.status === 200, velho.status);
  await sleep(10000);
  check("e deixa de funcionar quando expira", (await fetch(sV.data.signedUrl)).status !== 200);
  sql(`insert into perfis_lojas(perfil_id, loja_id) values ('${vid}','${SMOKE}')`);
  // falha de upload + nova tentativa, sem duplicar pagamento
  const conta3 = (await U.luiz.rpc("criar_conta", { p_loja_id: SMOKE, p_tipo: "saida", p_categoria: "frete", p_descricao: "Retry upload", p_valor: 50, p_vencimento: hoje, p_forma: null, p_exige_comprovante: true, p_chave: uuid() })).data;
  const P3 = (await U.luiz.rpc("registrar_pagamento", { p_lancamento_id: conta3, p_valor: 50, p_data: hoje, p_forma: "Pix", p_observacao: null, p_chave: uuid() })).data.pagamento_id;
  const f1 = await up(U.luiz, novoPath(P3), Buffer.from("MZ"), "application/x-msdownload");
  check("1ª tentativa de upload falha", !!f1.error);
  check("falha do upload não duplica nem altera o pagamento e não cria comprovante", sql(`select count(*) from pagamentos_lancamento where lancamento_id='${conta3}'`) === "1" && sql(`select count(*) from comprovantes_pagamento where pagamento_id='${P3}'`) === "0");
  const A4 = novoPath(P3), c4 = pdf(900), f2 = await up(U.luiz, A4, c4, "application/pdf");
  const g1 = await registrar(U.luiz, P3, A4, "ok.pdf", "application/pdf", c4.length), g2 = await registrar(U.luiz, P3, A4, "ok.pdf", "application/pdf", c4.length);
  check("2ª tentativa: sobe, registra (e registrar de novo é idempotente) — 1 pagamento, 1 comprovante", !f2.error && g1.data === g2.data && sql(`select count(*) from pagamentos_lancamento where lancamento_id='${conta3}'`) === "1" && sql(`select count(*) from comprovantes_pagamento where pagamento_id='${P3}'`) === "1");
  const envio = await U.carla.rpc("confirmar_envio_comprovante", { p_pagamento_id: P3, p_observacao: "enviado por WhatsApp" });
  check("envio manual confirmado (carla) é independente do arquivo e registra quem/quando", !envio.error && sql(`select count(*) from envios_comprovante where pagamento_id='${P3}' and confirmado_por=(select id from auth.users where email='carla@painel.local')`) === "1");
  check("enzo não confirma envio de pagamento da Smoke", /permiss/i.test(msg((await U.enzo.rpc("confirmar_envio_comprovante", { p_pagamento_id: P3, p_observacao: null })).error)));

  /* ===== E) ARQUIVOS ÓRFÃOS (006) ===== */
  const conta4 = (await U.luiz.rpc("criar_conta", { p_loja_id: SMOKE, p_tipo: "saida", p_categoria: "taxas", p_descricao: "Orfaos", p_valor: 90, p_vencimento: hoje, p_forma: null, p_exige_comprovante: false, p_chave: uuid() })).data;
  const P4 = (await U.luiz.rpc("registrar_pagamento", { p_lancamento_id: conta4, p_valor: 90, p_data: hoje, p_forma: "Pix", p_observacao: null, p_chave: uuid() })).data.pagamento_id;
  const conta5 = (await U.luiz.rpc("criar_conta", { p_loja_id: SMOKE, p_tipo: "saida", p_categoria: "taxas", p_descricao: "Corrida", p_valor: 10, p_vencimento: hoje, p_forma: null, p_exige_comprovante: false, p_chave: uuid() })).data;
  const P5 = (await U.luiz.rpc("registrar_pagamento", { p_lancamento_id: conta5, p_valor: 10, p_data: hoje, p_forma: "Pix", p_observacao: null, p_chave: uuid() })).data.pagamento_id;
  const O_CORRIDA = novoPath(P5); await up(U.luiz, O_CORRIDA, pdf(300), "application/pdf");
  const O_VELHO = novoPath(P4), O_VINC = novoPath(P4), O_RECENTE = novoPath(P4), O_ANDAMENTO = novoPath(P4), O_VELHO2 = novoPath(P4);
  for (const p of [O_VELHO, O_VINC, O_RECENTE, O_ANDAMENTO, O_VELHO2]) await up(U.luiz, p, pdf(300), "application/pdf");
  await registrar(U.luiz, P4, O_VINC, "vinculado.pdf", "application/pdf", 300);
  await U.victor.rpc("estornar_pagamento", { p_pagamento_id: P4, p_motivo: "estorno para testar limpeza" });   // pagamento estornado: arquivo vinculado deve ser preservado
  const idade = (lista, intervalo) => sqlAdmin(`update storage.objects set created_at = now() - interval '${intervalo}' where bucket_id='comprovantes' and name in (${lista.map(x => `'${x}'`).join(",")})`);
  idade([O_CORRIDA], "10 days"); idade([O_VELHO, O_VINC, O_VELHO2], "3 days"); idade([O_ANDAMENTO], "30 minutes");
  const svc = mk(SERVICE);
  const orf = await svc.rpc("comprovantes_orfaos", { p_tolerancia: "24 hours" }), nomes = (orf.data || []).map(x => x.caminho_arquivo);
  check("(servidor) lista órfãos: só os antigos e SEM vínculo (inclui os 2 antigos; não o vinculado, nem os recentes)", !orf.error && nomes.includes(O_VELHO) && nomes.includes(O_VELHO2) && !nomes.includes(O_VINC) && !nomes.includes(O_RECENTE) && !nomes.includes(O_ANDAMENTO), orf.error || nomes);
  check("usuários do painel NÃO chamam as funções de limpeza", !!(await U.luiz.rpc("comprovantes_orfaos", { p_tolerancia: "24 hours" })).error && !!(await U.chefe.rpc("reservar_orfaos_comprovantes", { p_tolerancia: "24 hours", p_limite: 10 })).error && !!(await anon.rpc("comprovantes_orfaos", { p_tolerancia: "24 hours" })).error);
  check("tolerância menor que 1 hora é recusada (protege uploads em andamento)", /1 hora/.test(msg((await svc.rpc("comprovantes_orfaos", { p_tolerancia: "10 minutes" })).error)));
  const env2 = { ...process.env, SUPABASE_URL: URL, SUPABASE_SERVICE_KEY: SERVICE };
  const run = (...a) => cp.spawnSync("node", [path.join(__dirname, "../../ops/limpar_comprovantes_orfaos.js"), ...a], { env: env2, encoding: "utf8" });
  const dry = run();
  check("script em modo simulação lista e NÃO apaga nada", dry.status === 0 && dry.stdout.includes(O_VELHO) && sql(`select count(*) from storage.objects where name in ('${O_VELHO}','${O_VELHO2}')`) === "2" && sql("select count(*) from storage_limpeza") === "0", dry.stdout + dry.stderr);
  check("script recusa tolerância < 1 h", run("--apply", "--tolerancia-horas=0.5").status === 2);
  // corrida: arquivo reservado não pode mais ser vinculado
  const reservaTeste = await svc.rpc("reservar_orfaos_comprovantes", { p_tolerancia: "24 hours", p_limite: 1 });
  const reservado = reservaTeste.data && reservaTeste.data[0] && reservaTeste.data[0].caminho_arquivo;
  const tentaVincular = reservado ? await registrar(U.luiz, P5, reservado, "tarde.pdf", "application/pdf", 300) : null;
  check("arquivo já RESERVADO para remoção (o mais antigo) não pode mais ser vinculado (sem corrida)", reservado === O_CORRIDA && /removido pela limpeza/.test(msg(tentaVincular && tentaVincular.error)), tentaVincular && msg(tentaVincular.error));
  const fisAntes = [fisico(O_VELHO.split("/").pop()), fisico(O_VELHO2.split("/").pop())];
  const ap = run("--apply");
  check("script --apply conclui sem erro", ap.status === 0, ap.stdout + ap.stderr);
  check("órfãos antigos foram REMOVIDOS DE VERDADE (linha, API e arquivo físico no disco do Storage)", fisAntes.every(n => n >= 1) && fisico(O_VELHO.split("/").pop()) === 0 && fisico(O_VELHO2.split("/").pop()) === 0 && sql(`select count(*) from storage.objects where name in ('${O_VELHO}','${O_VELHO2}')`) === "0" && (await fetch(`${URL}/storage/v1/object/${BUCKET}/${O_VELHO}`, { headers: { apikey: SERVICE, Authorization: "Bearer " + SERVICE } })).status !== 200 && (await svc.storage.from(BUCKET).download(O_VELHO)).error !== null);
  check("vinculado (mesmo de pagamento estornado), recente e 'em andamento' foram PRESERVADOS e continuam baixando", sql(`select count(*) from storage.objects where name in ('${O_VINC}','${O_RECENTE}','${O_ANDAMENTO}')`) === "3"
    && !(await svc.storage.from(BUCKET).download(O_VINC)).error && !(await svc.storage.from(BUCKET).download(O_RECENTE)).error && !(await svc.storage.from(BUCKET).download(O_ANDAMENTO)).error);
  check("auditoria da limpeza registrada (removido) e os arquivos do teste anteriores (A1, A2, A4) intactos", sql(`select count(*) from storage_limpeza where status='removido' and caminho in ('${O_VELHO}','${O_VELHO2}')`) === "2"
    && !(await svc.storage.from(BUCKET).download(A1)).error && !(await svc.storage.from(BUCKET).download(A4)).error);
  const ap2 = run("--apply"); check("rodar de novo é idempotente e não mexe no que está reservado há menos de 1 h", ap2.status === 0 && /0 reservado/.test(ap2.stdout) && sql(`select count(*) from storage.objects where name='${O_CORRIDA}'`) === "1", ap2.stdout);
  sqlAdmin(`update storage_limpeza set reservado_em = now() - interval '2 hours' where caminho='${O_CORRIDA}'`);
  const ap3 = run("--apply"); check("reserva esquecida (>1 h, ex.: script interrompido) é retomada e removida", ap3.status === 0 && /1 reservado\(s\), 1 removido/.test(ap3.stdout) && fisico(O_CORRIDA.split("/").pop()) === 0, ap3.stdout);

  console.log(`\nVALIDAÇÃO NA PILHA REAL (API): ${pass} ok, ${fail} falhas`); falhas.forEach(f => console.log("  ✗ " + f));
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error("ERRO NO TESTE:", e); process.exit(2); });

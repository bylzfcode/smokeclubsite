/* Catálogo online (014) — API REAL (Auth + PostgREST + Postgres do Supabase local): o que o site (anônimo) lê = o que a dashboard grava.
   Papéis do seed: luiz = gerente (Smoke, Start, EZ); carla = operadora (Smoke); chefe = dono; victor = gerente (Smoke, EZ). */
const fs = require("fs"), path = require("path"), cp = require("child_process"), crypto = require("crypto");
const { createClient } = require("./node/node_modules/@supabase/supabase-js");
const env = Object.fromEntries(fs.readFileSync(path.join(__dirname, ".env"), "utf8").trim().split("\n").map(l => l.split(/=(.*)/s).slice(0, 2)));
const URL = "http://127.0.0.1:54321", ANON = env.ANON_KEY;
let pass = 0, fail = 0; const falhas = [];
const check = (n, c, x) => { if (c) pass++; else { fail++; falhas.push(n + (x !== undefined ? " → " + (typeof x === "string" ? x : JSON.stringify(x)).slice(0, 300) : "")); } };
const sql = q => cp.execFileSync("docker", ["compose", "--env-file", ".env", "exec", "-T", "db", "psql", "-w", "-U", "postgres", "-d", "postgres", "-At", "-c", q], { cwd: __dirname, encoding: "utf8" }).trim();
const login = async u => { const c = createClient(URL, ANON, { auth: { persistSession: false, autoRefreshToken: false } }); const r = await c.auth.signInWithPassword({ email: u + "@painel.local", password: "1234" }); if (r.error) throw new Error(u + ": " + r.error.message); return c; };
const msg = e => e ? (e.message || JSON.stringify(e)) : "";
const TAG = "CO" + Date.now();

(async () => {
  const L = Object.fromEntries(sql("select slug||'|'||id from lojas").split("\n").map(l => l.split("|"))); const S = L["smoke-club"], T = L["start-br01"];
  const U = {}; for (const u of ["luiz", "carla", "chefe", "victor"]) U[u] = await login(u);
  const anon = createClient(URL, ANON, { auth: { persistSession: false, autoRefreshToken: false } });
  const pub = async (slug = "smoke-club") => { const r = await anon.rpc("catalogo_publico", { p_loja_slug: slug }); if (r.error) throw new Error(msg(r.error)); return r.data; };
  const achar = (c, nome) => c.produtos.find(p => p.nome === nome);

  /* ---- a dashboard cria; o anônimo (site) lê ---- */
  const cat = (await U.luiz.from("categorias").insert({ nome: `Cat ${TAG}`, cor: "azul", ordem: 1 }).select().single()).data;
  const marca = (await U.luiz.from("marcas").insert({ nome: `Marca ${TAG}`, descricao: "Pods premium", cor_fundo: "#112233", ordem: 1 }).select().single()).data;
  const ci = await U.luiz.rpc("criar_item", { p_loja_id: S, p_tipo: "produto", p_marca_id: null, p_categoria_id: cat.id, p_nome: `Essência ${TAG}`, p_emoji: "🍉", p_sabores: ["Menta", "Uva"], p_estoque_inicial: 5, p_estoque_minimo: 2 });
  const cm = await U.luiz.rpc("criar_item", { p_loja_id: S, p_tipo: "modelo", p_marca_id: marca.id, p_categoria_id: null, p_nome: `Pod ${TAG}`, p_emoji: "💨", p_sabores: [], p_estoque_inicial: 4, p_estoque_minimo: 1 });
  check("a dashboard cria itens (criar_item) sem erro", !ci.error && !cm.error, [msg(ci.error), msg(cm.error)]);
  const iA = ci.data && (ci.data.id || ci.data), iM = cm.data && (cm.data.id || cm.data);
  let c0 = await pub();
  check("item sem preço ainda NÃO aparece no site", !c0.produtos.some(p => p.item_id === iA) && !c0.marcas.some(m => m.nome === `Marca ${TAG}`));
  const pr = await Promise.all([U.luiz.from("precos_loja").upsert({ loja_id: S, item_id: iA, preco: 14.9, preco_de: 19.9, ativo: true }, { onConflict: "loja_id,item_id" }), U.luiz.from("precos_loja").upsert({ loja_id: S, item_id: iM, preco: 39.9, ativo: true }, { onConflict: "loja_id,item_id" })]);
  await U.luiz.from("itens").update({ descricao: "Doce e refrescante", destaque: true, imagem_url: "https://exemplo.com/a.jpg" }).eq("id", iA);
  const c1 = await pub();
  const menta = achar(c1, `Essência ${TAG} — Menta`), uva = achar(c1, `Essência ${TAG} — Uva`);
  check("com preço, cada sabor vira uma linha no site, com preço, de, descrição, destaque, imagem e categoria", !pr.some(r => r.error) && menta && uva && menta.preco === 14.9 && menta.de === 19.9 && menta.desc === "Doce e refrescante" && menta.destaque && menta.img === "https://exemplo.com/a.jpg" && menta.categoria === `Cat ${TAG}` && menta.estoque && menta.limite === 5, menta);
  check("modelo de marca aparece na marca com as cores; sem expor o estoque exato nem dados internos", c1.marcas.some(m => m.nome === `Marca ${TAG}` && m.cor_fundo === "#112233" && m.modelos.some(x => x.nome === `Pod ${TAG}` && x.preco === 39.9 && x.limite === 4)) && !/quantidade|cliente|venda|financeiro|criado_por|custo/i.test(JSON.stringify(c1)));
  check("anônimo não lê as tabelas diretamente (itens, estoque, preços, vendas)", await (async () => { const rs = await Promise.all(["itens", "estoque", "precos_loja", "vendas", "financeiro_lancamentos"].map(t => anon.from(t).select("*").limit(1))); return rs.every(r => r.error || (r.data || []).length === 0); })());

  /* ---- estoque da dashboard = estoque do site ---- */
  const est = Object.fromEntries(sql(`select s.nome||'|'||e.id from estoque e join sabores s on s.id=e.sabor_id where e.item_id='${iA}'`).split("\n").map(l => l.split("|")));
  await U.luiz.rpc("ajustar_estoque", { p_estoque_id: est.Uva, p_quantidade: -5, p_loja_id: S, p_observacao: "zerar teste" });
  let c2 = await pub();
  check("zerar o estoque de um sabor na dashboard o marca ESGOTADO no site (limite 0) e o outro segue disponível", achar(c2, `Essência ${TAG} — Uva`).estoque === false && achar(c2, `Essência ${TAG} — Uva`).limite === 0 && achar(c2, `Essência ${TAG} — Menta`).estoque === true);
  await U.luiz.rpc("registrar_venda", { p_loja_id: S, p_itens: [{ item_id: iA, sabor_id: sql(`select id from sabores where item_id='${iA}' and nome='Menta'`), quantidade: 5 }], p_cliente: null, p_forma_pagamento: "Pix", p_desconto: 0, p_chave: crypto.randomUUID() });
  c2 = await pub();
  check("venda registrada na dashboard (5 de 5) esgota o sabor no site", achar(c2, `Essência ${TAG} — Menta`).estoque === false);
  await U.luiz.rpc("ajustar_estoque", { p_estoque_id: est.Menta, p_quantidade: 40, p_loja_id: S, p_observacao: "entrada" });
  c2 = await pub();
  check("entrada de 40 volta a disponível e o limite é 20 (não revela o saldo)", achar(c2, `Essência ${TAG} — Menta`).estoque === true && achar(c2, `Essência ${TAG} — Menta`).limite === 20);

  /* ---- edição pela dashboard aparece no site ---- */
  await U.luiz.from("itens").update({ nome: `Essência ${TAG} Premium`, destaque: false }).eq("id", iA);
  await U.luiz.from("precos_loja").update({ preco: 15.5, preco_de: null }).eq("loja_id", S).eq("item_id", iA);
  await U.luiz.from("categorias").update({ nome: `Cat ${TAG} Nova`, cor: "roxo" }).eq("id", cat.id);
  await U.luiz.from("sabores").update({ nome: "Menta Gelada" }).eq("item_id", iA).eq("nome", "Menta");
  const c3 = await pub(), p3 = achar(c3, `Essência ${TAG} Premium — Menta Gelada`);
  check("renomear item, sabor e categoria, mudar preço e tirar o 'de' reflete no site", p3 && p3.preco === 15.5 && p3.de === null && p3.categoria === `Cat ${TAG} Nova` && !p3.destaque && c3.categorias.some(c => c.nome === `Cat ${TAG} Nova` && c.cor === "roxo"), p3);
  await U.luiz.from("precos_loja").update({ ativo: false }).eq("loja_id", S).eq("item_id", iA);
  check("'vender nesta loja' desligado tira o item do site; religar devolve", !(await pub()).produtos.some(p => p.item_id === iA) && (await U.luiz.from("precos_loja").update({ ativo: true }).eq("loja_id", S).eq("item_id", iA), (await pub()).produtos.some(p => p.item_id === iA)));
  await U.luiz.from("marcas").update({ ativo: false }).eq("id", marca.id);
  check("marca oculta some do site com seus modelos", !(await pub()).marcas.some(m => m.nome === `Marca ${TAG}`));
  await U.luiz.from("marcas").update({ ativo: true, nome: `Marca ${TAG} 2` }).eq("id", marca.id);
  check("marca visível de novo (renomeada) volta ao site", (await pub()).marcas.some(m => m.nome === `Marca ${TAG} 2`));
  await U.luiz.from("itens").update({ ativo: false }).eq("id", iM);
  check("item inativo some do site", !(await pub()).marcas.some(m => m.nome === `Marca ${TAG} 2`));
  await U.luiz.from("itens").update({ ativo: true }).eq("id", iM);
  const wpp = await U.luiz.rpc("definir_whatsapp_loja", { p_loja_id: S, p_whatsapp: "(11) 99999-0000" });
  check("WhatsApp definido na dashboard chega ao site só com dígitos", (await pub()).loja.whatsapp.replace(/^55/, "").endsWith("999990000") || /^\d{10,15}$/.test((await pub()).loja.whatsapp), [msg(wpp.error), (await pub()).loja.whatsapp]);

  /* ---- permissões e isolamento ---- */
  await U.carla.from("itens").update({ nome: "HACK" }).eq("id", iA); await U.carla.from("marcas").update({ nome: "HACK" }).eq("id", marca.id); await U.carla.from("categorias").update({ nome: "HACK" }).eq("id", cat.id);
  check("operadora não consegue editar itens, marcas nem categorias (RLS)", sql(`select count(*) from itens where id='${iA}' and nome like '%Premium'`) === "1" && sql(`select count(*) from marcas where id='${marca.id}' and nome like 'Marca%'`) === "1" && sql(`select count(*) from categorias where id='${cat.id}' and nome like 'Cat%'`) === "1");
  const pid = sql("select id from auth.users where email='victor@painel.local'");
  await U.chefe.rpc("definir_acesso_pessoa", { p_perfil: pid, p_ativo: false, p_motivo: "teste catálogo" });
  await U.victor.from("itens").update({ nome: "HACK2" }).eq("id", iA); await U.chefe.rpc("definir_acesso_pessoa", { p_perfil: pid, p_ativo: true });
  check("gerente desativado também não edita o catálogo", sql(`select count(*) from itens where id='${iA}' and nome like '%Premium'`) === "1");
  await U.luiz.from("precos_loja").upsert({ loja_id: T, item_id: iA, preco: 99.99, ativo: true }, { onConflict: "loja_id,item_id" });
  const cs = await pub("start-br01");
  check("o preço de outra loja não vaza para o catálogo da Smoke (e cada slug mostra o seu)", achar(await pub(), `Essência ${TAG} Premium — Menta Gelada`).preco === 15.5 && achar(cs, `Essência ${TAG} Premium — Menta Gelada`).preco === 99.99);
  check("loja inexistente é recusada", (await anon.rpc("catalogo_publico", { p_loja_slug: "nao-existe" })).error);
  check("catálogo é somente leitura: a função não altera nada (contagem igual antes/depois)", await (async () => { const q = "select (select count(*) from itens)||'/'||(select count(*) from estoque)||'/'||(select count(*) from precos_loja)||'/'||(select coalesce(sum(quantidade),0) from estoque)"; const a = sql(q); await pub(); await pub("start-br01"); return a === sql(q); })());

  console.log(`\nCATÁLOGO ONLINE (API real): ${pass} ok, ${fail} falhas`); if (fail) { falhas.forEach(f => console.log(" ✗ " + f)); process.exit(1); }
})().catch(e => { console.error("ERRO", e); process.exit(1); });

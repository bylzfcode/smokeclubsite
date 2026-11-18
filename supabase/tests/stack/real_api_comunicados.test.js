/* Comunicados — API REAL (Auth + PostgREST + Postgres do Supabase local). Papéis do seed: luiz = gerente (Smoke, Start, EZ); victor = gerente (Smoke, EZ);
   carla = operadora (Smoke); enzo = operador (só Start); chefe = dono (vinculado só à Start); rafael = gerente (só Streaks). */
const fs = require("fs"), path = require("path"), cp = require("child_process"), crypto = require("crypto");
const { createClient } = require("./node/node_modules/@supabase/supabase-js");
const env = Object.fromEntries(fs.readFileSync(path.join(__dirname, ".env"), "utf8").trim().split("\n").map(l => l.split(/=(.*)/s).slice(0, 2)));
const URL = "http://127.0.0.1:54321", ANON = env.ANON_KEY;
let pass = 0, fail = 0; const falhas = [];
const check = (n, c, x) => { if (c) pass++; else { fail++; falhas.push(n + (x !== undefined ? " → " + (typeof x === "string" ? x : JSON.stringify(x)).slice(0, 300) : "")); } };
const sql = q => cp.execFileSync("docker", ["compose", "--env-file", ".env", "exec", "-T", "db", "psql", "-w", "-U", "postgres", "-d", "postgres", "-At", "-c", q], { cwd: __dirname, encoding: "utf8" }).trim();
const login = async u => { const c = createClient(URL, ANON, { auth: { persistSession: false, autoRefreshToken: false } }); const r = await c.auth.signInWithPassword({ email: u + "@painel.local", password: "1234" }); if (r.error) throw new Error(u + ": " + r.error.message); return c; };
const uuid = () => crypto.randomUUID(), msg = e => e ? (e.message || JSON.stringify(e)) : "";
const TAG = "CM" + Date.now();

(async () => {
  const L = Object.fromEntries(sql("select slug||'|'||id from lojas").split("\n").map(l => l.split("|"))); const S = L["smoke-club"], T = L["start-br01"];
  const U = {}; for (const u of ["luiz", "victor", "carla", "enzo", "chefe", "rafael"]) U[u] = await login(u);
  const anon = createClient(URL, ANON, { auth: { persistSession: false, autoRefreshToken: false } });
  const salvar = (c, a) => c.rpc("salvar_comunicado", { p_id: null, p_loja_id: S, p_titulo: `Escala ${TAG}`, p_cabecalho: "", p_corpo: "", p_rodape: "", p_versao_base: null, p_chave: uuid(), ...a });
  const det = async (c, id) => (await c.rpc("comunicado_detalhe", { p_id: id })).data;

  /* ---- criar / persistir EXATAMENTE ---- */
  const cab = "📣 *AVISO* — _equipe_", cor = `Linha 1\n\n• item ✅\n  recuo preservado\n<script>alert(1)</script> <img src=x onerror=alert(1)> & "aspas" 'simples'\n\`\`\`mono\`\`\`\nFim 🙂`, rod = "— Gerência 💬";
  const k = uuid();
  const r1 = await salvar(U.luiz, { p_cabecalho: cab, p_corpo: cor, p_rodape: rod, p_chave: k });
  check("gerente cria rascunho (versão 1)", !r1.error && r1.data.versao === 1, msg(r1.error)); const id = r1.data && r1.data.id;
  const d1 = await det(U.luiz, id), c1 = d1.comunicado;
  check("texto persistido exatamente (emoji, quebras, espaços, HTML literal)", c1.cabecalho === cab && c1.corpo === cor && c1.rodape === rod, c1.corpo);
  check("título, status rascunho, autor e data registrados", c1.titulo === `Escala ${TAG}` && c1.status === "rascunho" && c1.criado_por_nome === "Luiz" && !!c1.criado_em && c1.atualizado_por_nome === "Luiz");
  const rr = await salvar(U.luiz, { p_cabecalho: cab, p_corpo: cor, p_rodape: rod, p_chave: k });
  check("mesma chave não duplica", rr.data.id === id && sql(`select count(*) from comunicados where titulo='Escala ${TAG}'`) === "1");
  check("rascunho não cria aviso", sql(`select count(*) from avisos where titulo='Escala ${TAG}'`) === "0");

  /* ---- editar + versões + restaurar ---- */
  const e2 = await U.luiz.rpc("salvar_comunicado", { p_id: id, p_loja_id: null, p_titulo: `Escala ${TAG}`, p_cabecalho: cab, p_corpo: cor + "\nextra", p_rodape: rod, p_versao_base: 1, p_chave: null });
  check("editar gera versão 2", !e2.error && e2.data.versao === 2, msg(e2.error));
  const dup = await U.luiz.rpc("salvar_comunicado", { p_id: id, p_loja_id: null, p_titulo: `Escala ${TAG}`, p_cabecalho: cab, p_corpo: "outro", p_rodape: rod, p_versao_base: 1, p_chave: null });
  check("base desatualizada é recusada (sem sobrescrever em silêncio)", /alterado por outra pessoa/.test(msg(dup.error)), msg(dup.error));
  // corrida real: duas gravações simultâneas com a mesma base — só uma vence
  const [ra, rb] = await Promise.all(["A", "B"].map(x => U.luiz.rpc("salvar_comunicado", { p_id: id, p_loja_id: null, p_titulo: `Escala ${TAG}`, p_cabecalho: cab, p_corpo: "corrida " + x, p_rodape: rod, p_versao_base: 2, p_chave: null })));
  check("duas gravações simultâneas com a mesma base: exatamente uma vence", [ra, rb].filter(x => !x.error).length === 1 && [ra, rb].filter(x => /alterado por outra pessoa/.test(msg(x.error))).length === 1, [msg(ra.error), msg(rb.error)]);
  const d3 = await det(U.luiz, id);
  check("histórico: 3 versões, com autor e data, mais recente primeiro", d3.versoes.length === 3 && d3.versoes[0].versao === 3 && d3.versoes.every(v => v.por_nome === "Luiz" && v.em), d3.versoes.length);
  const rs = await U.luiz.rpc("restaurar_comunicado", { p_id: id, p_versao: 1, p_versao_base: 3 });
  const d4 = await det(U.luiz, id);
  check("restaurar versão 1 cria versão 4 com o conteúdo da 1 e mantém todo o histórico", !rs.error && d4.comunicado.versao === 4 && d4.comunicado.corpo === cor && d4.versoes.length === 4 && d4.versoes[0].acao === "restaurado" && d4.versoes[0].restaurado_de === 1, msg(rs.error));

  /* ---- permissões ---- */
  const pCarla = await det(U.carla, id);
  check("operadora da Smoke (carla) vê e edita, mas não publica", pCarla.comunicado.pode_editar && !pCarla.comunicado.pode_publicar);
  const ec = await U.carla.rpc("salvar_comunicado", { p_id: id, p_loja_id: null, p_titulo: `Escala ${TAG}`, p_cabecalho: cab, p_corpo: cor + "\n(carla)", p_rodape: rod, p_versao_base: 4, p_chave: null });
  check("carla edita e fica registrada como autora da versão", !ec.error && (await det(U.luiz, id)).versoes[0].por_nome === "Carla", msg(ec.error));
  const pc = await U.carla.rpc("publicar_comunicado", { p_id: id, p_prioridade: "info", p_valido_ate: null, p_destaque: false, p_global: false });
  check("operadora não publica", /Só gerente/.test(msg(pc.error)), msg(pc.error));
  for (const u of ["enzo", "rafael"]) {
    const x = U[u]; const base = [await x.rpc("listar_comunicados", { p_loja_id: S }), await x.rpc("comunicado_detalhe", { p_id: id }), await salvar(x, {}),
      await x.rpc("salvar_comunicado", { p_id: id, p_loja_id: null, p_titulo: "Invasão aqui", p_cabecalho: "", p_corpo: "x", p_rodape: "", p_versao_base: 5, p_chave: null }),
      await x.rpc("restaurar_comunicado", { p_id: id, p_versao: 1, p_versao_base: 5 }), await x.rpc("publicar_comunicado", { p_id: id, p_prioridade: "info", p_valido_ate: null, p_destaque: false, p_global: false }), await x.rpc("despublicar_comunicado", { p_id: id })];
    check(`${u} (sem acesso à Smoke) não lista, abre, cria, edita, restaura, publica nem despublica`, base.every(b => b.error), base.map(b => msg(b.error).slice(0, 40)));
  }
  check("nada foi alterado pelas tentativas bloqueadas", (await det(U.luiz, id)).comunicado.corpo.endsWith("(carla)"));
  const dir = [await U.luiz.from("comunicados").select("*"), await U.luiz.from("comunicados_versoes").select("*"), await U.luiz.from("comunicados").insert({ loja_id: S, titulo: "Direto", criado_por: uuid(), atualizado_por: uuid(), chave_criacao: uuid() }), await U.luiz.from("comunicados").update({ corpo: "hack" }).eq("id", id), await U.luiz.from("comunicados").delete().eq("id", id)];
  check("acesso direto às tabelas (select/insert/update/delete) é negado, até para gerente", dir.every(x => x.error), dir.map(x => msg(x.error).slice(0, 30)));
  const an = [await anon.rpc("listar_comunicados", { p_loja_id: S }), await anon.rpc("salvar_comunicado", { p_id: null, p_loja_id: S, p_titulo: "Anônimo", p_cabecalho: "", p_corpo: "", p_rodape: "", p_versao_base: null, p_chave: uuid() }), await anon.from("comunicados").select("*")];
  check("anônimo não lê nem grava", an.every(x => x.error), an.map(x => msg(x.error).slice(0, 30)));

  /* ---- separação entre lojas: rascunhos por loja ---- */
  const rT = await U.enzo.rpc("salvar_comunicado", { p_id: null, p_loja_id: T, p_titulo: `Start ${TAG}`, p_cabecalho: "", p_corpo: "só da Start", p_rodape: "", p_versao_base: null, p_chave: uuid() });
  const lS = (await U.luiz.rpc("listar_comunicados", { p_loja_id: S })).data, lT = (await U.luiz.rpc("listar_comunicados", { p_loja_id: T })).data;
  check("enzo (operador da Start) cria rascunho na Start; a lista da Smoke não mostra o da Start e vice-versa", !rT.error && lS.every(x => x.loja_id === S) && lT.every(x => x.loja_id === T) && lT.some(x => x.id === rT.data.id) && !lS.some(x => x.id === rT.data.id), msg(rT.error));
  check("victor (gerente Smoke, sem Start) não vê a Start", (await U.victor.rpc("listar_comunicados", { p_loja_id: T })).error && (await U.victor.rpc("comunicado_detalhe", { p_id: rT.data.id })).error);
  check("dono (chefe, vinculado só à Start) acessa a Smoke", !(await U.chefe.rpc("listar_comunicados", { p_loja_id: S })).error && !(await U.chefe.rpc("comunicado_detalhe", { p_id: id })).error);

  /* ---- publicar como aviso interno ---- */
  const val = new Date(Date.now() + 3 * 86400000).toISOString();
  const pb = await U.victor.rpc("publicar_comunicado", { p_id: id, p_prioridade: "atencao", p_valido_ate: val, p_destaque: true, p_global: false });
  check("gerente da loja (victor) publica com prioridade, validade e destaque", !pb.error && pb.data.aviso_id, msg(pb.error));
  const av = pb.data && pb.data.aviso_id, msgTxt = (await det(U.luiz, id)).comunicado;
  const aS = (await U.carla.rpc("listar_avisos", { p_loja_id: S })).data || [], aT = (await U.enzo.rpc("listar_avisos", { p_loja_id: T })).data || [];
  const x = aS.find(a => a.id === av);
  check("aviso aparece para a Smoke (carla) com o texto exato do comunicado e prioridade; NÃO aparece na Start", !!x && x.prioridade === "atencao" && x.destaque && x.descricao === [cab, msgTxt.corpo, rod].join("\n\n").trim() && !aT.some(a => a.id === av), x && x.descricao.slice(0, 60));
  check("o mesmo aviso é o do sistema de avisos (1 linha em avisos, vinculado só à Smoke)", sql(`select count(*) from avisos where id='${av}'`) === "1" && sql(`select count(*) from avisos_lojas where aviso_id='${av}'`) === "1" && sql(`select tipo from avisos where id='${av}'`) === "comunicado");
  await U.carla.rpc("marcar_aviso_lido", { p_aviso_id: av, p_loja_id: S });
  const rep = await U.luiz.rpc("salvar_comunicado", { p_id: id, p_loja_id: null, p_titulo: `Escala ${TAG}`, p_cabecalho: cab, p_corpo: "texto novo", p_rodape: rod, p_versao_base: 5, p_chave: null });
  const dd = await det(U.luiz, id);
  check("editar depois de publicado: 'alterações não publicadas', aviso não muda até republicar", !rep.error && dd.comunicado.alteracoes_nao_publicadas && sql(`select descricao like '%texto novo%' from avisos where id='${av}'`) === "f", msg(rep.error));
  const rp = await U.victor.rpc("publicar_comunicado", { p_id: id, p_prioridade: "urgente", p_valido_ate: null, p_destaque: false, p_global: false });
  const aS2 = (await U.carla.rpc("listar_avisos", { p_loja_id: S })).data.find(a => a.id === av);
  check("republicar atualiza o MESMO aviso e quem já leu o vê como 'atualizado'", !rp.error && rp.data.aviso_id === av && sql(`select count(*) from avisos where titulo='Escala ${TAG}'`) === "1" && aS2.atualizado && !aS2.lido && aS2.prioridade === "urgente" && aS2.descricao.includes("texto novo"), msg(rp.error));
  check("aviso global só pelo dono (gerente recusado, dono aceito)", /administrador geral/.test(msg((await U.victor.rpc("publicar_comunicado", { p_id: id, p_prioridade: "info", p_valido_ate: null, p_destaque: false, p_global: true })).error)) && !(await U.chefe.rpc("publicar_comunicado", { p_id: id, p_prioridade: "info", p_valido_ate: null, p_destaque: false, p_global: true })).error);
  check("aviso virou global: gerente não despublica (regra dos avisos), dono sim", /administrador geral/.test(msg((await U.victor.rpc("despublicar_comunicado", { p_id: id })).error)));
  const ds = await U.chefe.rpc("despublicar_comunicado", { p_id: id });
  check("despublicar arquiva o aviso e volta a rascunho (histórico mantido)", !ds.error && sql(`select ativo from avisos where id='${av}'`) === "f" && (await det(U.luiz, id)).comunicado.status === "rascunho" && (await det(U.luiz, id)).versoes.length >= 8, msg(ds.error));
  check("limites do servidor: título curto, corpo > 2000 e mensagem > 2000 recusados", (await salvar(U.luiz, { p_titulo: "ab" })).error && (await salvar(U.luiz, { p_corpo: "a".repeat(2001) })).error && (await salvar(U.luiz, { p_cabecalho: "a".repeat(400), p_corpo: "b".repeat(1700) })).error);

  console.log(`\nCOMUNICADOS (API real): ${pass} ok, ${fail} falhas`); if (fail) { falhas.forEach(f => console.log(" ✗ " + f)); process.exit(1); }
})().catch(e => { console.error("ERRO", e); process.exit(1); });

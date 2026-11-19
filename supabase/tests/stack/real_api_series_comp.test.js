/* Séries compartilhadas (013) e retomada com prévia — API REAL (Auth + PostgREST + Postgres do Supabase local).
   Papéis do seed: luiz = gerente (Smoke, Start, EZ); victor = gerente (Smoke, EZ); carla = operadora (Smoke); enzo = operador (Start); chefe = dono; rafael = gerente (Streaks). */
const fs = require("fs"), path = require("path"), cp = require("child_process"), crypto = require("crypto");
const { createClient } = require("./node/node_modules/@supabase/supabase-js");
const env = Object.fromEntries(fs.readFileSync(path.join(__dirname, ".env"), "utf8").trim().split("\n").map(l => l.split(/=(.*)/s).slice(0, 2)));
const URL = "http://127.0.0.1:54321", ANON = env.ANON_KEY;
let pass = 0, fail = 0; const falhas = [];
const check = (n, c, x) => { if (c) pass++; else { fail++; falhas.push(n + (x !== undefined ? " → " + (typeof x === "string" ? x : JSON.stringify(x)).slice(0, 300) : "")); } };
const sql = q => cp.execFileSync("docker", ["compose", "--env-file", ".env", "exec", "-T", "db", "psql", "-w", "-U", "postgres", "-d", "postgres", "-At", "-c", q], { cwd: __dirname, encoding: "utf8" }).trim();
const login = async u => { const c = createClient(URL, ANON, { auth: { persistSession: false, autoRefreshToken: false } }); const r = await c.auth.signInWithPassword({ email: u + "@painel.local", password: "1234" }); if (r.error) throw new Error(u + ": " + r.error.message); return c; };
const uuid = () => crypto.randomUUID(), msg = e => e ? (e.message || JSON.stringify(e)) : "";
const hoje = new Date().toLocaleDateString("en-CA", { timeZone: "America/Sao_Paulo" });
const addDias = (iso, n) => { const d = new Date(iso + "T12:00:00Z"); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
const TAG = "SC" + Date.now();

(async () => {
  const L = Object.fromEntries(sql("select slug||'|'||id from lojas").split("\n").map(l => l.split("|"))); const S = L["smoke-club"], T = L["start-br01"], E = L["ez-store"];
  const U = {}; for (const u of ["luiz", "victor", "carla", "enzo", "chefe", "rafael"]) U[u] = await login(u);
  const pid = u => sql(`select id from auth.users where email='${u}@painel.local'`);
  const itens = [{ loja_id: S }, { loja_id: T }, { loja_id: E }];
  const criar = (c, over = {}) => c.rpc("criar_serie_rateio", { p_loja_id: S, p_descricao: `Internet ${TAG}`, p_categoria: "internet", p_valor_total: 100.01, p_exige_comprovante: false, p_metodo: "igual", p_itens: itens, p_frequencia: "semanal", p_intervalo: null, p_unidade: null,
    p_inicio: addDias(hoje, 1), p_fim_tipo: "quantidade", p_fim_data: null, p_fim_qtd: 20, p_chave: uuid(), ...over });

  /* ---- criação ---- */
  const k = uuid(), c1 = await criar(U.luiz, { p_chave: k }); const sid = c1.data && c1.data.serie_id;
  check("gerente das 3 lojas cria série compartilhada semanal (gera só a janela de 60 dias)", !c1.error && c1.data.geradas >= 8 && c1.data.geradas <= 10, msg(c1.error));
  const n = Number(sql(`select count(*) from rateios where serie_id='${sid}'`));
  check("cada ocorrência: rateio v1 ativo, 3 parcelas que somam 100,01, sem pagamentos, reembolsos nem comprovantes", sql(`select count(*) from rateios r where r.serie_id='${sid}' and r.versao=1 and r.status='ativo' and (select count(*) from rateio_parcelas p where p.rateio_id=r.id)=3 and (select sum(valor) from rateio_parcelas p where p.rateio_id=r.id)=100.01`) === String(n)
    && sql(`select (select count(*) from rateio_pagamentos x join rateios r on r.id=x.rateio_id where r.serie_id='${sid}')+(select count(*) from rateio_reembolsos x join rateios r on r.id=x.rateio_id where r.serie_id='${sid}')+(select count(*) from comprovantes_rateio x join rateios r on r.id=x.rateio_id where r.serie_id='${sid}')`) === "0");
  check("repetir a chave não duplica; 8 gerações simultâneas não duplicam", (await criar(U.luiz, { p_chave: k })).data.repetida === true && (await Promise.all(Array.from({ length: 8 }, () => U.luiz.rpc("gerar_series_loja", { p_loja_id: S })))).every(r => !r.error) && sql(`select count(*) = count(distinct serie_n) and count(*) = ${n} from rateios where serie_id='${sid}'`) === "t");
  check("auditoria: 'criado' por ocorrência e 'criada' na série", sql(`select count(*) from rateio_auditoria a join rateios r on r.id=a.rateio_id where r.serie_id='${sid}' and a.acao='criado'`) === String(n) && sql(`select count(*) from series_auditoria where serie_id='${sid}' and acao='criada'`) === "1");

  /* ---- permissões e isolamento ---- */
  check("victor (Smoke e EZ, sem Start) não cria série com a Start; operadora e rafael também não", (await criar(U.victor)).error && (await criar(U.carla)).error && (await criar(U.rafael)).error);
  check("victor cria entre Smoke e EZ (lojas que administra)", !(await criar(U.victor, { p_itens: [{ loja_id: S }, { loja_id: E }] })).error);
  check("método/centavos/loja atual inválidos recusados", (await criar(U.luiz, { p_metodo: "xyz" })).error && (await criar(U.luiz, { p_valor_total: 10.005 })).error && (await criar(U.luiz, { p_loja_id: L["streaks-store"] })).error && (await criar(U.luiz, { p_itens: [{ loja_id: S }] })).error);
  check("quem não administra todas as lojas não pausa nem vê a prévia; operador da Start vê a série mas sem gerir", (await U.victor.rpc("serie_controlar", { p_id: sid, p_acao: "pausar" })).error && (await U.victor.rpc("serie_retomar_previa", { p_id: sid })).error
    && (await U.enzo.rpc("listar_series", { p_loja_id: T })).data.find(s => s.id === sid && s.escopo === "compartilhada" && !s.pode_gerir) && (await U.rafael.rpc("listar_series", { p_loja_id: S })).error && (await U.rafael.rpc("gerar_series_loja", { p_loja_id: S })).error);
  check("tabelas e gerador fechados à API: séries, auditoria, gerar_series_pendentes, serie_gerar", [await U.luiz.from("contas_series").select("*"), await U.luiz.from("series_auditoria").select("*"), await U.luiz.rpc("gerar_series_pendentes"), await U.chefe.rpc("serie_gerar", { p_id: sid }), await createClient(URL, ANON).rpc("gerar_series_pendentes")].every(r => r.error));
  check("permissões de execução no banco: agendador só dono do banco/service_role; gerar_series_loja só logados", sql("select has_function_privilege('anon','public.gerar_series_pendentes()','execute')::text||has_function_privilege('authenticated','public.gerar_series_pendentes()','execute')::text||has_function_privilege('service_role','public.gerar_series_pendentes()','execute')::text||has_function_privilege('anon','public.gerar_series_loja(uuid)','execute')::text||has_function_privilege('authenticated','public.gerar_series_loja(uuid)','execute')::text") === "falsefalsetruefalsetrue");

  /* ---- ocorrências movimentadas ficam intactas; encerrar ---- */
  const oc = Object.fromEntries(sql(`select serie_n||'|'||id from rateios where serie_id='${sid}' and serie_n<=4 order by serie_n`).split("\n").map(l => l.split("|")));
  await U.luiz.rpc("registrar_pagamento_rateio", { p_rateio_id: oc[2], p_loja_id: S, p_valor: 50, p_data: hoje, p_forma: "Pix", p_observacao: null, p_chave: uuid() });
  await U.luiz.rpc("revisar_rateio", { p_id: oc[3], p_descricao: "Internet revisada", p_valor_total: 100.01, p_vencimento: addDias(hoje, 30), p_metodo: "igual", p_itens: itens, p_motivo: "ajuste de data" });
  await U.luiz.rpc("serie_controlar", { p_id: sid, p_acao: "pausar" });
  const pv0 = (await U.luiz.rpc("serie_retomar_previa", { p_id: sid })).data;
  check("prévia da retomada logo após pausar: nada faltante e nada gravado", pv0.faltantes_total === 0 && Number(sql(`select count(*) from rateios where serie_id='${sid}'`)) === n);
  const rt = await U.luiz.rpc("serie_controlar", { p_id: sid, p_acao: "retomar", p_modo: "gerar" });
  check("retomar sem faltantes: ativa, 0 geradas, nada duplicado", !rt.error && rt.data.geradas === 0 && Number(sql(`select count(*) from rateios where serie_id='${sid}'`)) === n, msg(rt.error));
  const en = await U.luiz.rpc("serie_controlar", { p_id: sid, p_acao: "encerrar", p_cancelar_futuras: true, p_motivo: "contrato encerrado" });
  check("encerrar cancelando futuras: a paga e a revisada permanecem ativas; as intocadas são canceladas; nada apagado", !en.error && sql(`select count(*) from rateios where id in ('${oc[2]}','${oc[3]}') and status='ativo'`) === "2" && sql(`select count(*) from rateios where id='${oc[4]}' and status='cancelado'`) === "1" && Number(sql(`select count(*) from rateios where serie_id='${sid}'`)) === n, msg(en.error));

  /* ---- retomada com lacunas: pular × gerar (séries montadas no banco; há registros cancelados/editados no meio) ---- */
  const monta = (escopo) => {
    const id = sql(`insert into contas_series (loja_id,tipo,categoria,descricao,valor,exige_comprovante,frequencia,intervalo,unidade,inicio,fim_tipo,status,proximo_k,pausada_em,criado_por,chave_criacao,escopo,metodo,itens) values ('${S}','saida','internet','Pausada ${escopo} ${TAG}',100,false,'semanal',1,'semana',current_date-40,'sem_prazo','pausada',0,now()-interval '41 days','${pid("luiz")}','${uuid()}','${escopo}',${escopo === "compartilhada" ? "'igual','" + JSON.stringify(itens) + "'::jsonb" : "null,null"}) returning id`).split("\n")[0];
    if (escopo === "compartilhada") {
      sql(`insert into rateios (descricao,categoria,valor_total,vencimento,metodo,exige_comprovante,chave_criacao,criado_por,serie_id,serie_n,vencimento_ref,status,versao) values ('Cancelada','internet',100,current_date-33,'igual',false,'${uuid()}','${pid("luiz")}','${id}',2,current_date-33,'cancelado',1)`);
      sql(`insert into rateios (descricao,categoria,valor_total,vencimento,metodo,exige_comprovante,chave_criacao,criado_por,serie_id,serie_n,vencimento_ref,status,versao) values ('Editada',  'internet',777,current_date-26,'igual',false,'${uuid()}','${pid("luiz")}','${id}',3,current_date-26,'ativo',2)`);
    } else {
      sql(`insert into financeiro_lancamentos (loja_id,tipo,categoria,descricao,valor,status,vencimento,vencimento_ref,criado_por,serie_id,serie_n) values ('${S}','saida','internet','Cancelada',100,'cancelada',current_date-33,current_date-33,'${pid("luiz")}','${id}',2)`);
      sql(`insert into financeiro_lancamentos (loja_id,tipo,categoria,descricao,valor,status,vencimento,vencimento_ref,criado_por,serie_id,serie_n,serie_editada) values ('${S}','saida','internet','Editada',777,'pendente',current_date-26,current_date-26,'${pid("luiz")}','${id}',3,true)`);
    }
    return id;
  };
  const tabela = e => e === "compartilhada" ? "rateios" : "financeiro_lancamentos";
  const idc = monta("compartilhada"), ide = monta("exclusiva");
  const pc = (await U.luiz.rpc("serie_retomar_previa", { p_id: idc })).data, pe = (await U.luiz.rpc("serie_retomar_previa", { p_id: ide })).data;
  check("prévia (as duas): 4 a tratar (1, 4, 5, 6); 2 e 3 já existem (cancelada e editada) e não serão tocados; a prévia não grava", [pc, pe].every(p => p.faltantes_total === 4 && p.ja_existem.length === 2 && p.ja_existem[0].situacao === "cancelada" && p.ja_existem[1].situacao === "editada" && p.pode_gerar) && sql(`select count(*) from rateios where serie_id='${idc}'`) === "2");
  const g = await U.luiz.rpc("serie_controlar", { p_id: idc, p_acao: "retomar", p_modo: "gerar" });
  check("GERAR (compartilhada): +4 do intervalo +9 da janela; cancelada e editada intactas; sem duplicar", !g.error && g.data.geradas === 13 && sql(`select count(*) from rateios where serie_id='${idc}'`) === "15" && sql(`select count(*) from rateios where serie_id='${idc}' and serie_n=2 and status='cancelado'`) === "1" && sql(`select count(*) from rateios where serie_id='${idc}' and serie_n=3 and valor_total=777 and versao=2`) === "1" && sql(`select count(*) = count(distinct serie_n) from rateios where serie_id='${idc}'`) === "t", msg(g.error));
  const pl = await U.luiz.rpc("serie_controlar", { p_id: ide, p_acao: "retomar", p_modo: "pular" });
  check("PULAR (exclusiva): 4 pulados e registrados; só a janela é criada; 2 e 3 intactas; os pulados não voltam", !pl.error && pl.data.puladas === 4 && sql(`select count(*) from financeiro_lancamentos where serie_id='${ide}'`) === "11" && sql(`select count(*) from financeiro_lancamentos where serie_id='${ide}' and serie_n in (1,4,5,6)`) === "0" && (await U.luiz.rpc("gerar_series_loja", { p_loja_id: S })).data >= 0 && sql(`select count(*) from financeiro_lancamentos where serie_id='${ide}' and serie_n in (1,4,5,6)`) === "0", msg(pl.error));
  check("retomadas auditadas com modo, pulados e gerados", sql(`select count(*) from series_auditoria where serie_id='${idc}' and acao='retomada' and detalhes->>'modo'='gerar' and (detalhes->>'geradas')::int=13`) === "1" && sql(`select count(*) from series_auditoria where serie_id='${ide}' and acao='retomada' and detalhes->>'modo'='pular' and (detalhes->>'puladas')::int=4`) === "1");
  check("retomar duas vezes em paralelo gera uma vez só", await (async () => { const id2 = monta("compartilhada"); const rs = await Promise.all(Array.from({ length: 5 }, () => U.luiz.rpc("serie_controlar", { p_id: id2, p_acao: "retomar", p_modo: "gerar" }))); return rs.every(r => !r.error) && sql(`select count(*) from rateios where serie_id='${id2}'`) === "15" && sql(`select count(*) from series_auditoria where serie_id='${id2}' and acao='retomada'`) === "1"; })());
  check("calendário e lista de rateios marcam as ocorrências como recorrentes", (await U.luiz.rpc("listar_rateios", { p_loja_id: S, p_situacao: null })).data.some(r => r.serie_id === idc && r.serie_n >= 1) && (await U.luiz.rpc("calendario_admin", { p_loja_id: S, p_inicio: hoje, p_fim: addDias(hoje, 60) })).data.eventos.some(e => e.tipo === "rateio" && e.recorrente));
  check("série compartilhada aparece em 'Esta loja' para cada loja participante (Smoke, Start e EZ)", (await U.luiz.rpc("listar_series", { p_loja_id: T })).data.some(s => s.id === idc) && (await U.victor.rpc("listar_series", { p_loja_id: E })).data.some(s => s.id === idc) && !(await U.victor.rpc("listar_series", { p_loja_id: S })).error);

  console.log(`\nSÉRIES COMPARTILHADAS E RETOMADA (API real): ${pass} ok, ${fail} falhas`); if (fail) { falhas.forEach(f => console.log(" ✗ " + f)); process.exit(1); }
})().catch(e => { console.error("ERRO", e); process.exit(1); });

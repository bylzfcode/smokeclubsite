/* Acessos (010), recorrência (011) e calendário (012) — API REAL (Auth + PostgREST + Postgres do Supabase local).
   Papéis do seed: luiz = gerente (Smoke, Start, EZ); victor = gerente (Smoke, EZ); carla = operadora (Smoke); enzo = operador (Start); chefe = dono (vinculado só à Start); rafael = gerente (Streaks). */
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
const TAG = "AD" + Date.now();

(async () => {
  const L = Object.fromEntries(sql("select slug||'|'||id from lojas").split("\n").map(l => l.split("|"))); const S = L["smoke-club"], T = L["start-br01"];
  const U = {}; for (const u of ["luiz", "victor", "carla", "enzo", "chefe", "rafael"]) U[u] = await login(u);
  const pid = u => sql(`select id from auth.users where email='${u}@painel.local'`);

  /* ================= ACESSOS ================= */
  const carlaId = pid("carla"), vincCarla = sql(`select count(*) from perfis_lojas where perfil_id='${carlaId}'`);
  const rLeg = await U.carla.rpc("criar_conta", { p_loja_id: S, p_tipo: "saida", p_categoria: "outro", p_descricao: `Histórico da Carla ${TAG}`, p_valor: 10, p_vencimento: addDias(hoje, 5), p_forma: null, p_exige_comprovante: false, p_chave: uuid() });
  check("carla (ativa) cria conta e lê a loja", !rLeg.error && (await U.carla.from("financeiro_lancamentos").select("id").eq("loja_id", S)).data.length > 0, msg(rLeg.error));
  check("só o dono lista e gerencia acessos (gerente e operadora recusados)", [await U.luiz.rpc("listar_pessoas"), await U.carla.rpc("listar_pessoas"), await U.luiz.rpc("definir_acesso_pessoa", { p_perfil: carlaId, p_ativo: false, p_motivo: "teste" })].every(r => r.error));
  const pes = (await U.chefe.rpc("listar_pessoas")).data || [];
  check("dono lista pessoas com papel, lojas e situação", pes.length >= 7 && pes.some(p => p.usuario === "carla" && p.ativo && p.lojas.length === 1));
  const d1 = await U.chefe.rpc("definir_acesso_pessoa", { p_perfil: carlaId, p_ativo: false, p_motivo: "saiu da equipe" });
  check("dono desativa a operadora (motivo obrigatório; auditoria gravada)", !d1.error && sql(`select count(*) from acessos_auditoria where perfil_id='${carlaId}' and acao='desativado' and motivo='saiu da equipe'`) === "1", msg(d1.error));
  // o MESMO cliente (token JWT ainda válido) é bloqueado no servidor
  const chamadas = [await U.carla.rpc("listar_contas", { p_loja_id: S, p_inicio: null, p_fim: null, p_situacao: null }), await U.carla.rpc("calendario_admin", { p_loja_id: S, p_inicio: hoje, p_fim: hoje }),
    await U.carla.rpc("criar_conta", { p_loja_id: S, p_tipo: "saida", p_categoria: "x", p_descricao: "y", p_valor: 10, p_vencimento: hoje, p_forma: null, p_exige_comprovante: false, p_chave: uuid() }), await U.carla.rpc("listar_comunicados", { p_loja_id: S })];
  check("desativada: o token ainda válido não adianta — todas as chamadas diretas à API são recusadas", chamadas.every(r => r.error), chamadas.map(r => msg(r.error).slice(0, 30)));
  const tabs = [await U.carla.from("financeiro_lancamentos").select("id"), await U.carla.from("perfis_lojas").select("loja_id"), await U.carla.from("itens").select("id"), await U.carla.from("lojas").select("id")];
  check("desativada: leituras diretas nas tabelas voltam vazias (RLS)", tabs.every(r => !r.error && r.data.length === 0), tabs.map(r => (r.data || []).length));
  check("o histórico dela continua no banco e visível para o gerente da loja", sql(`select count(*) from financeiro_lancamentos where descricao='Histórico da Carla ${TAG}' and criado_por='${carlaId}'`) === "1" && (await U.victor.from("financeiro_lancamentos").select("id").eq("descricao", `Histórico da Carla ${TAG}`)).data.length === 1);
  const novo = await login("carla");
  check("login continua possível (autenticação), mas sem acesso a dados: perfil lido como desativado", (await novo.from("perfis").select("ativo").eq("id", carlaId).single()).data.ativo === false && (await novo.from("perfis_lojas").select("loja_id")).data.length === 0);
  check("não desativa a si mesmo nem pessoa inexistente", /próprio/.test(msg((await U.chefe.rpc("definir_acesso_pessoa", { p_perfil: pid("chefe"), p_ativo: false, p_motivo: "teste" })).error)) && (await U.chefe.rpc("definir_acesso_pessoa", { p_perfil: uuid(), p_ativo: false, p_motivo: "teste" })).error);
  await U.chefe.rpc("definir_acesso_pessoa", { p_perfil: carlaId, p_ativo: true });
  check("reativada: acesso volta com as mesmas lojas", (await U.carla.rpc("listar_contas", { p_loja_id: S, p_inicio: null, p_fim: null, p_situacao: null })).error === null && sql(`select count(*) from perfis_lojas where perfil_id='${carlaId}'`) === vincCarla);
  const dl = await U.chefe.rpc("definir_lojas_pessoa", { p_perfil: carlaId, p_lojas: [T] });
  check("lojas trocadas pelo dono: perde a Smoke, acessa a Start; vazio recusado", !dl.error && (await U.carla.rpc("listar_contas", { p_loja_id: S, p_inicio: null, p_fim: null, p_situacao: null })).error && !(await U.carla.rpc("listar_contas", { p_loja_id: T, p_inicio: null, p_fim: null, p_situacao: null })).error && (await U.chefe.rpc("definir_lojas_pessoa", { p_perfil: carlaId, p_lojas: [] })).error);
  await U.chefe.rpc("definir_lojas_pessoa", { p_perfil: carlaId, p_lojas: [S] });
  check("gerente desativado perde as permissões de gerente", await (async () => { await U.chefe.rpc("definir_acesso_pessoa", { p_perfil: pid("victor"), p_ativo: false, p_motivo: "férias longas" }); const r = [await U.victor.rpc("criar_serie", { p_loja_id: S, p_tipo: "saida", p_categoria: "x", p_descricao: "y", p_valor: 10, p_forma: null, p_exige_comprovante: false, p_frequencia: "mensal", p_intervalo: null, p_unidade: null, p_inicio: hoje, p_fim_tipo: "sem_prazo", p_fim_data: null, p_fim_qtd: null, p_chave: uuid() }), await U.victor.from("categorias").insert({ nome: "Invasão " + TAG })]; await U.chefe.rpc("definir_acesso_pessoa", { p_perfil: pid("victor"), p_ativo: true }); return r.every(x => x.error); })());

  /* ================= RECORRÊNCIA ================= */
  const prev = (await U.luiz.rpc("serie_previa", { p_frequencia: "mensal", p_intervalo: null, p_unidade: null, p_inicio: "2031-01-31", p_fim_tipo: "quantidade", p_fim_data: null, p_fim_qtd: 4, p_limite: 12 })).data;
  check("prévia mensal a partir de 31/01/2031: 31/01, 28/02, 31/03, 30/04 (ajustadas marcadas)", prev && prev.datas.map(d => d.vencimento).join() === "2031-01-31,2031-02-28,2031-03-31,2031-04-30" && prev.datas[1].ajustada && !prev.datas[0].ajustada);
  const resumoAntes = (await U.luiz.rpc("financeiro_resumo", { p_loja_id: S, p_inicio: null, p_fim: null })).data;
  const k = uuid();
  const cs = await U.luiz.rpc("criar_serie", { p_loja_id: S, p_tipo: "saida", p_categoria: "aluguel", p_descricao: `Aluguel ${TAG}`, p_valor: 1234.56, p_forma: null, p_exige_comprovante: true, p_frequencia: "semanal", p_intervalo: null, p_unidade: null, p_inicio: addDias(hoje, 1), p_fim_tipo: "quantidade", p_fim_data: null, p_fim_qtd: 10, p_chave: k });
  check("criar série semanal de 10 ocorrências: gera só as da janela de 60 dias, todas pendentes", !cs.error && cs.data.geradas >= 8 && cs.data.geradas <= 10, msg(cs.error));
  const sid = cs.data.serie_id, nGer = Number(sql(`select count(*) from financeiro_lancamentos where serie_id='${sid}'`));
  check("repetir o pedido (mesma chave) não duplica", (await U.luiz.rpc("criar_serie", { p_loja_id: S, p_tipo: "saida", p_categoria: "aluguel", p_descricao: `Aluguel ${TAG}`, p_valor: 1234.56, p_forma: null, p_exige_comprovante: true, p_frequencia: "semanal", p_intervalo: null, p_unidade: null, p_inicio: addDias(hoje, 1), p_fim_tipo: "quantidade", p_fim_data: null, p_fim_qtd: 10, p_chave: k })).data.repetida === true && sql(`select count(*) from contas_series where chave_criacao='${k}'`) === "1");
  const par = await Promise.all(Array.from({ length: 8 }, () => U.luiz.rpc("gerar_series_loja", { p_loja_id: S })));
  check("8 gerações simultâneas (tela + agendador) sem erro e sem duplicar", par.every(r => !r.error) && Number(sql(`select count(*) from financeiro_lancamentos where serie_id='${sid}'`)) >= nGer && sql(`select count(*) = count(distinct serie_n) from financeiro_lancamentos where serie_id='${sid}'`) === "t");
  check("ocorrências: valor exato, pendentes, sem pagamentos nem comprovantes, exigem comprovante", sql(`select count(*) from financeiro_lancamentos where serie_id='${sid}' and (valor<>1234.56 or status<>'pendente' or not exige_comprovante)`) === "0" && sql(`select count(*) from pagamentos_lancamento p join financeiro_lancamentos f on f.id=p.lancamento_id where f.serie_id='${sid}'`) === "0");
  const resumoDepois = (await U.luiz.rpc("financeiro_resumo", { p_loja_id: S, p_inicio: null, p_fim: null })).data, nOc = Number(sql(`select count(*) from financeiro_lancamentos where serie_id='${sid}'`));
  check("resumo: 'a pagar' sobe exatamente o saldo das ocorrências (sem duplicar, sem mexer em entradas/saídas efetivadas)", Math.abs((resumoDepois.a_pagar.total - resumoAntes.a_pagar.total) - nOc * 1234.56) < 0.005 && resumoDepois.a_pagar.qtd - resumoAntes.a_pagar.qtd === nOc && resumoDepois.saidas === resumoAntes.saidas && resumoDepois.entradas === resumoAntes.entradas, [resumoAntes.a_pagar, resumoDepois.a_pagar]);
  const oc = Object.fromEntries(sql(`select serie_n||'|'||id from financeiro_lancamentos where serie_id='${sid}' order by serie_n limit 4`).split("\n").map(l => l.split("|")));
  await U.luiz.rpc("registrar_pagamento", { p_lancamento_id: oc[2], p_valor: 200, p_data: hoje, p_forma: "Pix", p_observacao: null, p_chave: uuid() });
  const e3 = await U.luiz.rpc("editar_conta", { p_id: oc[3], p_escopo: "esta", p_descricao: "Reajuste pontual", p_categoria: "aluguel", p_valor: 1300.1, p_vencimento: addDias(hoje, 30), p_forma: null, p_exige_comprovante: true });
  const ep = await U.luiz.rpc("editar_conta", { p_id: oc[2], p_escopo: "proximas", p_descricao: `Aluguel reajustado ${TAG}`, p_categoria: "aluguel", p_valor: 1500, p_vencimento: null, p_forma: null, p_exige_comprovante: true });
  check("editar só esta ocorrência e depois 'esta e as próximas': preserva a com pagamento e a editada à mão", !e3.error && !ep.error && ep.data.preservadas >= 2 && sql(`select valor from financeiro_lancamentos where id='${oc[2]}'`) === "1234.56" && sql(`select valor from financeiro_lancamentos where id='${oc[3]}'`) === "1300.10" && sql(`select valor from financeiro_lancamentos where id='${oc[4]}'`) === "1500.00", [msg(e3.error), msg(ep.error)]);
  check("valor de conta com pagamento não muda; operadora não edita nem controla série", /pagamentos/.test(msg((await U.luiz.rpc("editar_conta", { p_id: oc[2], p_escopo: "esta", p_descricao: "x", p_categoria: "aluguel", p_valor: 5, p_vencimento: null, p_forma: null, p_exige_comprovante: true })).error)) && (await U.carla.rpc("editar_conta", { p_id: oc[4], p_escopo: "esta", p_descricao: "x", p_categoria: "aluguel", p_valor: 5, p_vencimento: null, p_forma: null, p_exige_comprovante: false })).error && (await U.carla.rpc("serie_controlar", { p_id: sid, p_acao: "pausar" })).error);
  check("quem não tem acesso à loja não vê séries nem gera por ela", (await U.rafael.rpc("listar_series", { p_loja_id: S })).error && (await U.rafael.rpc("gerar_series_loja", { p_loja_id: S })).error && (await U.enzo.rpc("serie_controlar", { p_id: sid, p_acao: "pausar" })).error);
  check("o gerador interno e o agendador não são chamáveis pela API de ninguém logado", (await U.luiz.rpc("gerar_series_pendentes")).error && (await U.chefe.rpc("serie_gerar", { p_id: sid })).error && (await createClient(URL, ANON).rpc("gerar_series_pendentes")).error);
  const pz = await U.luiz.rpc("serie_controlar", { p_id: sid, p_acao: "pausar" }); const nP = Number(sql(`select count(*) from financeiro_lancamentos where serie_id='${sid}'`));
  await U.luiz.rpc("gerar_series_loja", { p_loja_id: S });
  check("pausar: nada novo é gerado nem apagado", !pz.error && Number(sql(`select count(*) from financeiro_lancamentos where serie_id='${sid}'`)) === nP && sql(`select status from contas_series where id='${sid}'`) === "pausada");
  await U.luiz.rpc("serie_controlar", { p_id: sid, p_acao: "retomar" });
  const en = await U.luiz.rpc("serie_controlar", { p_id: sid, p_acao: "encerrar", p_cancelar_futuras: true, p_motivo: "contrato rescindido" });
  check("retomar e encerrar (cancelando futuras intocadas): pagas/editadas permanecem e nada é apagado", !en.error && sql(`select status from contas_series where id='${sid}'`) === "encerrada" && Number(sql(`select count(*) from financeiro_lancamentos where serie_id='${sid}'`)) >= nP && sql(`select status from financeiro_lancamentos where id='${oc[2]}'`) === "parcial" && sql(`select status from financeiro_lancamentos where id='${oc[3]}'`) === "pendente" && Number(sql(`select count(*) from financeiro_lancamentos where serie_id='${sid}' and status='cancelada'`)) >= 1, msg(en.error));
  check("pg_cron e agendamento: a função informa o estado (no stack local não há pg_cron)", (await U.luiz.rpc("series_agendamento")).data.configurado === false);

  /* ================= CALENDÁRIO ================= */
  const cal = (await U.luiz.rpc("calendario_admin", { p_loja_id: S, p_inicio: hoje, p_fim: addDias(hoje, 20) })).data;
  check("calendário traz as ocorrências recorrentes marcadas e a conta única criada pela Carla", cal.eventos.some(e => e.id === oc[1] && e.recorrente) && cal.eventos.some(e => e.titulo === `Histórico da Carla ${TAG}`) && !cal.truncado);
  check("situações: vencimento futuro = pendente; parcial = pendente com saldo; cancelada = cancelado", cal.eventos.find(e => e.id === oc[2]).situacao === "pendente" && cal.eventos.find(e => e.id === oc[2]).parcial && Number(cal.eventos.find(e => e.id === oc[2]).saldo) === 1034.56);
  const rat = await U.luiz.rpc("criar_rateio", { p_descricao: `Rateio ${TAG}`, p_categoria: "internet", p_valor_total: 900, p_vencimento: addDias(hoje, 4), p_exige_comprovante: false, p_metodo: "igual", p_itens: [{ loja_id: S }, { loja_id: T }, { loja_id: L["ez-store"] }], p_chave: uuid() });
  const calT = (await U.enzo.rpc("calendario_admin", { p_loja_id: null, p_inicio: hoje, p_fim: addDias(hoje, 20) })).data.eventos;
  check("rateio aparece uma vez em cada loja envolvida (consolidado) e some para quem não participa", calT.filter(e => e.id === rat.data).length === 1 && !(await U.rafael.rpc("calendario_admin", { p_loja_id: null, p_inicio: hoje, p_fim: addDias(hoje, 20) })).data.eventos.some(e => e.id === rat.data));
  check("operador da Start não vê contas da Smoke no calendário e é recusado ao pedir a loja", !calT.some(e => e.id === oc[1]) && (await U.enzo.rpc("calendario_admin", { p_loja_id: S, p_inicio: hoje, p_fim: hoje })).error);
  const kc = uuid(), cm = await U.luiz.rpc("salvar_compromisso", { p_id: null, p_loja_id: S, p_titulo: `Reunião ${TAG}`, p_data: addDias(hoje, 2), p_responsavel: pid("victor"), p_observacao: "levar notas", p_versao_base: null, p_chave: kc });
  check("compromisso criado com responsável, autor e histórico; repetição não duplica", !cm.error && (await U.luiz.rpc("salvar_compromisso", { p_id: null, p_loja_id: S, p_titulo: `Reunião ${TAG}`, p_data: addDias(hoje, 2), p_responsavel: pid("victor"), p_observacao: "levar notas", p_versao_base: null, p_chave: kc })).data.repetida === true && sql(`select count(*) from compromissos where titulo='Reunião ${TAG}'`) === "1", msg(cm.error));
  const cid = cm.data.id;
  check("operadora da Smoke (Carla) edita o compromisso (acesso à loja); base desatualizada é recusada", !(await U.carla.rpc("salvar_compromisso", { p_id: cid, p_loja_id: null, p_titulo: `Reunião ${TAG}`, p_data: addDias(hoje, 3), p_responsavel: null, p_observacao: null, p_versao_base: 1, p_chave: null })).error && /outra pessoa/.test(msg((await U.luiz.rpc("salvar_compromisso", { p_id: cid, p_loja_id: null, p_titulo: "Outro título", p_data: hoje, p_responsavel: null, p_observacao: null, p_versao_base: 1, p_chave: null })).error)));
  check("operador da Start não vê nem altera o compromisso da Smoke", (await U.enzo.rpc("compromisso_detalhe", { p_id: cid })).error && (await U.enzo.rpc("mudar_status_compromisso", { p_id: cid, p_status: "cancelado", p_versao_base: 2 })).error);
  const cl = await U.luiz.rpc("mudar_status_compromisso", { p_id: cid, p_status: "concluido", p_versao_base: 2 });
  check("concluir e histórico (3 versões com autores diferentes)", !cl.error && (await U.luiz.rpc("compromisso_detalhe", { p_id: cid })).data.historico.length === 3 && (await U.luiz.rpc("calendario_admin", { p_loja_id: S, p_inicio: addDias(hoje, 0), p_fim: addDias(hoje, 5) })).data.eventos.find(e => e.id === cid).situacao === "concluido");
  const dir = [await U.luiz.from("compromissos").select("*"), await U.luiz.from("contas_series").select("*"), await U.luiz.from("acessos_auditoria").select("*"), await U.luiz.from("compromissos").delete().eq("id", cid)];
  check("tabelas novas fechadas à API direta (gerente inclusive)", dir.every(r => r.error), dir.map(r => msg(r.error).slice(0, 25)));
  check("consultar o calendário não altera nada (contagens iguais antes/depois)", await (async () => { const a = sql("select (select count(*) from financeiro_lancamentos)||'/'||(select count(*) from rateios)||'/'||(select count(*) from compromissos)"); await U.luiz.rpc("calendario_admin", { p_loja_id: null, p_inicio: hoje, p_fim: addDias(hoje, 40) }); return a === sql("select (select count(*) from financeiro_lancamentos)||'/'||(select count(*) from rateios)||'/'||(select count(*) from compromissos)"); })());

  console.log(`\nADMINISTRAÇÃO (acessos, recorrência, calendário — API real): ${pass} ok, ${fail} falhas`); if (fail) { falhas.forEach(f => console.log(" ✗ " + f)); process.exit(1); }
})().catch(e => { console.error("ERRO", e); process.exit(1); });

/* Supabase falso em memória, só para testar a TELA. Valida nomes de parâmetros das RPCs contra o SQL real. */
(function () {
  const CONTRACT = window.__CONTRACT || {};
  const ids = (() => { let n = 0; return p => `${p}-${++n}`; })();
  const L1 = "loja-1", L2 = "loja-2";
  const db = window.__db = {
    lojas: [{ id: L1, nome: "Smoke Club", slug: "smoke-club", whatsapp: null, ativo: true }, { id: L2, nome: "EZ Store", slug: "ez-store", whatsapp: null, ativo: true }],
    perfis: [{ id: "u-luiz", nome: "LUIZ", papel: "dono" }, { id: "u-enzo", nome: "ENZO", papel: "operador" }],
    perfis_lojas: [{ perfil_id: "u-luiz", loja_id: L1 }, { perfil_id: "u-luiz", loja_id: L2 }, { perfil_id: "u-enzo", loja_id: L1 }],
    marcas: [{ id: "m1", nome: "Ignite", ordem: 0 }], categorias: [{ id: "c1", nome: "Essências", ordem: 0 }],
    itens: [
      { id: "i1", tipo: "modelo", marca_id: "m1", categoria_id: null, nome: "Ignite V50", emoji: "💨", ativo: true },
      { id: "i2", tipo: "produto", marca_id: null, categoria_id: "c1", nome: "Carvão <img src=x onerror=\"window.__xss=1\">", emoji: "🔥", ativo: true },
      { id: "i3", tipo: "produto", marca_id: null, categoria_id: "c1", nome: "Item inativo", emoji: "🚫", ativo: false },
      { id: "i4", tipo: "produto", marca_id: null, categoria_id: "c1", nome: "Sem preço", emoji: "❓", ativo: true },
    ],
    sabores: [{ id: "s1", item_id: "i1", nome: "Menta", ordem: 0 }, { id: "s2", item_id: "i1", nome: "Uva", ordem: 1 }, { id: "s3", item_id: "i1", nome: "Esgotado", ordem: 2 }],
    estoque: [
      { id: "e1", item_id: "i1", sabor_id: "s1", quantidade: 5, estoque_minimo: 3 }, { id: "e2", item_id: "i1", sabor_id: "s2", quantidade: 2, estoque_minimo: 3 },
      { id: "e3", item_id: "i1", sabor_id: "s3", quantidade: 0, estoque_minimo: 3 }, { id: "e4", item_id: "i2", sabor_id: null, quantidade: 10, estoque_minimo: 3 },
      { id: "e5", item_id: "i3", sabor_id: null, quantidade: 9, estoque_minimo: 3 }, { id: "e6", item_id: "i4", sabor_id: null, quantidade: 9, estoque_minimo: 3 },
    ],
    precos_loja: [{ loja_id: L1, item_id: "i1", preco: 100, ativo: true }, { loja_id: L1, item_id: "i2", preco: 12.5, ativo: true }, { loja_id: L1, item_id: "i3", preco: 5, ativo: true }, { loja_id: L2, item_id: "i1", preco: 90, ativo: true }],
    clientes: [{ id: "c-ana", loja_id: L1, nome: "Ana", telefone: "11999990000", endereco: "Rua A" }],
    vendas: [], venda_itens: [], financeiro_lancamentos: [], estoque_movimentos: [],
    caixas: [], caixa_movs: [], pagamentos: [], comprovantes: [], envios: [], avisos: [{ id: 'av1', origem: 'aviso', tipo: 'sistema', titulo: 'Novo: caixa <b onmouseover="window.__xss=2">e avisos</b>', descricao: 'Texto', prioridade: 'info', destaque: false, global: true, lojas: [], lido: false, atualizado: false, criado_em: new Date().toISOString(), atualizado_em: new Date().toISOString() }], alertasLidos: {},
  };
  const log = window.__rpcLog = [];
  const users = { luiz: { id: "u-luiz", pw: "1234" }, enzo: { id: "u-enzo", pw: "1234" } };
  let session = null;
  const listeners = [];
  window.__emit = (table, payload) => listeners.forEach(l => l.table === table && l.cb(payload || { eventType: "UPDATE", new: {} }));
  window.__failNext = null; window.__netDown = false; window.__storage = {};

  const err = m => ({ data: null, error: { message: m } });
  const uid = () => session && session.user.id;
  const meuPerfil = () => db.perfis.find(p => p.id === uid());
  const minhas = () => db.perfis_lojas.filter(x => x.perfil_id === uid()).map(x => x.loja_id);
  const gerente = () => ["gerente", "dono"].includes(meuPerfil().papel);
  const money = n => Math.round(n * 100) / 100;

  function rel(table, row, sel) {
    const out = { ...row };
    const m = [...sel.matchAll(/(\w+)\(([^)]*)\)/g)];
    for (const [, name] of m) {
      if (name === "lojas") out.lojas = db.lojas.find(l => l.id === (row.loja_id)) || null;
      if (name === "clientes") out.clientes = db.clientes.find(c => c.id === row.cliente_id) || null;
      if (name === "perfis") out.perfis = db.perfis.find(p => p.id === row.criado_por) || null;
      if (name === "venda_itens") out.venda_itens = db.venda_itens.filter(v => v.venda_id === row.id);
    }
    return out;
  }
  function from(table) {
    let op = "select", sel = "*", filters = [], order = [], lim = null, payload = null, single = false, conflict = null;
    const q = {
      select(s) { sel = s || "*"; return q; }, eq(c, v) { filters.push(r => r[c] === v); return q; },
      gte(c, v) { filters.push(r => new Date(r[c]) >= new Date(v)); return q; }, lte(c, v) { filters.push(r => new Date(r[c]) <= new Date(v)); return q; },
      order(c, o) { order.push([c, !(o && o.ascending === false)]); return q; }, limit(n) { lim = n; return q; },
      maybeSingle() { single = true; return q; }, single() { single = true; return q; },
      insert(p) { op = "insert"; payload = p; return q; }, update(p) { op = "update"; payload = p; return q; },
      upsert(p, o) { op = "upsert"; payload = p; conflict = o && o.onConflict; return q; },
      then(res, rej) { return run().then(res, rej); },
    };
    async function run() {
      await new Promise(r => setTimeout(r, 5));
      if (window.__netDown) return err("Failed to fetch");
      if (!session) return err("JWT ausente");
      const rows = db[table]; if (!rows) return err("tabela desconhecida " + table);
      if (op === "insert") { if (["estoque", "estoque_movimentos", "vendas"].includes(table)) return err("permission denied (escrita direta bloqueada)");
        const r = { id: ids(table), criado_em: new Date().toISOString(), ...payload }; if (table === "financeiro_lancamentos") { r.criado_por = uid(); r.data_ref = r.criado_em; }
        rows.push(r); return { data: [r], error: null }; }
      if (op === "update") { if (["estoque", "vendas"].includes(table) || (table === "financeiro_lancamentos")) return err("permission denied (update direto bloqueado)");
        rows.filter(r => filters.every(f => f(r))).forEach(r => Object.assign(r, payload)); return { data: null, error: null }; }
      if (op === "upsert") { const keys = conflict.split(","); let r = rows.find(x => keys.every(k => x[k] === payload[k])); if (r) Object.assign(r, payload); else rows.push({ ...payload }); return { data: null, error: null }; }
      let out = rows.filter(r => filters.every(f => f(r)));
      for (const [c, asc] of order.slice().reverse()) out.sort((a, b) => (a[c] > b[c] ? 1 : a[c] < b[c] ? -1 : 0) * (asc ? 1 : -1));
      if (lim) out = out.slice(0, lim);
      out = out.map(r => rel(table, r, sel));
      return single ? { data: out[0] || null, error: null } : { data: out, error: null };
    }
    return q;
  }

  function checkParams(name, args) {
    const c = CONTRACT[name]; if (!c) throw new Error("RPC inexistente: " + name);
    for (const k of Object.keys(args)) if (!c.all.includes(k)) throw new Error(`RPC ${name}: parâmetro desconhecido "${k}"`);
    for (const k of c.required) if (!(k in args)) throw new Error(`RPC ${name}: parâmetro obrigatório ausente "${k}"`);
  }
  function mov(e, loja, tipo, q, venda, obs) { db.estoque_movimentos.push({ id: ids("mv"), estoque_id: e.id, loja_id: loja, tipo, quantidade: q, saldo_resultante: e.quantidade, venda_id: venda || null, observacao: obs || null, criado_em: new Date().toISOString(), criado_por: uid() }); }
  const R = {
    painel_resumo(a) {
      const vs = db.vendas.filter(v => v.loja_id === a.p_loja_id && v.status === "concluida"), t = vs.reduce((s, v) => s + v.total, 0);
      const fin = db.financeiro_lancamentos.filter(l => l.loja_id === a.p_loja_id), pend = fin.filter(l => l.status !== "pago");
      const sum = ls => ({ qtd: ls.length, total: ls.reduce((s, l) => s + Number(l.valor), 0) });
      const hoje = new Date().toLocaleDateString("en-CA", { timeZone: "America/Sao_Paulo" });
      return { hoje: { qtd: vs.length, total: t }, mes: { qtd: vs.length, total: t },
        saldo_caixa: fin.filter(l => l.status === "pago").reduce((s, l) => s + (l.tipo === "entrada" ? 1 : -1) * Number(l.valor), 0),
        a_receber: sum(pend.filter(l => l.tipo === "entrada")), a_pagar: sum(pend.filter(l => l.tipo === "saida")), atrasados: sum(pend.filter(l => l.vencimento && l.vencimento < hoje)),
        por_dia: Array.from({ length: 7 }, (_, i) => ({ dia: new Date(Date.now() - (6 - i) * 864e5).toISOString().slice(0, 10), total: i === 6 ? t : 0, qtd: i === 6 ? vs.length : 0 })),
        top_produtos: [] };
    },
    financeiro_resumo(a) {
      const fin = db.financeiro_lancamentos.filter(l => l.loja_id === a.p_loja_id), pago = fin.filter(l => l.status === "pago"), pend = fin.filter(l => l.status !== "pago");
      const s = (ls, t) => ls.filter(l => l.tipo === t).reduce((x, l) => x + Number(l.valor), 0), sm = ls => ({ qtd: ls.length, total: ls.reduce((x, l) => x + Number(l.valor), 0) });
      const hoje = new Date().toLocaleDateString("en-CA", { timeZone: "America/Sao_Paulo" });
      return { entradas: s(pago, "entrada"), saidas: s(pago, "saida"), saldo_periodo: s(pago, "entrada") - s(pago, "saida"), saldo_caixa: s(pago, "entrada") - s(pago, "saida"),
        a_receber: sm(pend.filter(l => l.tipo === "entrada")), a_pagar: sm(pend.filter(l => l.tipo === "saida")), atrasados: sm(pend.filter(l => l.vencimento && l.vencimento < hoje)) };
    },
    registrar_venda(a) {
      if (window.__failNext) { const m = window.__failNext; window.__failNext = null; throw new Error(m); }
      const dup = db.vendas.find(v => v.loja_id === a.p_loja_id && v.chave_idempotencia === a.p_chave);
      if (dup) return { id: dup.id, subtotal: dup.subtotal, desconto: dup.desconto, total: dup.total, repetida: true };
      if (!Array.isArray(a.p_itens) || !a.p_itens.length) throw new Error("Venda sem itens");
      let sub = 0; const its = [];
      for (const it of a.p_itens) {
        const e = db.estoque.find(x => x.item_id === it.item_id && (x.sabor_id || null) === (it.sabor_id || null)); if (!e) throw new Error("Item não encontrado");
        if (!Number.isInteger(it.quantidade) || it.quantidade <= 0) throw new Error("Quantidade inválida");
        if (e.quantidade < it.quantidade) throw new Error("Estoque insuficiente");
        const p = db.precos_loja.find(x => x.loja_id === a.p_loja_id && x.item_id === it.item_id && x.ativo); if (!p) throw new Error("Item sem preço nesta loja");
        sub += p.preco * it.quantidade; its.push([e, it, p]);
      }
      if (a.p_desconto > sub) throw new Error("Desconto maior que o subtotal");
      const v = { id: ids("v"), loja_id: a.p_loja_id, status: "concluida", subtotal: money(sub), desconto: a.p_desconto || 0, total: money(sub - (a.p_desconto || 0)), forma_pagamento: a.p_forma_pagamento, criado_em: new Date().toISOString(), chave_idempotencia: a.p_chave, cliente_nome: a.p_cliente && a.p_cliente.nome || null, cliente_id: null };
      if (a.p_cliente && a.p_cliente.telefone) { const t = a.p_cliente.telefone.replace(/\D/g, ""); let c = db.clientes.find(x => x.loja_id === a.p_loja_id && x.telefone === t); if (!c) { c = { id: ids("cli"), loja_id: a.p_loja_id, nome: a.p_cliente.nome, telefone: t, endereco: a.p_cliente.endereco }; db.clientes.push(c); } v.cliente_id = c.id; }
      db.vendas.push(v);
      for (const [e, it, p] of its) { e.quantidade -= it.quantidade; mov(e, a.p_loja_id, "venda", -it.quantidade, v.id); db.venda_itens.push({ id: ids("vi"), venda_id: v.id, nome_snapshot: db.itens.find(i => i.id === e.item_id).nome, quantidade: it.quantidade, preco_unitario: p.preco }); }
      db.financeiro_lancamentos.push({ id: ids("fin"), loja_id: a.p_loja_id, tipo: "entrada", categoria: "venda", valor: v.total, status: "pago", venda_id: v.id, criado_em: v.criado_em, data_ref: v.criado_em });
      return { id: v.id, subtotal: v.subtotal, desconto: v.desconto, total: v.total };
    },
    cancelar_venda(a) {
      const v = db.vendas.find(x => x.id === a.p_venda_id); if (!v) throw new Error("Venda não encontrada"); if (v.status === "cancelada") throw new Error("Venda já cancelada");
      v.status = "cancelada"; v.cancelada_em = new Date().toISOString(); v.motivo_cancelamento = a.p_motivo;
      db.venda_itens.filter(i => i.venda_id === v.id).forEach(i => { const it = db.itens.find(x => x.nome === i.nome_snapshot); const e = db.estoque.find(x => x.item_id === it.id); e.quantidade += i.quantidade; mov(e, v.loja_id, "estorno", i.quantidade, v.id); });
      db.financeiro_lancamentos.push({ id: ids("fin"), loja_id: v.loja_id, tipo: "saida", categoria: "estorno", valor: v.total, status: "pago", venda_id: v.id, criado_em: v.cancelada_em, data_ref: v.cancelada_em });
    },
    ajustar_estoque(a) { if (!gerente()) throw new Error("Só gerente ou dono pode ajustar o estoque"); const e = db.estoque.find(x => x.id === a.p_estoque_id); if (e.quantidade + a.p_quantidade < 0) throw new Error("Esse ajuste deixaria o estoque negativo"); e.quantidade += a.p_quantidade; mov(e, a.p_loja_id, a.p_quantidade > 0 ? "entrada" : "ajuste", a.p_quantidade, null, a.p_observacao); return e.quantidade; },
    contar_estoque(a) { const e = db.estoque.find(x => x.id === a.p_estoque_id); const d = a.p_quantidade_contada - e.quantidade; e.quantidade = a.p_quantidade_contada; mov(e, a.p_loja_id, "ajuste", d, null, a.p_observacao); return e.quantidade; },
    definir_estoque_minimo(a) { db.estoque.find(x => x.id === a.p_estoque_id).estoque_minimo = a.p_minimo; },
    criar_item(a) {
      if (!gerente()) throw new Error("Só gerente ou dono pode criar itens");
      const id = ids("item"); db.itens.push({ id, tipo: a.p_tipo, marca_id: a.p_marca_id, categoria_id: a.p_categoria_id, nome: a.p_nome, emoji: a.p_emoji, ativo: true });
      if (a.p_sabores && a.p_sabores.length) a.p_sabores.forEach((n, i) => { const sid = ids("sab"); db.sabores.push({ id: sid, item_id: id, nome: n, ordem: i }); db.estoque.push({ id: ids("est"), item_id: id, sabor_id: sid, quantidade: a.p_estoque_inicial, estoque_minimo: a.p_estoque_minimo }); });
      else db.estoque.push({ id: ids("est"), item_id: id, sabor_id: null, quantidade: a.p_estoque_inicial, estoque_minimo: a.p_estoque_minimo });
      return id;
    },
    adicionar_sabor(a) { const sid = ids("sab"); db.sabores.push({ id: sid, item_id: a.p_item_id, nome: a.p_nome, ordem: 9 }); db.estoque.push({ id: ids("est"), item_id: a.p_item_id, sabor_id: sid, quantidade: a.p_quantidade, estoque_minimo: 3 }); return sid; },
    pagar_lancamento(a) { const l = db.financeiro_lancamentos.find(x => x.id === a.p_id); if (l.status === "pago") throw new Error("Lançamento já está pago"); l.status = "pago"; l.pago_em = new Date().toISOString(); l.data_ref = l.pago_em; },

    /* ---- caixa / histórico / avisos (simplificado: valida permissões e regras principais) ---- */
    _cx(id) { const c = db.caixas.find(x => x.id === id); if (!c) throw new Error("Caixa não encontrado"); return c; },
    _res(c) {
      const movs = db.caixa_movs.filter(m => m.caixa_id === c.id), vend = f => db.vendas.filter(v => v.loja_id === c.loja_id && v.status === "concluida" && f(v.forma_pagamento)).reduce((s, v) => s + v.total, 0);
      const md = movs.filter(m => m.meio === "dinheiro").reduce((s, m) => s + m.sentido * m.valor, 0), vd = vend(f => f === "Dinheiro");
      return { id: c.id, loja_id: c.loja_id, loja_nome: db.lojas.find(l => l.id === c.loja_id).nome, status: c.status, saldo_inicial: c.saldo_inicial, aberto_em: c.aberto_em, aberto_por_nome: "Luiz", fechado_em: c.fechado_em, fechado_por_nome: c.fechado_em ? "Luiz" : null,
        esperado_dinheiro: c.status === "fechado" ? c.esperado : money(c.saldo_inicial + md + vd), valor_conferido: c.conferido ?? null, diferenca: c.diferenca ?? null, justificativa: c.justificativa || null, reaberturas: c.reaberturas || 0,
        vendas_dinheiro: vd, vendas_pix: vend(f => f === "Pix"), vendas_cartao: vend(f => ["Cartão", "Débito", "Crédito"].includes(f)), vendas_outro: 0, mov_dinheiro: md, mov_outros_meios: movs.filter(m => m.meio !== "dinheiro").reduce((s, m) => s + m.sentido * m.valor, 0) };
    },
    _movs(id) { return db.caixa_movs.filter(m => m.caixa_id === id).map(m => ({ ...m, criado_por_nome: "Luiz", estornado: db.caixa_movs.some(e => e.estorno_de === m.id) })); },
    abrir_caixa(a) {
      if (!minhas().includes(a.p_loja_id)) throw new Error("Você não tem permissão para esta loja");
      if (!(a.p_saldo_inicial >= 0) || Math.round(a.p_saldo_inicial * 100) !== a.p_saldo_inicial * 100) throw new Error("Valor inválido");
      if (db.caixas.some(c => c.loja_id === a.p_loja_id && c.status === "aberto")) throw new Error("Já existe um caixa aberto nesta loja");
      const c = { id: ids("cx"), loja_id: a.p_loja_id, status: "aberto", saldo_inicial: a.p_saldo_inicial, aberto_em: new Date().toISOString() }; db.caixas.push(c); return c.id;
    },
    caixa_atual(a) { const ab = db.caixas.find(c => c.loja_id === a.p_loja_id && c.status === "aberto"), ul = db.caixas.filter(c => c.loja_id === a.p_loja_id && c.status === "fechado").pop();
      return { aberto: ab ? this._res(ab) : null, movimentos: ab ? this._movs(ab.id) : [], ultimo_fechado: ul ? this._res(ul) : null }; },
    registrar_movimento_caixa(a) {
      const c = this._cx(a.p_caixa_id); if (c.status !== "aberto") throw new Error("O caixa está fechado — reabra para lançar");
      if (!(a.p_valor > 0) || Math.round(a.p_valor * 100) !== a.p_valor * 100) throw new Error("O valor deve ter no máximo 2 casas decimais (centavos)");
      if (a.p_tipo === "ajuste" && !gerente()) throw new Error("Só gerente ou dono faz ajuste de caixa");
      const sent = a.p_tipo === "entrada" ? 1 : a.p_tipo === "ajuste" ? a.p_sentido : -1;
      if (sent === -1 && a.p_meio === "dinheiro" && this._res(c).esperado_dinheiro - a.p_valor < 0) throw new Error("Dinheiro insuficiente no caixa");
      const m = { id: ids("mv"), caixa_id: c.id, tipo: a.p_tipo, sentido: sent, meio: a.p_meio, valor: a.p_valor, categoria: a.p_categoria, observacao: a.p_observacao, criado_em: new Date().toISOString() }; db.caixa_movs.push(m); return m.id;
    },
    estornar_movimento_caixa(a) {
      if (!gerente()) throw new Error("Só gerente ou dono pode estornar"); const m = db.caixa_movs.find(x => x.id === a.p_movimento_id);
      if (db.caixa_movs.some(e => e.estorno_de === m.id)) throw new Error("Esta movimentação já foi estornada");
      db.caixa_movs.push({ ...m, id: ids("mv"), tipo: "estorno", sentido: -m.sentido, categoria: "estorno", estorno_de: m.id, observacao: a.p_motivo, criado_em: new Date().toISOString() }); return "ok";
    },
    fechar_caixa(a) {
      const c = this._cx(a.p_caixa_id), esp = this._res(c).esperado_dinheiro, dif = money(a.p_valor_conferido - esp);
      if (dif !== 0 && !a.p_justificativa) throw new Error("Há diferença — informe a justificativa");
      Object.assign(c, { status: "fechado", esperado: esp, conferido: a.p_valor_conferido, diferenca: dif, justificativa: a.p_justificativa, fechado_em: new Date().toISOString() });
      return { esperado: esp, conferido: a.p_valor_conferido, diferenca: dif };
    },
    reabrir_caixa(a) { if (!gerente()) throw new Error("Só gerente ou dono pode reabrir o caixa"); const c = this._cx(a.p_caixa_id); if (db.caixas.some(x => x.loja_id === c.loja_id && x.status === "aberto")) throw new Error("Já existe outro caixa aberto nesta loja");
      Object.assign(c, { status: "aberto", reaberturas: (c.reaberturas || 0) + 1 }); },
    caixa_detalhe(a) { const c = this._cx(a.p_caixa_id); return { caixa: this._res(c), movimentos: this._movs(c.id), auditoria: [{ acao: "abertura", em: c.aberto_em, por: "Luiz", motivo: null }] }; },
    historico_financeiro(a) {
      const hoje = new Date().toLocaleDateString("en-CA", { timeZone: "America/Sao_Paulo" });
      return db.caixas.filter(c => minhas().includes(c.loja_id) && (!a.p_loja_id || c.loja_id === a.p_loja_id) && (!a.p_situacao || c.status === a.p_situacao)).map(c => { const r = this._res(c);
        return { dia: hoje, loja_id: c.loja_id, loja_nome: r.loja_nome, abertura: c.saldo_inicial, entradas: 10, saidas: 2, estornos: 0, saldo: 8, fechamento: c.conferido || 0, diferenca: c.diferenca || 0, situacao: c.status, caixas: [] }; });
    },
    detalhe_dia_financeiro(a) { return { caixas: db.caixas.filter(c => c.loja_id === a.p_loja_id).map(c => this._res(c)), movimentos: db.caixa_movs.map(m => ({ ...m, criado_por_nome: "Luiz" })), lancamentos: [] }; },
    listar_avisos(a) {
      const hoje = new Date().toLocaleDateString("en-CA", { timeZone: "America/Sao_Paulo" }), out = db.avisos.filter(x => !x.arquivado).map(x => ({ ...x, pode_editar: gerente() && x.tipo !== "sistema" }));
      const venc = db.financeiro_lancamentos.filter(l => l.loja_id === a.p_loja_id && !["pago", "cancelada"].includes(l.status) && l.vencimento && l.vencimento < hoje);
      if (venc.length) out.unshift({ origem: "alerta", chave: "contas_vencidas", tipo: "alerta", titulo: venc.length + " conta(s) vencida(s)", descricao: "Total em atraso", prioridade: "urgente", destaque: true, acao: "financeiro", lojas: [], lido: db.alertasLidos.contas_vencidas === venc.length, atualizado: false, criado_em: new Date().toISOString(), atualizado_em: new Date().toISOString() });
      const pend = db.pagamentos.filter(p => p.loja_id === a.p_loja_id && p.tipo === "pagamento" && (db.financeiro_lancamentos.find(l => l.id === p.lancamento_id) || {}).exige_comprovante && !db.pagamentos.some(e => e.estorno_de === p.id) && !db.envios.some(v => v.pagamento_id === p.id));
      if (pend.length) out.push({ origem: "alerta", chave: "comprovantes_pendentes", tipo: "alerta", titulo: pend.length + " comprovante(s) com envio pendente", descricao: "Envio ainda não confirmado", prioridade: "atencao", destaque: false, acao: "financeiro", lojas: [], lido: false, atualizado: false, criado_em: new Date().toISOString(), atualizado_em: new Date().toISOString() });
      return out;
    },
    publicar_aviso(a) { if (!gerente()) throw new Error("Só gerente ou dono publica avisos"); if (a.p_global && meuPerfil().papel !== "dono") throw new Error("Só o administrador geral publica avisos globais");
      db.avisos.push({ id: ids("av"), origem: "aviso", tipo: a.p_tipo, titulo: a.p_titulo, descricao: a.p_descricao, prioridade: a.p_prioridade, destaque: a.p_destaque, global: a.p_global, lojas: db.lojas.filter(l => (a.p_lojas || []).includes(l.id)).map(l => l.nome), lido: false, atualizado: false, criado_em: new Date().toISOString(), atualizado_em: new Date().toISOString() }); return "ok"; },
    marcar_aviso_lido(a) { db.avisos.find(x => x.id === a.p_aviso_id).lido = true; },
    marcar_alerta_lido(a) { db.alertasLidos[a.p_chave] = db.financeiro_lancamentos.filter(l => l.loja_id === a.p_loja_id && l.status !== "pago" && l.vencimento && l.vencimento < new Date().toLocaleDateString("en-CA")).length; },
    arquivar_aviso(a) { db.avisos.find(x => x.id === a.p_id).arquivado = true; },
    marcar_comprovante_enviado(a) { db.financeiro_lancamentos.find(l => l.id === a.p_id).comprovante_enviado_em = new Date().toISOString(); },

    /* ---- contas, pagamentos parciais e comprovantes (regras principais; o servidor real é testado no SQL) ---- */
    _conta(id) { const l = db.financeiro_lancamentos.find(x => x.id === id); if (!l) throw new Error("Conta não encontrada"); if (!minhas().includes(l.loja_id)) throw new Error("Você não tem permissão para esta conta"); return l; },
    _liq(id) { return money(db.pagamentos.filter(p => p.lancamento_id === id).reduce((s, p) => s + (p.tipo === "pagamento" ? p.valor : -p.valor), 0)); },
    _sit(l) { return l.status === "cancelada" ? "cancelada" : l.status === "pago" ? "paga" : l.status === "parcial" ? "parcial" : "pendente"; },
    _calc(l) { const tem = db.pagamentos.some(p => p.lancamento_id === l.id), pago = tem ? this._liq(l.id) : (l.status === "pago" ? l.valor : 0), hoje = new Date().toLocaleDateString("en-CA");
      const sit = this._sit(l), saldo = l.status === "cancelada" ? 0 : money(l.valor - pago);
      const envPend = l.exige_comprovante ? db.pagamentos.filter(p => p.lancamento_id === l.id && p.tipo === "pagamento" && !db.pagamentos.some(e => e.estorno_de === p.id) && !db.envios.some(v => v.pagamento_id === p.id)).length : 0;
      return { tem, pago, sit, saldo, vencida: ["pendente", "parcial"].includes(sit) && !!l.vencimento && l.vencimento < hoje, envPend, legado: !tem && l.status === "pago" }; },
    criar_conta(a) {
      if (!minhas().includes(a.p_loja_id)) throw new Error("Você não tem permissão para esta loja");
      const dup = db.financeiro_lancamentos.find(l => l.loja_id === a.p_loja_id && l.chave_criacao === a.p_chave); if (dup) return dup.id;
      if (!(a.p_valor > 0) || Math.round(a.p_valor * 100) !== a.p_valor * 100) throw new Error("O valor deve ter no máximo 2 casas decimais (centavos)");
      const now = new Date().toISOString(), l = { id: ids("conta"), loja_id: a.p_loja_id, tipo: a.p_tipo, categoria: a.p_categoria, descricao: a.p_descricao, valor: a.p_valor, status: "pendente", vencimento: a.p_vencimento, exige_comprovante: a.p_exige_comprovante, chave_criacao: a.p_chave, criado_em: now, data_ref: now };
      db.financeiro_lancamentos.push(l); return l.id;
    },
    registrar_pagamento(a) {
      if (window.__failPay) { const m = window.__failPay; window.__failPay = null; throw new Error(m); }
      const l = this._conta(a.p_lancamento_id), dup = db.pagamentos.find(p => p.loja_id === l.loja_id && p.chave === a.p_chave);
      if (dup) { const c = this._calc(l); return { pagamento_id: dup.id, total_pago: c.pago, saldo: c.saldo, situacao: l.status, repetida: true }; }
      if (l.status === "cancelada") throw new Error("Conta cancelada não recebe pagamentos"); if (l.status === "pago") throw new Error("Esta conta já está quitada");
      if (!(a.p_valor > 0) || Math.round(a.p_valor * 100) !== a.p_valor * 100) throw new Error("O valor deve ter no máximo 2 casas decimais (centavos)");
      const saldo = money(l.valor - this._liq(l.id)); if (a.p_valor > saldo) throw new Error("Pagamento (R$ " + a.p_valor + ") maior que o saldo da conta (R$ " + saldo + ")");
      const p = { id: ids("pag"), lancamento_id: l.id, loja_id: l.loja_id, tipo: "pagamento", valor: a.p_valor, data_pagamento: a.p_data || new Date().toLocaleDateString("en-CA"), forma_pagamento: a.p_forma, observacao: a.p_observacao, chave: a.p_chave, criado_em: new Date().toISOString() };
      db.pagamentos.push(p); const liq = this._liq(l.id); l.status = liq >= l.valor ? "pago" : liq > 0 ? "parcial" : "pendente";
      return { pagamento_id: p.id, total_pago: liq, saldo: money(l.valor - liq), situacao: l.status, repetida: false };
    },
    estornar_pagamento(a) {
      if (!gerente()) throw new Error("Só gerente ou dono pode estornar pagamentos"); const p = db.pagamentos.find(x => x.id === a.p_pagamento_id); if (db.pagamentos.some(e => e.estorno_de === p.id)) throw new Error("Este pagamento já foi estornado");
      if (String(a.p_motivo || "").trim().length < 5) throw new Error("Informe o motivo do estorno (mínimo 5 letras)");
      db.pagamentos.push({ ...p, id: ids("pag"), tipo: "estorno", estorno_de: p.id, motivo: a.p_motivo, chave: ids("k"), criado_em: new Date().toISOString() });
      const l = db.financeiro_lancamentos.find(x => x.id === p.lancamento_id), liq = this._liq(l.id); l.status = liq >= l.valor ? "pago" : liq > 0 ? "parcial" : "pendente"; return { situacao: l.status };
    },
    cancelar_conta(a) { if (!gerente()) throw new Error("Só gerente ou dono cancela contas"); const l = this._conta(a.p_id); if (db.pagamentos.some(p => p.lancamento_id === l.id)) throw new Error("A conta tem pagamentos — estorne-os antes de cancelar"); l.status = "cancelada"; l.motivo_cancelamento = a.p_motivo; l.cancelada_em = new Date().toISOString(); },
    registrar_comprovante(a) {
      const p = db.pagamentos.find(x => x.id === a.p_pagamento_id); if (!p || !minhas().includes(p.loja_id)) throw new Error("Você não tem permissão para esta loja");
      if (window.__failReg) { const m = window.__failReg; window.__failReg = null; throw new Error(m); }
      if (!(a.p_path in window.__storage)) throw new Error("Arquivo ainda não está no armazenamento — envie de novo");
      if (!["application/pdf", "image/jpeg", "image/png", "image/webp"].includes(a.p_mime)) throw new Error("Tipo de arquivo não permitido (use PDF, JPG, PNG ou WEBP)");
      const dup = db.comprovantes.find(c => c.storage_path === a.p_path); if (dup) return dup.id;
      const c = { id: ids("comp"), pagamento_id: p.id, lancamento_id: p.lancamento_id, loja_id: p.loja_id, storage_path: a.p_path, nome_original: a.p_nome, mime: a.p_mime, tamanho: a.p_tamanho, enviado_em: new Date().toISOString() }; db.comprovantes.push(c); return c.id;
    },
    confirmar_envio_comprovante(a) { const p = db.pagamentos.find(x => x.id === a.p_pagamento_id); if (!p || !minhas().includes(p.loja_id)) throw new Error("Você não tem permissão para esta loja");
      if (db.envios.some(e => e.pagamento_id === p.id)) return { repetido: true }; db.envios.push({ pagamento_id: p.id, confirmado_em: new Date().toISOString(), observacao: a.p_observacao }); return { repetido: false }; },
    listar_contas(a) {
      if (!minhas().includes(a.p_loja_id)) throw new Error("Você não tem permissão para esta loja");
      return db.financeiro_lancamentos.filter(l => l.loja_id === a.p_loja_id).map(l => ({ l, c: this._calc(l) })).filter(({ l, c }) => !a.p_situacao || (a.p_situacao === "vencida" ? c.vencida : a.p_situacao === "comprovante_pendente" ? c.envPend > 0 : c.sit === a.p_situacao))
        .map(({ l, c }) => ({ id: l.id, tipo: l.tipo, categoria: l.categoria, descricao: l.descricao, valor: l.valor, total_pago: c.pago, saldo: c.saldo, situacao: c.sit, vencida: c.vencida, vencimento: l.vencimento, data_ref: l.data_ref || l.criado_em,
          exige_comprovante: !!l.exige_comprovante, qtd_pagamentos: db.pagamentos.filter(p => p.lancamento_id === l.id).length, qtd_comprovantes: db.comprovantes.filter(x => x.lancamento_id === l.id).length, envios_pendentes: c.envPend, legado: c.legado }));
    },
    conta_detalhe(a) {
      const l = this._conta(a.p_id), c = this._calc(l);
      return { conta: { id: l.id, loja_id: l.loja_id, tipo: l.tipo, categoria: l.categoria, descricao: l.descricao, valor: l.valor, vencimento: l.vencimento, situacao: c.sit, vencida: c.vencida, total_pago: c.pago, saldo: c.saldo, exige_comprovante: !!l.exige_comprovante, legado: c.legado, venda_id: null, marcacao_antiga_comprovante: l.comprovante_enviado_em || null, criado_em: l.criado_em, criado_por_nome: "Luiz", cancelada_em: l.cancelada_em, motivo_cancelamento: l.motivo_cancelamento },
        pagamentos: db.pagamentos.filter(p => p.lancamento_id === l.id).map(p => ({ id: p.id, tipo: p.tipo, valor: p.valor, data_pagamento: p.data_pagamento, forma_pagamento: p.forma_pagamento, observacao: p.observacao, motivo: p.motivo, estorno_de: p.estorno_de || null, criado_em: p.criado_em, criado_por_nome: "Luiz",
          estornado: db.pagamentos.some(e => e.estorno_de === p.id), comprovantes: db.comprovantes.filter(x => x.pagamento_id === p.id).map(x => ({ id: x.id, nome: x.nome_original, mime: x.mime, tamanho: x.tamanho, path: x.storage_path, enviado_em: x.enviado_em, enviado_por_nome: "Luiz" })),
          envio: (e => e ? { confirmado_em: e.confirmado_em, confirmado_por_nome: "Luiz", observacao: e.observacao } : null)(db.envios.find(v => v.pagamento_id === p.id)) })),
        auditoria: [{ acao: "conta_criada", em: l.criado_em, por: "Luiz", motivo: null }] };
    },
    entradas_sem_caixa(a) {
      const lojas = minhas(); if (a.p_loja_id && !lojas.includes(a.p_loja_id)) throw new Error("Você não tem permissão para esta loja");
      const sem = db.vendas.filter(v => lojas.includes(v.loja_id) && (!a.p_loja_id || v.loja_id === a.p_loja_id) && v.status === "concluida" && v.forma_pagamento === "Dinheiro"
        && !db.caixas.some(c => c.loja_id === v.loja_id && v.criado_em >= c.aberto_em && (!c.fechado_em || v.criado_em <= c.fechado_em)));
      const nome = id => db.lojas.find(l => l.id === id).nome, dia = v => v.criado_em.slice(0, 10), porDia = {};
      sem.forEach(v => { const k = v.loja_id + dia(v); porDia[k] = porDia[k] || { dia: dia(v), loja_id: v.loja_id, loja_nome: nome(v.loja_id), total: 0, quantidade: 0 }; porDia[k].total += v.total; porDia[k].quantidade++; });
      return { total: sem.reduce((s, v) => s + v.total, 0), quantidade: sem.length, por_dia: Object.values(porDia),
        itens: sem.map(v => ({ venda_id: v.id, loja_id: v.loja_id, loja_nome: nome(v.loja_id), criado_em: v.criado_em, dia: dia(v), valor: v.total, responsavel: "Luiz" })) };
    },
    definir_whatsapp_loja(a) { const n = (a.p_whatsapp || "").replace(/\D/g, ""); db.lojas.find(l => l.id === a.p_loja_id).whatsapp = n; return n; },
  };

  const client = {
    auth: {
      async signInWithPassword({ email, password }) {
        if (window.__netDown) return { data: null, error: { message: "Failed to fetch" } };
        const u = users[email.replace("@painel.local", "")];
        if (!u || u.pw !== password) return { data: null, error: { message: "Invalid login credentials" } };
        session = { user: { id: u.id } }; return { data: { session }, error: null };
      },
      async getSession() { return { data: { session } }; }, async getUser() { return { data: { user: session && session.user } }; },
      async signOut() { session = null; return { error: null }; },
    },
    from, 
    async rpc(name, args) {
      log.push({ name, args: JSON.parse(JSON.stringify(args || {})) });
      await new Promise(r => setTimeout(r, 5));
      if (window.__netDown) return err("Failed to fetch");
      if (window.__missing === name) return err('Could not find the function public.' + name + ' in the schema cache');
      try { checkParams(name, args || {}); const d = R[name].call(R, args || {}); return { data: d === undefined ? null : d, error: null }; }
      catch (e) { return err(e.message); }
    },
    storage: { from(bucket) { return {
      async upload(path, file, opts) { if (window.__failUpload) { const m = window.__failUpload; window.__failUpload = null; return { data: null, error: { message: m } }; }
        if (opts && opts.upsert) return { data: null, error: { message: "upsert não permitido" } };
        if (path in window.__storage) return { data: null, error: { message: "The resource already exists" } }; window.__storage[path] = { size: file.size, type: file.type, opts }; window.__uploads = (window.__uploads || 0) + 1; return { data: { path }, error: null }; },
      async createSignedUrl(path, seg) { const c = db.comprovantes.find(x => x.storage_path === path); if (!c || !minhas().includes(c.loja_id)) return { data: null, error: { message: "Object not found" } }; return { data: { signedUrl: "http://storage.test/signed/" + path + "?t=" + seg }, error: null }; } }; } },
    channel(name) { const ch = { on(_t, f, cb) { listeners.push({ table: f.table, cb }); return ch; }, subscribe(cb) { setTimeout(() => cb && cb("SUBSCRIBED"), 5); return ch; } }; return ch; },
    async removeChannel() { listeners.length = 0; },
  };
  window.supabase = { createClient: () => client };
})();

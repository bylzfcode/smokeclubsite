#!/usr/bin/env node
/* Limpeza de comprovantes ÓRFÃOS (arquivos no bucket sem vínculo com pagamento). SOMENTE NO SERVIDOR.
 *
 *  SUPABASE_URL=https://<projeto>.supabase.co SUPABASE_SERVICE_KEY=<chave service_role> node limpar_comprovantes_orfaos.js [--apply] [--tolerancia-horas=24] [--limite=100]
 *
 *  - Sem --apply: só LISTA (simulação). Nada é reservado nem apagado.
 *  - Com --apply: reserva no banco (006) e apaga pela API do Storage; registra o resultado em storage_limpeza.
 *  - Nunca toca em arquivos vinculados a pagamentos nem em arquivos mais novos que a tolerância (mínimo 1 h).
 *  - A chave service_role NUNCA deve ir para o navegador, para o dashboard.html nem para o repositório: rode em cron/agendador seguro.
 */
const arg = (n, d) => { const a = process.argv.find(x => x.startsWith("--" + n + "=")); return a ? a.split("=")[1] : d; };
const apply = process.argv.includes("--apply"), horas = Number(arg("tolerancia-horas", "24")), limite = Number(arg("limite", "100"));
const URL = (process.env.SUPABASE_URL || "").replace(/\/$/, ""), KEY = process.env.SUPABASE_SERVICE_KEY || "";
if (!URL || !KEY) { console.error("Defina SUPABASE_URL e SUPABASE_SERVICE_KEY."); process.exit(2); }
if (!(horas >= 1)) { console.error("A tolerância mínima é de 1 hora."); process.exit(2); }
const H = { apikey: KEY, Authorization: "Bearer " + KEY, "Content-Type": "application/json" };
const rpc = async (nome, body) => { const r = await fetch(`${URL}/rest/v1/rpc/${nome}`, { method: "POST", headers: H, body: JSON.stringify(body) }); const t = await r.text(); if (!r.ok) throw new Error(`${nome}: ${r.status} ${t}`); return t ? JSON.parse(t) : null; };
(async () => {
  const tol = `${horas} hours`;
  if (!apply) {
    const l = await rpc("comprovantes_orfaos", { p_tolerancia: tol });
    console.log(`SIMULAÇÃO: ${l.length} arquivo(s) órfão(s) com mais de ${horas} h (nada foi alterado).`); l.forEach(x => console.log("  -", x.caminho_arquivo, x.criado_em_arquivo));
    return;
  }
  const lista = await rpc("reservar_orfaos_comprovantes", { p_tolerancia: tol, p_limite: limite });
  let ok = 0, erro = 0;
  for (const x of lista) {
    const caminho = x.caminho_arquivo, r = await fetch(`${URL}/storage/v1/object/comprovantes/${caminho.split("/").map(encodeURIComponent).join("/")}`, { method: "DELETE", headers: H });
    const bom = r.ok || r.status === 404;        // 404 = já não existe fisicamente
    await rpc("confirmar_remocao_orfao", { p_caminho: caminho, p_ok: bom, p_detalhe: bom ? null : `${r.status} ${(await r.text()).slice(0, 200)}` });
    bom ? ok++ : erro++;
  }
  console.log(`LIMPEZA: ${lista.length} reservado(s), ${ok} removido(s), ${erro} com erro (podem ser repetidos depois).`);
  process.exit(erro ? 1 : 0);
})().catch(e => { console.error(e.message); process.exit(1); });

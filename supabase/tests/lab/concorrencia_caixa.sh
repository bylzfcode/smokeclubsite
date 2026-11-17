#!/bin/bash
# Caixa com sessões SIMULTÂNEAS de verdade (Postgres local). Imprime "TUDO CERTO" se tudo bater.
HERE="$(cd "$(dirname "$0")" && pwd)"
P="sudo -u postgres psql -d lab -At -q"
"$HERE/rebuild_db.sh" >/dev/null 2>&1
LUIZ=$($P -c "select id from auth.users where email='luiz@painel.local'")
loja () { $P -c "select id from lojas where slug='$1'"; }
SMOKE=$(loja smoke-club); START=$(loja start-br01); EZ=$(loja ez-store)
AS="set role authenticated; select set_config('request.jwt.claims','{\"sub\":\"$LUIZ\",\"role\":\"authenticated\"}',false); select set_config('request.jwt.claim.sub','$LUIZ',false);"
FALHAS=0; rm -f /tmp/cx[0-9]_*.txt
conferir () { if [ "$2" = "$3" ]; then echo "   ok  - $1: $2"; else echo "   ERRO - $1: obtido $2, esperado $3"; FALHAS=$((FALHAS+1)); fi; }
largada () { python3 -c "import time;print(time.time()+3)"; }
# $1=instante  $2=comando SQL (uma expressão select) -> imprime OK ou a mensagem de erro
sessao () { $P -c "$AS
select pg_sleep(greatest(0, $1 - extract(epoch from clock_timestamp())));
do \$x\$ begin perform $2; raise notice 'RESULTADO_OK'; exception when others then raise notice 'RESULTADO_ERRO %', sqlerrm; end \$x\$;" 2>&1 | grep -o "RESULTADO_.*" | head -1; }

echo "### 1) 10 sessões abrindo caixa na MESMA loja ao mesmo tempo"
T=$(largada); for i in $(seq 1 10); do sessao $T "abrir_caixa('$SMOKE', 100)" > /tmp/cx1_$i.txt & done; wait
conferir "aberturas que deram certo" "$(cat /tmp/cx1_*.txt | grep -c RESULTADO_OK)" 1
conferir "recusadas por 'já existe caixa aberto'" "$(cat /tmp/cx1_*.txt | grep -c 'Já existe um caixa aberto')" 9
conferir "caixas abertos no banco" "$($P -c "select count(*) from caixas where loja_id='$SMOKE' and status='aberto'")" 1

echo "### 2) 3 lojas diferentes abrindo ao mesmo tempo (devem conviver)"
$P -c "update caixas set status=status where false" >/dev/null
T=$(largada); for l in $START $EZ; do sessao $T "abrir_caixa('$l', 100)" > /tmp/cx2_$l.txt & done; wait
conferir "aberturas em lojas diferentes" "$(cat /tmp/cx2_*.txt | grep -c RESULTADO_OK)" 2

CX=$($P -c "select id from caixas where loja_id='$SMOKE' and status='aberto'")
M=$($P -c "$AS
select registrar_movimento_caixa('$CX','entrada','dinheiro',10,'teste');" | tail -1)

echo "### 3) 8 sessões estornando a MESMA movimentação"
T=$(largada); for i in $(seq 1 8); do sessao $T "estornar_movimento_caixa('$M','duplicado $i')" > /tmp/cx3_$i.txt & done; wait
conferir "estornos aceitos" "$(cat /tmp/cx3_*.txt | grep -c RESULTADO_OK)" 1
conferir "estornos gravados" "$($P -c "select count(*) from caixa_movimentos where estorno_de='$M'")" 1

echo "### 4) 8 sessões tirando R\$ 30 de um caixa com R\$ 100 (nunca pode ficar negativo)"
CXS=$($P -c "select id from caixas where loja_id='$START' and status='aberto'")
T=$(largada); for i in $(seq 1 8); do sessao $T "registrar_movimento_caixa('$CXS','saida','dinheiro',30,'saque')" > /tmp/cx4_$i.txt & done; wait
conferir "saques aceitos (3×30 ≤ 100)" "$(cat /tmp/cx4_*.txt | grep -c RESULTADO_OK)" 3
conferir "esperado final" "$($P -c "select caixa_esperado('$CXS')")" 10.00
conferir "recusados por dinheiro insuficiente" "$(cat /tmp/cx4_*.txt | grep -c 'Dinheiro insuficiente')" 5

echo "### 5) 6 fechamentos simultâneos do mesmo caixa"
T=$(largada); for i in $(seq 1 6); do sessao $T "fechar_caixa('$CXS', 10, null)" > /tmp/cx5_$i.txt & done; wait
conferir "fechamentos aceitos" "$(cat /tmp/cx5_*.txt | grep -c RESULTADO_OK)" 1
conferir "auditorias de fechamento" "$($P -c "select count(*) from caixa_auditoria where caixa_id='$CXS' and acao='fechamento'")" 1

echo "### 6) 12 lançamentos + 1 fechamento ao mesmo tempo (nada pode entrar depois do fechamento)"
CXE=$($P -c "select id from caixas where loja_id='$EZ' and status='aberto'")
T=$(largada); for i in $(seq 1 12); do sessao $T "registrar_movimento_caixa('$CXE','entrada','dinheiro',1,'corrida')" > /tmp/cx6_$i.txt & done
sessao $T "fechar_caixa('$CXE', 100, 'corrida')" > /tmp/cx6_f.txt & wait
$P -c "select 1" >/dev/null
ESP=$($P -c "select esperado_dinheiro from caixas where id='$CXE'"); STATUS=$($P -c "select status from caixas where id='$CXE'")
SOMA=$($P -c "select 100 + coalesce(sum(sentido*valor),0) from caixa_movimentos where caixa_id='$CXE' and meio='dinheiro'")
conferir "caixa terminou fechado (fechamento aceito ou recusado por diferença)" "$STATUS" "$([ "$(cat /tmp/cx6_f.txt)" = "RESULTADO_OK" ] && echo fechado || echo aberto)"
if [ "$STATUS" = "fechado" ]; then conferir "esperado gravado = saldo + todos os movimentos (nenhum entrou depois)" "$ESP" "$SOMA"; fi
echo
[ $FALHAS -eq 0 ] && echo "TUDO CERTO" || echo "FALHAS: $FALHAS"

#!/bin/bash
# Testa vendas SIMULTÂNEAS em sessões paralelas de verdade (Postgres local).
HERE="$(cd "$(dirname "$0")" && pwd)"
uuidgen () { python3 -c "import uuid;print(uuid.uuid4())"; }
P="sudo -u postgres psql -d lab -At -q"
"$HERE/rebuild_db.sh" >/dev/null 2>&1
LUIZ=$($P -c "select id from auth.users where email='luiz@painel.local'")
SMOKE=$($P -c "select id from lojas where slug='smoke-club'")
AS_LUIZ="set role authenticated; select set_config('request.jwt.claims','{\"sub\":\"$LUIZ\",\"role\":\"authenticated\"}',false); select set_config('request.jwt.claim.sub','$LUIZ',false);"

$P -c "$AS_LUIZ
insert into categorias(nome) values ('C');" >/dev/null
SETUP=$($P -c "$AS_LUIZ
with c as (select id from categorias where nome='C')
select 'A=' || criar_item('$SMOKE','produto',null,(select id from c),'Item A',null,null,30,1)
 || ' B=' || criar_item('$SMOKE','produto',null,(select id from c),'Item B',null,null,30,1)
 || ' X=' || criar_item('$SMOKE','produto',null,(select id from c),'Item X',null,null,5,1)
 || ' C=' || criar_item('$SMOKE','produto',null,(select id from c),'Item C',null,null,20,1);" | tail -1)
A=$(echo $SETUP | sed -E 's/.*A=([^ ]+).*/\1/'); B=$(echo $SETUP | sed -E 's/.*B=([^ ]+).*/\1/')
X=$(echo $SETUP | sed -E 's/.*X=([^ ]+).*/\1/'); C=$(echo $SETUP | sed -E 's/.*C=([^ ]+).*/\1/')
$P -c "insert into precos_loja(loja_id,item_id,preco) select '$SMOKE', id, 10 from itens where nome like 'Item %'"

sessao () { # $1=itens json  $2=chave ou vazio  $3=instante de largada
  local T=$3 CH="null"; [ -n "$2" ] && CH="'$2'"
  $P -c "$AS_LUIZ
select pg_sleep(greatest(0, $T - extract(epoch from clock_timestamp())));
select 'OK' from (select registrar_venda('$SMOKE','$1'::jsonb,null,'Pix',0,$CH)) s;" 2>&1 | grep -v "^SET\|^set_config\|^$\|^[0-9a-f-]\{36\}$\|^{" | tr '\n' ' ' ; echo
}
largada () { python3 -c "import time;print(time.time()+4)"; }
FALHAS=0; conferir () { # $1=descrição $2=obtido $3=esperado
  if [ "$2" = "$3" ]; then echo "   ok  - $1: $2"; else echo "   ERRO - $1: obtido $2, esperado $3"; FALHAS=$((FALHAS+1)); fi; }

echo "### 1) 12 sessões vendendo 1 un. de X (estoque 5) ao mesmo tempo"
T=$(largada)
for i in $(seq 1 12); do sessao "[{\"item_id\":\"$X\",\"quantidade\":1}]" "$(uuidgen)" $T > /tmp/conc1_$i.txt & done; wait
conferir "vendas feitas" "$(cat /tmp/conc1_*.txt | grep -c '^OK')" 5
conferir "recusadas por falta de estoque" "$(cat /tmp/conc1_*.txt | grep -c 'Estoque insuficiente')" 7
conferir "estoque final de X" "$($P -c "select quantidade from estoque where item_id='$X'")" 0

echo "### 2) 30 sessões, ordens opostas A,B / B,A (impasse se não houver ordem fixa)"
T=$(largada)
for i in $(seq 1 30); do
  if [ $((i%2)) -eq 0 ]; then J="[{\"item_id\":\"$A\",\"quantidade\":1},{\"item_id\":\"$B\",\"quantidade\":1}]"; else J="[{\"item_id\":\"$B\",\"quantidade\":1},{\"item_id\":\"$A\",\"quantidade\":1}]"; fi
  sessao "$J" "$(uuidgen)" $T > /tmp/conc2_$i.txt & done; wait
conferir "vendas feitas" "$(cat /tmp/conc2_*.txt | grep -c '^OK')" 30
conferir "impasses (deadlock)" "$(cat /tmp/conc2_*.txt | grep -ci deadlock)" 0
conferir "estoque final de A e B" "$($P -c "select quantidade from estoque where item_id='$A'")/$($P -c "select quantidade from estoque where item_id='$B'")" "0/0"

echo "### 3) mesmo envio (mesma chave) por 8 sessões ao mesmo tempo, 2 un. de C"
CH=$(uuidgen); T=$(largada)
for i in $(seq 1 8); do sessao "[{\"item_id\":\"$C\",\"quantidade\":2}]" "$CH" $T > /tmp/conc3_$i.txt & done; wait
conferir "respostas ok" "$(cat /tmp/conc3_*.txt | grep -c '^OK')" 8
conferir "vendas gravadas com a chave" "$($P -c "select count(*) from vendas where chave_idempotencia='$CH'")" 1
conferir "estoque final de C" "$($P -c "select quantidade from estoque where item_id='$C'")" 18

echo "### 4) 6 sessões cancelando a MESMA venda ao mesmo tempo"
VID=$($P -c "$AS_LUIZ
select (registrar_venda('$SMOKE','[{\"item_id\":\"$C\",\"quantidade\":3}]'::jsonb,null,'Pix',0))->>'id';" | tail -1)
conferir "estoque de C depois da venda de 3" "$($P -c "select quantidade from estoque where item_id='$C'")" 15
T=$(largada)
for i in $(seq 1 6); do
  ( $P -c "$AS_LUIZ
select pg_sleep(greatest(0, $T - extract(epoch from clock_timestamp())));
select cancelar_venda('$VID','teste');" >/dev/null 2>&1 ) &
done; wait
conferir "estoque final de C (devolveu UMA vez)" "$($P -c "select quantidade from estoque where item_id='$C'")" 18
conferir "estornos no financeiro dessa venda" "$($P -c "select count(*) from financeiro_lancamentos where venda_id='$VID' and categoria='estorno'")" 1

echo "### CONTAS FINAIS"
conferir "linhas de estoque diferentes da soma dos movimentos" "$($P -c "select count(*) from estoque e where e.quantidade <> coalesce((select sum(quantidade) from estoque_movimentos m where m.estoque_id=e.id),0)")" 0
conferir "estoques negativos" "$($P -c "select count(*) from estoque where quantidade<0")" 0
conferir "vendas concluídas com financeiro diferente do total" "$($P -c "select count(*) from vendas v where status='concluida' and (select coalesce(sum(valor),0) from financeiro_lancamentos f where f.venda_id=v.id and tipo='entrada') <> v.total")" 0
echo; [ $FALHAS -eq 0 ] && echo "TUDO CERTO" || echo "$FALHAS verificação(ões) com ERRO"
exit $FALHAS

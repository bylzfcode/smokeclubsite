#!/bin/bash
# Pagamentos de contas com sessões SIMULTÂNEAS de verdade (Postgres local). Imprime "TUDO CERTO" se tudo bater.
HERE="$(cd "$(dirname "$0")" && pwd)"
P="sudo -u postgres psql -d lab -At -q"
"$HERE/rebuild_db.sh" >/dev/null 2>&1
rm -f /tmp/cp[0-9]_*.txt
LUIZ=$($P -c "select id from auth.users where email='luiz@painel.local'"); SMOKE=$($P -c "select id from lojas where slug='smoke-club'")
AS="set role authenticated; select set_config('request.jwt.claims','{\"sub\":\"$LUIZ\",\"role\":\"authenticated\"}',false); select set_config('request.jwt.claim.sub','$LUIZ',false);"
FALHAS=0
conferir () { if [ "$2" = "$3" ]; then echo "   ok  - $1: $2"; else echo "   ERRO - $1: obtido $2, esperado $3"; FALHAS=$((FALHAS+1)); fi; }
largada () { python3 -c "import time;print(time.time()+3)"; }
uuid () { python3 -c "import uuid;print(uuid.uuid4())"; }
sessao () { $P -c "$AS
select pg_sleep(greatest(0, $1 - extract(epoch from clock_timestamp())));
do \$x\$ begin perform $2; raise notice 'RESULTADO_OK'; exception when others then raise notice 'RESULTADO_ERRO %', sqlerrm; end \$x\$;" 2>&1 | grep -o "RESULTADO_.*" | head -1; }
nova_conta () { $P -c "$AS
select criar_conta('$SMOKE','saida','fornecedor','$1',$2,null,null,false,gen_random_uuid());" | tail -1; }

echo "### 1) 6 sessões criando a MESMA conta (mesma chave)"
K=$(uuid); T=$(largada)
for i in $(seq 1 6); do sessao $T "criar_conta('$SMOKE','saida','x','dup',50,null,null,false,'$K')" > /tmp/cp1_$i.txt & done; wait
conferir "contas gravadas" "$($P -c "select count(*) from financeiro_lancamentos where chave_criacao='$K'")" 1

echo "### 2) 10 sessões pagando R\$ 30 de uma conta de R\$ 100 (chaves diferentes)"
C=$(nova_conta conta100 100); T=$(largada)
for i in $(seq 1 10); do sessao $T "registrar_pagamento('$C',30,null,'Pix',null,'$(uuid)')" > /tmp/cp2_$i.txt & done; wait
conferir "pagamentos aceitos (3 × 30 ≤ 100)" "$(cat /tmp/cp2_*.txt | grep -c RESULTADO_OK)" 3
conferir "recusados por passar do saldo" "$(cat /tmp/cp2_*.txt | grep -c 'maior que o saldo')" 7
conferir "total pago nunca passa de 100" "$($P -c "select coalesce(sum(valor),0) from pagamentos_lancamento where lancamento_id='$C'")" 90.00
conferir "status da conta" "$($P -c "select status from financeiro_lancamentos where id='$C'")" parcial

echo "### 3) 8 sessões pagando o saldo restante (R\$ 10) ao mesmo tempo"
T=$(largada); for i in $(seq 1 8); do sessao $T "registrar_pagamento('$C',10,null,'Pix',null,'$(uuid)')" > /tmp/cp3_$i.txt & done; wait
conferir "só 1 quitação aceita" "$(cat /tmp/cp3_*.txt | grep -c RESULTADO_OK)" 1
conferir "total pago = valor da conta" "$($P -c "select coalesce(sum(valor),0) from pagamentos_lancamento where lancamento_id='$C' and tipo='pagamento'")" 100.00
conferir "conta quitada" "$($P -c "select status from financeiro_lancamentos where id='$C'")" pago

echo "### 4) 8 sessões repetindo a MESMA requisição de pagamento (mesma chave)"
C2=$(nova_conta repeticao 200); K=$(uuid); T=$(largada)
for i in $(seq 1 8); do sessao $T "registrar_pagamento('$C2',80,null,'Pix','dup','$K')" > /tmp/cp4_$i.txt & done; wait
conferir "pagamentos gravados (não duplica)" "$($P -c "select count(*) from pagamentos_lancamento where lancamento_id='$C2'")" 1
conferir "todas as repetições responderam sem erro" "$(cat /tmp/cp4_*.txt | grep -c RESULTADO_OK)" 8
conferir "total pago" "$($P -c "select sum(valor) from pagamentos_lancamento where lancamento_id='$C2'")" 80.00

echo "### 5) 6 sessões estornando o MESMO pagamento"
PG=$($P -c "select id from pagamentos_lancamento where lancamento_id='$C2'")
T=$(largada); for i in $(seq 1 6); do sessao $T "estornar_pagamento('$PG','estorno simultaneo $i')" > /tmp/cp5_$i.txt & done; wait
conferir "estornos aceitos" "$(cat /tmp/cp5_*.txt | grep -c RESULTADO_OK)" 1
conferir "estornos gravados" "$($P -c "select count(*) from pagamentos_lancamento where estorno_de='$PG'")" 1
conferir "conta voltou a pendente" "$($P -c "select status from financeiro_lancamentos where id='$C2'")" pendente

echo "### 6) pagamento e estorno ao mesmo tempo: o status final sempre bate com a soma"
C3=$(nova_conta mistura 100)
$P -c "$AS
select registrar_pagamento('$C3',60,null,'Pix',null,gen_random_uuid());" >/dev/null
PG3=$($P -c "select id from pagamentos_lancamento where lancamento_id='$C3'")
T=$(largada)
sessao $T "estornar_pagamento('$PG3','estorno corrida')" > /tmp/cp6_e.txt &
for i in 1 2 3 4; do sessao $T "registrar_pagamento('$C3',50,null,'Pix',null,'$(uuid)')" > /tmp/cp6_$i.txt & done; wait
LIQ=$($P -c "select sum(case tipo when 'pagamento' then valor else -valor end) from pagamentos_lancamento where lancamento_id='$C3'")
ST=$($P -c "select status from financeiro_lancamentos where id='$C3'")
ESP=$(python3 -c "l=float('$LIQ'); print('pago' if l>=100 else 'parcial' if l>0 else 'pendente')")
conferir "status coerente com o líquido ($LIQ)" "$ST" "$ESP"
conferir "líquido nunca passa do valor da conta" "$(python3 -c "print('sim' if float('$LIQ')<=100 and float('$LIQ')>=0 else 'nao')")" sim

echo
[ $FALHAS -eq 0 ] && echo "TUDO CERTO" || echo "FALHAS: $FALHAS"

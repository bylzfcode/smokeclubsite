#!/bin/bash
# Rateios e reembolsos com sessões SIMULTÂNEAS de verdade (Postgres local). Imprime "TUDO CERTO" se tudo bater.
HERE="$(cd "$(dirname "$0")" && pwd)"
P="sudo -u postgres psql -d lab -At -q"
"$HERE/rebuild_db.sh" >/dev/null 2>&1
rm -f /tmp/cr[0-9]_*.txt
LUIZ=$($P -c "select id from auth.users where email='luiz@painel.local'")
S=$($P -c "select id from lojas where slug='smoke-club'"); T=$($P -c "select id from lojas where slug='start-br01'"); E=$($P -c "select id from lojas where slug='ez-store'")
AS="set role authenticated; select set_config('request.jwt.claims','{\"sub\":\"$LUIZ\",\"role\":\"authenticated\"}',false); select set_config('request.jwt.claim.sub','$LUIZ',false);"
ITENS="'[{\"loja_id\":\"$S\"},{\"loja_id\":\"$T\"},{\"loja_id\":\"$E\"}]'::jsonb"
FALHAS=0
conferir () { if [ "$2" = "$3" ]; then echo "   ok  - $1: $2"; else echo "   ERRO - $1: obtido $2, esperado $3"; FALHAS=$((FALHAS+1)); fi; }
largada () { python3 -c "import time;print(time.time()+3)"; }
uuid () { python3 -c "import uuid;print(uuid.uuid4())"; }
sessao () { $P -c "$AS
select pg_sleep(greatest(0, $1 - extract(epoch from clock_timestamp())));
do \$x\$ begin perform $2; raise notice 'RESULTADO_OK'; exception when others then raise notice 'RESULTADO_ERRO %', sqlerrm; end \$x\$;" 2>&1 | grep -o "RESULTADO_.*" | head -1; }
novo () { $P -c "$AS
select criar_rateio('$1','taxas',900,null,false,'igual',$ITENS,gen_random_uuid());" | tail -1; }
pago () { $P -c "select coalesce(sum(case tipo when 'pagamento' then valor else -valor end),0) from rateio_pagamentos where rateio_id='$1'"; }

echo "### 1) 6 sessões criando o MESMO rateio (mesma chave)"
K=$(uuid); T0=$(largada)
for i in $(seq 1 6); do sessao $T0 "criar_rateio('dup','taxas',900,null,false,'igual',$ITENS,'$K')" > /tmp/cr1_$i.txt & done; wait
conferir "rateios gravados" "$($P -c "select count(*) from rateios where chave_criacao='$K'")" 1
conferir "parcelas gravadas (3 × 300)" "$($P -c "select count(*) from rateio_parcelas p join rateios r on r.id=p.rateio_id where r.chave_criacao='$K' and p.valor=300")" 3

echo "### 2) 10 sessões pagando R\$ 300 de uma despesa de R\$ 900 (chaves diferentes)"
R=$(novo despesa900); T0=$(largada)
for i in $(seq 1 10); do sessao $T0 "registrar_pagamento_rateio('$R','$S',300,null,'Pix',null,'$(uuid)')" > /tmp/cr2_$i.txt & done; wait
conferir "pagamentos aceitos (3 × 300 = 900)" "$(cat /tmp/cr2_*.txt | grep -c RESULTADO_OK)" 3
conferir "recusados (saldo externo/quitada)" "$(cat /tmp/cr2_*.txt | grep -c 'RESULTADO_ERRO')" 7
conferir "total pago ao externo nunca passa de 900" "$(pago $R)" 900.00

echo "### 3) 8 repetições da MESMA requisição de pagamento externo"
R2=$(novo repeticao); K=$(uuid); T0=$(largada)
for i in $(seq 1 8); do sessao $T0 "registrar_pagamento_rateio('$R2','$S',500,null,'Pix','dup','$K')" > /tmp/cr3_$i.txt & done; wait
conferir "pagamentos gravados (não duplica)" "$($P -c "select count(*) from rateio_pagamentos where rateio_id='$R2'")" 1
conferir "todas responderam sem erro" "$(cat /tmp/cr3_*.txt | grep -c RESULTADO_OK)" 8

echo "### 4) 10 reembolsos de R\$ 100 de B (Start) para A (Smoke) — B deve apenas R\$ 300"
$P -c "$AS
select registrar_pagamento_rateio('$R2','$S',400,null,'Pix',null,gen_random_uuid());" >/dev/null     # A quita os 900 (500+400)
T0=$(largada)
for i in $(seq 1 10); do sessao $T0 "registrar_reembolso('$R2','$T','$S',100,null,null,'$(uuid)')" > /tmp/cr4_$i.txt & done; wait
conferir "reembolsos aceitos (B só deve 300)" "$(cat /tmp/cr4_*.txt | grep -c RESULTADO_OK)" 3
conferir "recusados por saldo devido" "$(cat /tmp/cr4_*.txt | grep -c 'saldo devido pela loja de origem')" 7
conferir "posição de B zerada e nunca positiva" "$($P -c "select posicao from rateio_posicoes('$R2') where loja_uuid='$T'")" 0.00
conferir "total pago ao externo continua 900 (reembolso não quita de novo)" "$(pago $R2)" 900.00

echo "### 5) 8 repetições do MESMO reembolso (C → A, R\$ 100)"
K=$(uuid); T0=$(largada)
for i in $(seq 1 8); do sessao $T0 "registrar_reembolso('$R2','$E','$S',100,null,'dup','$K')" > /tmp/cr5_$i.txt & done; wait
conferir "reembolsos gravados" "$($P -c "select count(*) from rateio_reembolsos where rateio_id='$R2' and loja_origem='$E' and valor=100 and tipo='reembolso'")" 1

echo "### 6) 6 estornos simultâneos do MESMO reembolso"
RB=$($P -c "select id from rateio_reembolsos where rateio_id='$R2' and loja_origem='$E' and tipo='reembolso' limit 1")
T0=$(largada); for i in $(seq 1 6); do sessao $T0 "estornar_reembolso('$RB','estorno simultaneo $i')" > /tmp/cr6_$i.txt & done; wait
conferir "estornos aceitos" "$(cat /tmp/cr6_*.txt | grep -c RESULTADO_OK)" 1
conferir "estornos gravados" "$($P -c "select count(*) from rateio_reembolsos where estorno_de='$RB'")" 1

echo "### 7) corrida: estorno do pagamento externo × novo reembolso (o rateio nunca fica incoerente)"
R3=$(novo corrida); PG=$($P -c "$AS
select (registrar_pagamento_rateio('$R3','$S',900,null,'Pix',null,gen_random_uuid())->>'pagamento_id');" | tail -1)
T0=$(largada)
sessao $T0 "estornar_pagamento_rateio('$PG','corrida estorno pagamento')" > /tmp/cr7_e.txt &
for i in 1 2 3; do sessao $T0 "registrar_reembolso('$R3','$T','$S',100,null,null,'$(uuid)')" > /tmp/cr7_$i.txt & done; wait
OK=$($P -c "select 'ok' where not exists (select 1 from rateio_posicoes('$R3') p where (p.reembolso_recebido - p.reembolso_pago) > greatest(0, p.pago_externo - p.parcela) or -(p.reembolso_recebido - p.reembolso_pago) > greatest(0, -(p.pago_externo - p.parcela)))")
conferir "invariante: reembolsos sempre com lastro nos pagamentos externos" "$OK" ok
echo
[ $FALHAS -eq 0 ] && echo "TUDO CERTO" || echo "FALHAS: $FALHAS"

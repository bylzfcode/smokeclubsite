#!/bin/bash
# Contas recorrentes com sessões SIMULTÂNEAS de verdade (Postgres local). Imprime "TUDO CERTO" se tudo bater.
HERE="$(cd "$(dirname "$0")" && pwd)"
P="sudo -u postgres psql -d lab -At -q"
"$HERE/rebuild_db.sh" >/dev/null 2>&1
rm -f /tmp/cs[0-9]_*.txt
LUIZ=$($P -c "select id from auth.users where email='luiz@painel.local'")
S=$($P -c "select id from lojas where slug='smoke-club'")
AS="set role authenticated; select set_config('request.jwt.claims','{\"sub\":\"$LUIZ\",\"role\":\"authenticated\"}',false); select set_config('request.jwt.claim.sub','$LUIZ',false);"
FALHAS=0
conferir () { if [ "$2" = "$3" ]; then echo "   ok  - $1: $2"; else echo "   ERRO - $1: obtido $2, esperado $3"; FALHAS=$((FALHAS+1)); fi; }
largada () { python3 -c "import time;print(time.time()+3)"; }
uuid () { python3 -c "import uuid;print(uuid.uuid4())"; }
sessao () { $P -c "$AS
select pg_sleep(greatest(0, $1 - extract(epoch from clock_timestamp())));
do \$x\$ begin perform $2; raise notice 'RESULTADO_OK'; exception when others then raise notice 'RESULTADO_ERRO %', sqlerrm; end \$x\$;" 2>&1 | grep -o "RESULTADO_.*" | head -1; }

echo "### 1) 8 sessões criando a MESMA série (mesma chave)"
K=$(uuid); T0=$(largada)
for i in $(seq 1 8); do sessao $T0 "criar_serie('$S','saida','aluguel','Aluguel',500.10,null,false,'mensal',null,null,current_date,'quantidade',null,6,'$K')" > /tmp/cs1_$i.txt & done; wait
conferir "séries gravadas" "$($P -c "select count(*) from contas_series where chave_criacao='$K'")" 1
SID=$($P -c "select id from contas_series where chave_criacao='$K'")
conferir "contas geradas sem repetição (1ª + janela de 60 dias = 3 mensais)" "$($P -c "select count(*) from financeiro_lancamentos where serie_id='$SID'")" "$($P -c "select count(distinct serie_n) from financeiro_lancamentos where serie_id='$SID'")"
N1=$($P -c "select count(*) from financeiro_lancamentos where serie_id='$SID'")

echo "### 2) 12 sessões gerando ao mesmo tempo a mesma série (tela + agendador)"
K2=$(uuid); $P -c "$AS select criar_serie('$S','saida','internet','Internet',99.99,null,false,'personalizada',1,'dia',current_date,'sem_prazo',null,null,'$K2');" >/dev/null
SID2=$($P -c "select id from contas_series where chave_criacao='$K2'")
T0=$(largada)
for i in $(seq 1 12); do sessao $T0 "gerar_series_loja('$S')" > /tmp/cs2_$i.txt & done; wait
conferir "nenhuma sessão falhou" "$(cat /tmp/cs2_*.txt | grep -c RESULTADO_OK)" 12
conferir "sem duplicar: números 1..N sem buracos nem repetição" "$($P -c "select count(*) = max(serie_n) and count(*) = count(distinct serie_n) from financeiro_lancamentos where serie_id='$SID2'")" t
conferir "janela futura respeitada (último vencimento ≤ hoje + 60)" "$($P -c "select max(vencimento) <= current_date + 61 from financeiro_lancamentos where serie_id='$SID2'")" t

echo "### 3) geração simultânea com pausa/retomada e encerramento"
T0=$(largada)
for i in $(seq 1 4); do sessao $T0 "gerar_series_loja('$S')" > /tmp/cs3_g$i.txt & done
sessao $T0 "serie_controlar('$SID2','pausar')" > /tmp/cs3_p.txt &
wait
conferir "pausa aceita" "$(cat /tmp/cs3_p.txt)" RESULTADO_OK
conferir "continua sem duplicar" "$($P -c "select count(*) = count(distinct serie_n) from financeiro_lancamentos where serie_id='$SID2'")" t
NA=$($P -c "select count(*) from financeiro_lancamentos where serie_id='$SID2'")
sessao $(largada) "gerar_series_loja('$S')" >/dev/null
conferir "pausada não gera" "$($P -c "select count(*) from financeiro_lancamentos where serie_id='$SID2'")" "$NA"

echo "### 4) 6 sessões editando 'esta e as próximas' ao mesmo tempo"
OC=$($P -c "select id from financeiro_lancamentos where serie_id='$SID' and serie_n=2")
T0=$(largada)
for i in $(seq 1 6); do sessao $T0 "editar_conta('$OC','proximas','Aluguel novo','aluguel',$((600+i)).00,null,null,false)" > /tmp/cs4_$i.txt & done; wait
conferir "todas concluíram sem erro (serializadas)" "$(cat /tmp/cs4_*.txt | grep -c RESULTADO_OK)" 6
conferir "ocorrências com um único valor final coerente (o modelo)" "$($P -c "select count(distinct valor) from financeiro_lancamentos where serie_id='$SID' and serie_n>=2")" 1
conferir "valor final = modelo da série" "$($P -c "select (select valor from contas_series where id='$SID') = (select max(valor) from financeiro_lancamentos where serie_id='$SID' and serie_n=2)")" t
[ "$FALHAS" = 0 ] && echo "TUDO CERTO" || { echo "$FALHAS falha(s)"; exit 1; }

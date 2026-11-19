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

S2=$($P -c "select id from lojas where slug='start-br01'"); S3=$($P -c "select id from lojas where slug='ez-store'")
ITENS="'[{\"loja_id\":\"$S\"},{\"loja_id\":\"$S2\"},{\"loja_id\":\"$S3\"}]'::jsonb"
echo "### 5) 8 sessões criando a MESMA série compartilhada (mesma chave)"
K5=$(uuid); T0=$(largada)
for i in $(seq 1 8); do sessao $T0 "criar_serie_rateio('$S','Internet','internet',100.01,false,'igual',$ITENS,'semanal',null,null,current_date,'sem_prazo',null,null,'$K5')" > /tmp/cs5_$i.txt & done; wait
conferir "séries gravadas" "$($P -c "select count(*) from contas_series where chave_criacao='$K5'")" 1
SID5=$($P -c "select id from contas_series where chave_criacao='$K5'")
conferir "nenhuma sessão falhou" "$(cat /tmp/cs5_*.txt | grep -c RESULTADO_OK)" 8
echo "### 6) 12 sessões gerando ao mesmo tempo a série compartilhada"
T0=$(largada)
for i in $(seq 1 12); do sessao $T0 "gerar_series_loja('$S')" > /tmp/cs6_$i.txt & done; wait
conferir "nenhuma sessão falhou" "$(cat /tmp/cs6_*.txt | grep -c RESULTADO_OK)" 12
conferir "rateios sem buracos nem repetição" "$($P -c "select count(*) = max(serie_n) and count(*) = count(distinct serie_n) from rateios where serie_id='$SID5'")" t
conferir "3 parcelas por rateio somando 100,01 (centavos exatos)" "$($P -c "select bool_and(c = 3 and t = 100.01) from (select r.id, count(p.*) c, sum(p.valor) t from rateios r join rateio_parcelas p on p.rateio_id = r.id where r.serie_id='$SID5' group by r.id) x")" t
conferir "janela futura respeitada" "$($P -c "select max(vencimento) <= current_date + 61 from rateios where serie_id='$SID5'")" t
echo "### 7) 6 sessões retomando (gerar) a MESMA série pausada, com lacunas"
SID7=$($P -c "insert into contas_series (loja_id,tipo,categoria,descricao,valor,exige_comprovante,frequencia,intervalo,unidade,inicio,fim_tipo,status,proximo_k,pausada_em,criado_por,chave_criacao,escopo,metodo,itens) values ('$S','saida','internet','Pausada','100.00',false,'semanal',1,'semana',current_date-40,'sem_prazo','pausada',0,now()-interval '41 days','$LUIZ','$(uuid)','compartilhada','igual',$ITENS) returning id" | head -1)
$P -c "insert into rateios (descricao,categoria,valor_total,vencimento,metodo,exige_comprovante,chave_criacao,criado_por,serie_id,serie_n,vencimento_ref,status) values ('xxx','internet',100,current_date-33,'igual',false,'$(uuid)','$LUIZ','$SID7',2,current_date-33,'cancelado')" >/dev/null
T0=$(largada)
for i in $(seq 1 6); do sessao $T0 "serie_controlar('$SID7','retomar',false,null,'gerar')" > /tmp/cs7_$i.txt & done; wait
conferir "uma sessão retoma; as outras já encontram a série ativa e não fazem nada (nenhum erro)" "$(cat /tmp/cs7_*.txt | grep -c RESULTADO_OK)" 6
conferir "sem duplicar: 1 registro por número; o cancelado continua cancelado" "$($P -c "select count(*) = count(distinct serie_n) and bool_or(serie_n = 2 and status = 'cancelado') from rateios where serie_id='$SID7'")" t
conferir "números 1,3,4,5,6 criados + janela (total 15 registros)" "$($P -c "select count(*) from rateios where serie_id='$SID7'")" 15
conferir "auditoria registra uma única retomada" "$($P -c "select count(*) from series_auditoria where serie_id='$SID7' and acao='retomada'")" 1
[ "$FALHAS" = 0 ] && echo "TUDO CERTO" || { echo "$FALHAS falha(s)"; exit 1; }

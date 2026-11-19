#!/bin/bash
# Valida as consultas SOMENTE LEITURA de supabase/ops contra bancos de teste: completo (001–013), parcial (001–008) e vazio, e prova que nada muda (transação READ ONLY).
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../../.." && pwd)"; P="sudo -u postgres psql -At -q"
FALHAS=0; conferir () { if [ "$2" = "$3" ]; then echo "   ok  - $1"; else echo "   ERRO - $1: obtido [$2], esperado [$3]"; FALHAS=$((FALHAS+1)); fi; }
"$HERE/rebuild_db.sh" >/dev/null 2>&1
ro () { (echo "begin read only;"; cat "$REPO/supabase/ops/$2"; echo "rollback;") | $P -d "$1" -F '|' 2>&1; }
echo "### banco completo (lab)"
R=$(ro lab verificar_migracoes.sql); conferir "13 migrações 'aplicada' (nenhuma parcial/ausente)" "$(echo "$R" | grep -c '|aplicada$')" 13
conferir "executa em transação READ ONLY sem erro" "$(echo "$R" | grep -ci 'error')" 0
C=$(ro lab conferencia_pos_migracao.sql); conferir "conferência pós-migração sem FALHA" "$(echo "$C" | grep -c '|FALHA|')" 0
conferir "conferência sem erro de execução e com as verificações de segurança e do agendador" "$(echo "$C" | grep -ci 'error')/$(echo "$C" | grep -c 'gerar_series_pendentes\|RLS\|anon')" "0/3"
echo "### banco parcial (schema → 008)"
W=/tmp/painel-lab/sql
$P -d postgres -c "drop database if exists lab_parcial with (force);" -c "create database lab_parcial;" >/dev/null
sudo -u postgres psql -q -d lab_parcial -f $W/00_supabase_stub.sql >/dev/null 2>&1   # papéis já existem no cluster: erros esperados e ignorados
for f in schema.sql 002.sql 003.sql 004.sql 05_storage_stub.sql 005.sql 006.sql 007.sql 008.sql; do sudo -u postgres psql -q -v ON_ERROR_STOP=1 -d lab_parcial -f $W/$f >/dev/null 2>&1; done
R=$(ro lab_parcial verificar_migracoes.sql)
conferir "001–008 aplicadas" "$(echo "$R" | grep -E '^(schema|00[2-8])' | grep -c '|aplicada$')" 8
conferir "009–013 ausentes (próxima a aplicar: 009)" "$(echo "$R" | grep -E '^(009|01[0-3])' | grep -c '|ausente$')" 5
C=$(ro lab_parcial conferencia_pos_migracao.sql); conferir "conferência no banco parcial roda sem erro e marca itens futuros como n/a" "$(echo "$C" | grep -ci 'error')/$( [ "$(echo "$C" | grep -c 'n/a')" -ge 5 ] && echo ok)" "0/ok"
conferir "conferência no banco parcial sem FALHA indevida" "$(echo "$C" | grep -c '|FALHA|')" 0
echo "### banco vazio"
$P -d postgres -c "drop database if exists lab_vazio with (force);" -c "create database lab_vazio;" >/dev/null
R=$(ro lab_vazio verificar_migracoes.sql); conferir "banco vazio: tudo 'ausente' e sem erro" "$(echo "$R" | grep -c '|ausente$')/$(echo "$R" | grep -ci 'error')" "13/0"
C=$(ro lab_vazio conferencia_pos_migracao.sql); conferir "conferência no banco vazio roda sem erro" "$(echo "$C" | grep -ci 'error')" 0
echo "### nada foi alterado (somente leitura)"
A=$($P -d lab -c "select (select count(*) from pg_class where relnamespace='public'::regnamespace)||'/'||(select count(*) from pg_proc where pronamespace='public'::regnamespace)")
ro lab verificar_migracoes.sql >/dev/null; ro lab conferencia_pos_migracao.sql >/dev/null
conferir "contagem de objetos do schema public igual antes/depois" "$($P -d lab -c "select (select count(*) from pg_class where relnamespace='public'::regnamespace)||'/'||(select count(*) from pg_proc where pronamespace='public'::regnamespace)")" "$A"
conferir "scripts não contêm comandos de escrita (create/alter/drop/insert/update/delete/grant/revoke)" "$(grep -viE '^\s*--' "$REPO"/supabase/ops/verificar_migracoes.sql "$REPO"/supabase/ops/conferencia_pos_migracao.sql | grep -ciE '\b(create|alter|drop|insert into|update |delete from|grant |revoke |truncate)\b')" 0
$P -d postgres -c "drop database if exists lab_parcial with (force);" -c "drop database if exists lab_vazio with (force);" >/dev/null
[ "$FALHAS" = 0 ] && echo "TUDO CERTO" || { echo "$FALHAS falha(s)"; exit 1; }

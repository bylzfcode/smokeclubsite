#!/bin/bash
# Instalação do ZERO, na ordem documentada, como o papel "postgres" (o mesmo do SQL Editor do Supabase; NÃO é superusuário).
set -e; cd "$(dirname "$0")"; SQL=../..
for f in schema.sql 002_melhorias.sql 003_caixa_avisos.sql 004_entradas_sem_caixa.sql 005_pagamentos_comprovantes.sql 006_limpeza_comprovantes.sql 007_rateios_reembolsos.sql 008_rateios_resumos.sql 009_comunicados.sql 010_acessos.sql 011_recorrencia.sql; do
  echo ">> $f"
  docker compose --env-file .env exec -T db psql -w -q -v ON_ERROR_STOP=1 -U postgres -d postgres < "$SQL/$f" 2>&1 | grep -v "^NOTICE\|^psql:.*NOTICE" || true
  [ "${PIPESTATUS[0]}" = "0" ] || { echo "FALHOU em $f"; exit 1; }
done
docker compose --env-file .env exec -T db psql -w -q -U postgres -d postgres -c "notify pgrst, 'reload schema'" >/dev/null
echo "migrações aplicadas na ordem: schema -> 002 -> 003 -> 004 -> 005 -> 006 -> 007 -> 008 -> 009 -> 010 -> 011"

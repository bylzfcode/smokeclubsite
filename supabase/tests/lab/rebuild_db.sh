#!/bin/bash
# Recria o banco local "lab" do zero: stub do Supabase + schema.sql + 002_melhorias.sql + 003 + 004 + 005 + 006 + 007 + 008 + 009 + 010_acessos + 011_recorrencia + 012_calendario + 013_series_compartilhadas + 014_catalogo_online (com stub de Storage) + usuários.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../../.." && pwd)"
W=/tmp/painel-lab/sql; mkdir -p $W
cp "$HERE"/*.sql $W/ && cp "$REPO/supabase/schema.sql" $W/schema.sql && cp "$REPO/supabase/002_melhorias.sql" $W/002.sql && cp "$REPO/supabase/003_caixa_avisos.sql" $W/003.sql && cp "$REPO/supabase/004_entradas_sem_caixa.sql" $W/004.sql && cp "$REPO/supabase/005_pagamentos_comprovantes.sql" $W/005.sql && cp "$REPO/supabase/006_limpeza_comprovantes.sql" $W/006.sql && cp "$REPO/supabase/007_rateios_reembolsos.sql" $W/007.sql && cp "$REPO/supabase/008_rateios_resumos.sql" $W/008.sql && cp "$REPO/supabase/009_comunicados.sql" $W/009.sql && cp "$REPO/supabase/010_acessos.sql" $W/010.sql && cp "$REPO/supabase/011_recorrencia.sql" $W/011.sql && cp "$REPO/supabase/012_calendario.sql" $W/012.sql && cp "$REPO/supabase/013_series_compartilhadas.sql" $W/013.sql && cp "$REPO/supabase/014_catalogo_online.sql" $W/014.sql
[ -f "$REPO/supabase/tests/banco_testes.sql" ] && cp "$REPO/supabase/tests/banco_testes.sql" $W/banco_testes.sql
chmod -R a+rX /tmp/painel-lab
service postgresql start >/dev/null 2>&1 || true
for i in 1 2 3 4 5 6 7 8; do sudo -u postgres psql -qAt -c "select 1" >/dev/null 2>&1 && break; sleep 1; done
sudo -u postgres psql -q -c "drop database if exists lab with (force);" >/dev/null
sudo -u postgres psql -q -d postgres -c "drop role if exists authenticator;" -c "drop role if exists anon;" -c "drop role if exists authenticated;" -c "drop role if exists service_role;" >/dev/null 2>&1 || true
sudo -u postgres psql -q -c "create database lab;" >/dev/null
sudo -u postgres psql -q -v ON_ERROR_STOP=1 -d lab -f $W/00_supabase_stub.sql >/dev/null
sudo -u postgres psql -q -v ON_ERROR_STOP=1 -d lab -f $W/schema.sql >/dev/null 2>&1
sudo -u postgres psql -q -v ON_ERROR_STOP=1 -d lab -f $W/002.sql >/dev/null 2>&1
sudo -u postgres psql -q -v ON_ERROR_STOP=1 -d lab -f $W/003.sql >/dev/null
sudo -u postgres psql -q -v ON_ERROR_STOP=1 -d lab -f $W/004.sql >/dev/null
sudo -u postgres psql -q -v ON_ERROR_STOP=1 -d lab -f $W/05_storage_stub.sql >/dev/null
sudo -u postgres psql -q -v ON_ERROR_STOP=1 -d lab -f $W/005.sql >/dev/null
sudo -u postgres psql -q -v ON_ERROR_STOP=1 -d lab -f $W/006.sql >/dev/null
sudo -u postgres psql -q -v ON_ERROR_STOP=1 -d lab -f $W/007.sql >/dev/null
sudo -u postgres psql -q -v ON_ERROR_STOP=1 -d lab -f $W/008.sql >/dev/null
sudo -u postgres psql -q -v ON_ERROR_STOP=1 -d lab -f $W/009.sql >/dev/null
sudo -u postgres psql -q -v ON_ERROR_STOP=1 -d lab -f $W/010.sql >/dev/null
sudo -u postgres psql -q -v ON_ERROR_STOP=1 -d lab -f $W/011.sql >/dev/null
sudo -u postgres psql -q -v ON_ERROR_STOP=1 -d lab -f $W/012.sql >/dev/null
sudo -u postgres psql -q -v ON_ERROR_STOP=1 -d lab -f $W/013.sql >/dev/null
sudo -u postgres psql -q -v ON_ERROR_STOP=1 -d lab -f $W/014.sql >/dev/null
sudo -u postgres psql -q -v ON_ERROR_STOP=1 -d lab -f $W/10_seed_users.sql >/dev/null
echo "banco lab pronto"

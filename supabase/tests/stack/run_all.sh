#!/bin/bash
# Sobe a pilha Supabase LOCAL REAL do zero (Docker), instala o banco na ordem correta e roda a validação de API e de navegador.
# Requisitos: Docker (daemon ativo), Node 18+, acesso aos registries de imagens. Uso: ./run_all.sh [--keep]   (--keep deixa a pilha de pé)
set -e; cd "$(dirname "$0")"
DC="docker compose --env-file .env"
pkill -f "node gateway.js" 2>/dev/null || true
[ -f .env ] && $DC down -v >/dev/null 2>&1 || true
node gen_env.js
echo ">> subindo Postgres"; $DC up -d db >/dev/null
for i in $(seq 1 60); do $DC exec -T db psql -w -U postgres -d postgres -Atc "select 1 from pg_roles where rolname='supabase_storage_admin'" 2>/dev/null | grep -q 1 && break; sleep 2; done
sleep 5; ./roles.sh
echo ">> subindo Auth, PostgREST e Storage"; $DC up -d auth rest storage >/dev/null
for i in $(seq 1 60); do $DC exec -T db psql -w -U postgres -d postgres -Atc "select to_regclass('storage.objects') is not null and to_regclass('auth.users') is not null and (select count(*) from information_schema.columns where table_schema='storage' and table_name='buckets' and column_name in ('public','file_size_limit','allowed_mime_types')) = 3 and (select count(*) from information_schema.columns where table_schema='storage' and table_name='objects' and column_name in ('metadata','created_at','owner')) = 3" 2>/dev/null | grep -q t && break; sleep 2; done
(nohup node gateway.js > /tmp/gateway.log 2>&1 &)
./migrar.sh
$DC exec -T db psql -w -q -v ON_ERROR_STOP=1 -U postgres -d postgres < seed_usuarios.sql
[ -d node/node_modules/@supabase ] || (mkdir -p node && cd node && npm init -y >/dev/null 2>&1 && npm i --silent @supabase/supabase-js@2.45.4)
source .env
for i in $(seq 1 60); do c1=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:54321/auth/v1/health -H "apikey: $ANON_KEY"); c2=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:54321/storage/v1/status); c3=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:54321/rest/v1/ -H "apikey: $ANON_KEY"); [ "$c1$c2$c3" = "200200200" ] && break; sleep 2; done
sleep 3
RC=0
echo ">> validação de API (pilha real)"; node real_api.test.js || RC=1
echo ">> validação de rateios e reembolsos (pilha real)"; node real_api_rateios.test.js || RC=1
echo ">> validação dos resumos de rateios (pilha real)"; node real_api_resumos.test.js || RC=1
echo ">> validação de comunicados (pilha real)"; node real_api_comunicados.test.js || RC=1
echo ">> validação de acessos, recorrência e calendário (pilha real)"; node real_api_admin.test.js || RC=1
echo ">> validação de séries compartilhadas e retomada (pilha real)"; node real_api_series_comp.test.js || RC=1
echo ">> validação do catálogo online (pilha real)"; node real_api_catalogo.test.js || RC=1
if [ -f real_ui.test.js ]; then echo ">> validação no navegador (pilha real)"; NODE_PATH=/opt/node22/lib/node_modules node real_ui.test.js || RC=1; fi
if [ -f real_ui_resumos.test.js ]; then echo ">> validação dos resumos de rateios no navegador (pilha real)"; NODE_PATH=/opt/node22/lib/node_modules node real_ui_resumos.test.js || RC=1; fi
if [ -f real_ui_rateios.test.js ]; then echo ">> validação de rateios no navegador (pilha real)"; NODE_PATH=/opt/node22/lib/node_modules node real_ui_rateios.test.js || RC=1; fi
if [ -f real_ui_comunicados.test.js ]; then echo ">> validação de comunicados no navegador (pilha real)"; NODE_PATH=/opt/node22/lib/node_modules node real_ui_comunicados.test.js || RC=1; fi
if [ -f real_ui_admin.test.js ]; then echo ">> validação de acessos, recorrência e calendário no navegador (pilha real)"; NODE_PATH=/opt/node22/lib/node_modules node real_ui_admin.test.js || RC=1; fi
if [ -f real_ui_catalogo.test.js ]; then echo ">> validação do site e da dashboard (catálogo online) no navegador (pilha real)"; NODE_PATH=/opt/node22/lib/node_modules node real_ui_catalogo.test.js || RC=1; fi
[ "$1" = "--keep" ] || { pkill -f "node gateway.js" || true; $DC down >/dev/null 2>&1; }
exit $RC

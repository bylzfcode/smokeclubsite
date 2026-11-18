#!/bin/bash
# Equivale ao "roles.sql" do compose oficial do Supabase: define a senha da pilha nos papéis de serviço.
set -e; cd "$(dirname "$0")"; source .env
docker compose --env-file .env exec -T -e PGPASSWORD="$POSTGRES_PASSWORD" db psql -w -h localhost -v ON_ERROR_STOP=1 -U supabase_admin -d postgres -c "
alter role authenticator with password '$POSTGRES_PASSWORD';
alter role supabase_auth_admin with password '$POSTGRES_PASSWORD';
alter role supabase_storage_admin with password '$POSTGRES_PASSWORD';" >/dev/null
echo "senhas dos papéis de serviço definidas"

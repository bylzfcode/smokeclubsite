// Gera segredos DESCARTÁVEIS (só para esta pilha local de teste) e as chaves JWT anon/service_role (HS256, sem dependências).
const crypto = require("crypto"), fs = require("fs");
const b64 = o => Buffer.from(typeof o === "string" ? o : JSON.stringify(o)).toString("base64url");
const secret = crypto.randomBytes(24).toString("hex");           // 48 caracteres
const jwt = role => { const h = b64({ alg: "HS256", typ: "JWT" }), p = b64({ iss: "supabase-local", role, iat: 1700000000, exp: 2000000000 }); return `${h}.${p}.${crypto.createHmac("sha256", secret).update(`${h}.${p}`).digest("base64url")}`; };
const env = { POSTGRES_PASSWORD: crypto.randomBytes(12).toString("hex"), JWT_SECRET: secret, ANON_KEY: jwt("anon"), SERVICE_KEY: jwt("service_role") };
fs.writeFileSync(__dirname + "/.env", Object.entries(env).map(([k, v]) => `${k}=${v}`).join("\n") + "\n");
console.log(".env gerado (valores descartáveis, não versionados)");

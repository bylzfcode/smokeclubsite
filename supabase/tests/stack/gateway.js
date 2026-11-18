// Mini "Kong": uma porta só (54321) que roteia para os serviços reais, como no Supabase.
const http = require("http");
const rotas = { "/auth/v1": [9999, ""], "/rest/v1": [3000, ""], "/storage/v1": [5000, ""] };
http.createServer((req, res) => {
  const pref = Object.keys(rotas).find(p => req.url.startsWith(p + "/") || req.url === p);
  if (!pref) { res.writeHead(404); return res.end("rota desconhecida"); }
  const [port] = rotas[pref], path = req.url.slice(pref.length) || "/";
  const up = http.request({ host: "127.0.0.1", port, path, method: req.method, headers: { ...req.headers, host: `127.0.0.1:${port}` } }, r => { res.writeHead(r.statusCode, r.headers); r.pipe(res); });
  up.on("error", e => { res.writeHead(502); res.end("gateway: " + e.message); });
  req.pipe(up);
}).listen(54321, "127.0.0.1", () => console.log("gateway em http://127.0.0.1:54321"));

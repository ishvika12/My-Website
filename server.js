const http = require("http");
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

const root = __dirname;
const publicDir = path.join(root, "public");
const dataDir = path.join(root, "data");
const dbPath = path.join(dataDir, "db.json");
const port = process.env.PORT || 8000;

const mime = {
  ".html": "text/html; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".js": "application/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".svg": "image/svg+xml",
  ".pdf": "application/pdf"
};

function ensureDb() {
  if (!fs.existsSync(dataDir)) fs.mkdirSync(dataDir, { recursive: true });
  if (!fs.existsSync(dbPath)) {
    fs.writeFileSync(dbPath, JSON.stringify({
      users: [],
      quizResults: [],
      feedback: [],
      demoBookings: [],
      students: { count: 428, history: [280, 316, 352, 389, 428] }
    }, null, 2));
  }
}

function readDb() {
  ensureDb();
  return JSON.parse(fs.readFileSync(dbPath, "utf8"));
}

function writeDb(db) {
  fs.writeFileSync(dbPath, JSON.stringify(db, null, 2));
}

function send(res, status, body, type = "application/json; charset=utf-8") {
  res.writeHead(status, {
    "Content-Type": type,
    "X-Content-Type-Options": "nosniff",
    "Cache-Control": type.includes("text/html") ? "no-store" : "public, max-age=3600"
  });
  res.end(body);
}

function json(res, status, body) {
  send(res, status, JSON.stringify(body));
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let body = "";
    req.on("data", chunk => {
      body += chunk;
      if (body.length > 1_000_000) {
        reject(new Error("Payload too large"));
        req.destroy();
      }
    });
    req.on("end", () => {
      try {
        resolve(body ? JSON.parse(body) : {});
      } catch {
        reject(new Error("Invalid JSON"));
      }
    });
  });
}

function hashPassword(password, salt = crypto.randomBytes(16).toString("hex")) {
  const hash = crypto.pbkdf2Sync(password, salt, 120000, 64, "sha512").toString("hex");
  return { salt, hash };
}

function safeUser(user) {
  return { id: user.id, name: user.name, email: user.email };
}

function routeFile(req, res) {
  const url = new URL(req.url, `http://${req.headers.host}`);
  let filePath = decodeURIComponent(url.pathname);
  if (filePath === "/") filePath = "/index.html";
  const resolved = path.normalize(path.join(publicDir, filePath));

  if (!resolved.startsWith(publicDir)) {
    send(res, 403, "Forbidden", "text/plain; charset=utf-8");
    return;
  }

  fs.readFile(resolved, (err, data) => {
    if (err) {
      fs.readFile(path.join(publicDir, "404.html"), (notFoundErr, notFound) => {
        send(res, 404, notFoundErr ? "Not found" : notFound, notFoundErr ? "text/plain; charset=utf-8" : mime[".html"]);
      });
      return;
    }
    send(res, 200, data, mime[path.extname(resolved)] || "application/octet-stream");
  });
}

async function handleApi(req, res) {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const db = readDb();

  if (req.method === "GET" && url.pathname === "/api/stats") {
    json(res, 200, {
      studentCount: db.students.count + db.users.length,
      history: db.students.history,
      leaderboard: db.quizResults
        .slice()
        .sort((a, b) => b.score - a.score || new Date(b.createdAt) - new Date(a.createdAt))
        .slice(0, 10),
      testimonials: db.feedback.filter(item => item.rating >= 4).slice(-6)
    });
    return;
  }

  if (req.method === "POST" && url.pathname === "/api/signup") {
    const body = await readBody(req);
    const name = String(body.name || "").trim();
    const email = String(body.email || "").trim().toLowerCase();
    const password = String(body.password || "");
    const confirmPassword = String(body.confirmPassword || "");
    if (!name || !email || password.length < 8 || password !== confirmPassword) {
      json(res, 400, { error: "Please provide a name, valid email, and matching password of at least 8 characters." });
      return;
    }
    if (db.users.some(user => user.email === email)) {
      json(res, 409, { error: "An account already exists for this email." });
      return;
    }
    const passwordHash = hashPassword(password);
    const user = { id: crypto.randomUUID(), name, email, passwordHash, createdAt: new Date().toISOString() };
    db.users.push(user);
    writeDb(db);
    json(res, 201, { user: safeUser(user), redirect: "/welcome.html" });
    return;
  }

  if (req.method === "POST" && url.pathname === "/api/login") {
    const body = await readBody(req);
    const email = String(body.email || "").trim().toLowerCase();
    const password = String(body.password || "");
    const user = db.users.find(item => item.email === email);
    if (!user) {
      json(res, 401, { error: "Invalid email or password." });
      return;
    }
    const attempt = hashPassword(password, user.passwordHash.salt);
    if (attempt.hash !== user.passwordHash.hash) {
      json(res, 401, { error: "Invalid email or password." });
      return;
    }
    json(res, 200, { user: safeUser(user), redirect: "/dashboard.html" });
    return;
  }

  if (req.method === "POST" && url.pathname === "/api/quiz-results") {
    const body = await readBody(req);
    const result = {
      id: crypto.randomUUID(),
      name: String(body.name || "Student").slice(0, 60),
      subject: String(body.subject || "General").slice(0, 40),
      score: Number(body.score || 0),
      total: Number(body.total || 0),
      createdAt: new Date().toISOString()
    };
    db.quizResults.push(result);
    writeDb(db);
    json(res, 201, result);
    return;
  }

  if (req.method === "POST" && url.pathname === "/api/feedback") {
    const body = await readBody(req);
    const item = {
      id: crypto.randomUUID(),
      name: String(body.name || "Parent").slice(0, 60),
      role: String(body.role || "Student").slice(0, 40),
      rating: Math.max(1, Math.min(5, Number(body.rating || 5))),
      comments: String(body.comments || "").slice(0, 600),
      createdAt: new Date().toISOString()
    };
    db.feedback.push(item);
    writeDb(db);
    json(res, 201, item);
    return;
  }

  if (req.method === "POST" && url.pathname === "/api/demo-booking") {
    const body = await readBody(req);
    const booking = {
      id: crypto.randomUUID(),
      name: String(body.name || "").slice(0, 60),
      email: String(body.email || "").slice(0, 120),
      subject: String(body.subject || "Science").slice(0, 40),
      slot: String(body.slot || "").slice(0, 80),
      createdAt: new Date().toISOString()
    };
    db.demoBookings.push(booking);
    writeDb(db);
    json(res, 201, booking);
    return;
  }

  json(res, 404, { error: "API route not found." });
}

const server = http.createServer((req, res) => {
  if (req.url.startsWith("/api/")) {
    handleApi(req, res).catch(error => json(res, 400, { error: error.message }));
    return;
  }
  routeFile(req, res);
});

server.listen(port, () => {
  console.log(`Education site running at http://127.0.0.1:${port}`);
});

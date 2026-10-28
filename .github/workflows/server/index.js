const express = require('express');
const http = require('http');
const fs = require('fs');
const crypto = require('crypto');
const { WebSocketServer } = require('ws');

const FILE = process.env.DATA_FILE || 'data.json';
const PORT = process.env.PORT || 3000;
// حالت آزمایشی: کد تأیید همیشه این است. برای استفاده واقعی به سرویس SMS وصل کنید.
const DEV_CODE = process.env.DEV_CODE || '12345';

let db = { users: [], messages: [] };
if (fs.existsSync(FILE)) db = JSON.parse(fs.readFileSync(FILE, 'utf8'));
const save = () => fs.writeFileSync(FILE, JSON.stringify(db));
const uid = () => crypto.randomBytes(8).toString('hex');
const pub = (u) => ({ id: u.id, name: u.name, phone: u.phone });

const app = express();
app.use(express.json());

const online = new Map(); // userId -> Set<ws>
const push = (userId, data) => {
  (online.get(userId) || new Set()).forEach((w) => w.readyState === 1 && w.send(JSON.stringify(data)));
};

function auth(req, res, next) {
  const t = (req.headers.authorization || '').replace('Bearer ', '');
  const u = db.users.find((x) => x.token === t);
  if (!u) return res.status(401).json({ error: 'نیاز به ورود مجدد' });
  req.user = u;
  next();
}

app.post('/auth/request', (req, res) => {
  if (!req.body.phone) return res.status(400).json({ error: 'شماره تلفن را وارد کنید' });
  res.json({ ok: true, hint: 'حالت آزمایشی: کد ' + DEV_CODE });
});

app.post('/auth/verify', (req, res) => {
  const { phone, code, name } = req.body;
  if (code !== DEV_CODE) return res.status(400).json({ error: 'کد اشتباه است' });
  let u = db.users.find((x) => x.phone === phone);
  if (!u) {
    if (!name) return res.status(400).json({ error: 'نام را وارد کنید' });
    u = { id: uid(), phone, name };
    db.users.push(u);
  }
  u.token = uid() + uid();
  save();
  res.json({ token: u.token, user: pub(u) });
});

app.get('/users', auth, (req, res) => {
  const q = (req.query.q || '').toString().trim();
  res.json(db.users.filter((u) => u.id !== req.user.id && (u.phone.includes(q) || u.name.includes(q))).slice(0, 30).map(pub));
});

app.get('/chats', auth, (req, res) => {
  const me = req.user.id;
  const map = {};
  for (const m of db.messages) {
    if (m.from !== me && m.to !== me) continue;
    const peer = m.from === me ? m.to : m.from;
    const c = map[peer] || (map[peer] = { unread: 0 });
    c.last = m;
    if (m.to === me && m.status !== 'read') c.unread++;
  }
  res.json(Object.entries(map).map(([id, c]) => ({
    peer: pub(db.users.find((u) => u.id === id)), last: c.last, unread: c.unread,
  })).sort((a, b) => b.last.time - a.last.time));
});

app.get('/messages/:peer', auth, (req, res) => {
  const me = req.user.id, p = req.params.peer;
  res.json(db.messages.filter((m) => (m.from === me && m.to === p) || (m.from === p && m.to === me)));
});

const server = http.createServer(app);
const wss = new WebSocketServer({ server, path: '/ws' });

wss.on('connection', (ws, req) => {
  const token = new URL(req.url, 'http://x').searchParams.get('token');
  const user = db.users.find((u) => u.token === token);
  if (!user) return ws.close();
  if (!online.has(user.id)) online.set(user.id, new Set());
  online.get(user.id).add(ws);

  db.messages.filter((m) => m.to === user.id && m.status === 'sent').forEach((m) => {
    m.status = 'delivered';
    push(m.from, { type: 'status', id: m.id, status: 'delivered' });
  });
  save();

  ws.on('message', (raw) => {
    let d; try { d = JSON.parse(raw); } catch { return; }
    if (d.type === 'msg' && d.text && d.to) {
      const m = { id: uid(), from: user.id, to: d.to, text: String(d.text).slice(0, 4000), time: Date.now(), status: 'sent' };
      if (online.has(d.to) && online.get(d.to).size) m.status = 'delivered';
      db.messages.push(m); save();
      push(user.id, { type: 'msg', message: m });
      push(d.to, { type: 'msg', message: m });
    } else if (d.type === 'typing') {
      push(d.to, { type: 'typing', from: user.id });
    } else if (d.type === 'read') {
      db.messages.filter((m) => m.from === d.peer && m.to === user.id && m.status !== 'read').forEach((m) => {
        m.status = 'read';
        push(d.peer, { type: 'status', id: m.id, status: 'read' });
      });
      save();
    }
  });
  ws.on('close', () => online.get(user.id)?.delete(ws));
});

server.listen(PORT, () => console.log('Payam server on :' + PORT));

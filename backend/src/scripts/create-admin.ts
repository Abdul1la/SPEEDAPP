// npm run create-admin -- you@example.com "a long password" [moderator|admin]
//
// Creates the first admin account (or makes an existing account staff and
// sets its password). Then sign in at http://localhost:3000/admin
import { hashPassword } from '../auth/crypto.ts';
import { loadConfig } from '../config.ts';
import { createPool, execute, selectOne } from '../db.ts';
import { runMigrations } from '../migrate.ts';

const [email, password, role = 'admin'] = process.argv.slice(2);
if (!email || !password || !['admin', 'moderator'].includes(role)) {
  console.error('Usage: npm run create-admin -- <email> <password> [admin|moderator]');
  process.exit(1);
}
if (password.length < 10) {
  console.error('Use a password of at least 10 characters for staff accounts.');
  process.exit(1);
}

const config = loadConfig();
await runMigrations(config.databaseUrl);
const db = createPool(config.databaseUrl, 1);
try {
  const clean = email.trim().toLowerCase();
  const hash = await hashPassword(password);
  const existing = await selectOne<{ id: number }>(db, 'SELECT id FROM users WHERE email = ?', [clean]);
  if (existing) {
    await execute(db, "UPDATE users SET role = ?, password_hash = ?, status = 'active' WHERE id = ?", [
      role,
      hash,
      existing.id,
    ]);
    console.log(`${clean} is now ${role} (password updated).`);
  } else {
    await execute(db, 'INSERT INTO users (email, password_hash, role) VALUES (?, ?, ?)', [clean, hash, role]);
    console.log(`Created ${role} ${clean}.`);
  }
} finally {
  await db.end();
}

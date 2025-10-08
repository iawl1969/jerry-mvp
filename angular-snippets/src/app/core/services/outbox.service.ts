import { Injectable } from '@angular/core';
import { DbService } from './db.service';

@Injectable({ providedIn: 'root' })
export class OutboxService {
  constructor(private db: DbService) {}

  async enqueue(method: string, path: string, body: unknown) {
    const id = (globalThis.crypto?.randomUUID?.() ?? Math.random().toString(36).slice(2));
    const now = new Date().toISOString();
    await this.db.run(
      `INSERT INTO sync_outbox(outbox_id, method, path, body_json, created_at) VALUES (?,?,?,?,?)`,
      [id, method, path, JSON.stringify(body ?? null), now]
    );
  }

  async drain(pushFn: (item: { method: string; path: string; body_json: string }) => Promise<void>) {
    const res = await this.db.query(`SELECT outbox_id, method, path, body_json FROM sync_outbox ORDER BY created_at ASC`);
    const rows = (res.values ?? []) as any[];
    for (const r of rows) {
      await pushFn({ method: r.method, path: r.path, body_json: r.body_json });
      await this.db.run(`DELETE FROM sync_outbox WHERE outbox_id = ?`, [r.outbox_id]);
    }
  }
}

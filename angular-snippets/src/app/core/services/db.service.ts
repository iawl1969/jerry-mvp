import { Injectable } from '@angular/core';
import { Capacitor } from '@capacitor/core';
// @ts-ignore
import { CapacitorSQLite, SQLiteDBConnection } from '@capacitor-community/sqlite';

@Injectable({ providedIn: 'root' })
export class DbService {
  private db?: SQLiteDBConnection;

  async init() {
    const sqlite = CapacitorSQLite as any;
    const conn = await sqlite.createConnection({ database: 'jerry', version: 1, encrypted: false });
    this.db = conn;
    await this.db.open();
    await this.db.execute(`PRAGMA foreign_keys = ON;`);
    // Load schema from /assets/schema.sql if available (fetch in web; Filesystem in native)
  }

  async query(sql: string, params: any[] = []) {
    if (!this.db) throw new Error('DB not initialized');
    return this.db.query(sql, params);
  }

  async run(sql: string, params: any[] = []) {
    if (!this.db) throw new Error('DB not initialized');
    return this.db.run(sql, params);
  }
}

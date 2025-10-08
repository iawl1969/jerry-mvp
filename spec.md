# Jerry — MVP Specification (MVP → Phase 2)

**Stack**: Angular 20 · PWA + Capacitor · SQLite (now) → Aurora PostgreSQL Serverless v2 (later) · AWS API Gateway + Lambda · Cognito · S3 · KMS

---

## 0) Problem Statement & Goals

Adult children (caregivers) need a secure, offline-capable app to track aging parents’ medications and critical medical info and to share a **read-only emergency view** via QR code with first responders and clinicians.

**Top goals**
- **Capture & update** meds, allergies, conditions, directives.
- **Emergency access** via tokenized QR exposing only a minimal “ICE” payload.
- **Offline-first** with reliable sync when online, plus auditability and export/backup.
- **Phase 2**: HIPAA-aligned backend on AWS with RBAC and break‑glass logging.

---

## 1) Architecture (MVP → Phase 2)

### MVP (Local-first)
- **Front end**: Angular 20 (standalone components, Signals, Angular Material).
- **Mobile**: Capacitor (Android/iOS) + PWA.
- **Local DB**: SQLite via `@capacitor-community/sqlite`; web fallback via capacitor-web/sql.js.
- **QR**: `qrcode` for generation; `@zxing/browser` for scanning.
- **PDF (optional)**: `pdfmake` to render the Emergency One-Pager.

### Phase 2 (AWS)
- **Auth**: Amazon Cognito.
- **API**: API Gateway + Lambda (TypeScript/Node) or NestJS-on-Lambda (REST/GraphQL).
- **Primary DB**: **Aurora PostgreSQL Serverless v2** (relational integrity, temporal audit, PITR).
- **Storage**: S3 (documents; presigned uploads).
- **Encryption**: KMS for RDS/S3/Secrets.
- **Observability**: CloudWatch/CloudTrail; structured audit events.
- **(Optional)** DynamoDB cache for the read-only Emergency Profile and/or append-only Audit stream.

**Why Postgres?** Strong relational model (meds↔prescriptions↔providers), temporal history, mature migration tooling. HIPAA-eligible managed service with autoscaling.

---

## 2) Roles & Access Model

- **Owner** (parent) — optional if caregiver is legal proxy.
- **Caregiver** — primary authenticated user; CRUD on parent profile.
- **Delegate** — limited caregiver.
- **Guest (clinician)** — invited, time-boxed link; read-only.
- **Emergency Responder** — QR token → minimal ICE payload only.

All accesses are least-privilege and **audited**. Break‑glass reads trigger caregiver-visible log entries.

---

## 3) QR Code Flow (Security-First)

QR encodes a **short-lived opaque token** URL (no PHI in the QR):
```
https://api.jerry.health/emergency?v=1&token=<opaque-id>
```

Server validates token (TTL, nonce, rate limit, optional geo/IP checks) → returns **Emergency Profile** JSON + optional PDF. The printed card can hold a persistent URL, but server enforces freshness by expiring tokens and requiring periodic refresh through the app.

---

## 4) Emergency Profile (ICE payload)

Minimal, life-saving subset only:
- Identity: name, DOB, (photo optional), height/weight
- **Allergies** (reactions, severity)
- **Active medications** (name, strength, route, schedule, last taken)
- **Key conditions** (e.g., anticoagulants, diabetes, implanted devices)
- **Implants/devices** (pacemaker, ports)
- **Code status / advance directives** (link to PDF)
- **Primary physician / pharmacy / emergency contacts**
- **Last updated** timestamp & editor

Everything else is available only to authenticated users with consent.

---

## 5) Data Model (SQLite now, Postgres later)

> SQLite uses `TEXT` for UUIDs and ISO strings for timestamps; Postgres migration converts to `uuid` and `timestamptz`. Use vocab codes (RxNorm, SNOMED/ICD) when available.

```sql
-- === People & Access ===
CREATE TABLE person (
  person_id   TEXT PRIMARY KEY,     -- uuid
  full_name   TEXT NOT NULL,
  dob         TEXT,                 -- ISO date
  sex_at_birth TEXT,
  height_cm   REAL,
  weight_kg   REAL,
  photo_ref   TEXT,                 -- s3 key later
  created_at  TEXT NOT NULL,
  updated_at  TEXT NOT NULL
);

CREATE TABLE user_account (
  user_id     TEXT PRIMARY KEY,
  email       TEXT NOT NULL UNIQUE,
  display_name TEXT,
  created_at  TEXT NOT NULL,
  updated_at  TEXT NOT NULL
);

CREATE TABLE careteam_link (
  person_id   TEXT NOT NULL REFERENCES person(person_id),
  user_id     TEXT NOT NULL REFERENCES user_account(user_id),
  role        TEXT NOT NULL,        -- owner|caregiver|delegate
  permissions TEXT NOT NULL,        -- json
  created_at  TEXT NOT NULL,
  PRIMARY KEY (person_id, user_id)
);

-- === Clinical Core ===
CREATE TABLE condition (
  condition_id TEXT PRIMARY KEY,
  person_id    TEXT NOT NULL REFERENCES person(person_id),
  code_system  TEXT,                -- snomed|icd10
  code         TEXT,
  display      TEXT NOT NULL,
  onset_date   TEXT,
  status       TEXT,                -- active|inactive|resolved
  created_at   TEXT NOT NULL,
  updated_at   TEXT NOT NULL
);

CREATE TABLE allergy (
  allergy_id     TEXT PRIMARY KEY,
  person_id      TEXT NOT NULL REFERENCES person(person_id),
  substance_code TEXT,              -- rxnorm
  substance_name TEXT NOT NULL,
  reaction       TEXT,
  severity       TEXT,              -- mild|moderate|severe
  notes          TEXT,
  created_at     TEXT NOT NULL,
  updated_at     TEXT NOT NULL
);

CREATE TABLE medication (
  medication_id TEXT PRIMARY KEY,
  person_id     TEXT NOT NULL REFERENCES person(person_id),
  rxnorm_code   TEXT,
  generic_name  TEXT NOT NULL,
  brand_name    TEXT,
  form          TEXT,               -- tab|cap|solution
  strength      TEXT,
  route         TEXT,               -- po|iv|sc
  schedule      TEXT,               -- qd|bid or cron-like
  last_taken_at TEXT,
  active        INTEGER NOT NULL DEFAULT 1,
  created_at    TEXT NOT NULL,
  updated_at    TEXT NOT NULL
);

CREATE TABLE prescription (
  prescription_id TEXT PRIMARY KEY,
  medication_id   TEXT NOT NULL REFERENCES medication(medication_id),
  prescriber_id   TEXT,
  sig             TEXT NOT NULL,
  start_date      TEXT,
  end_date        TEXT,
  prn             INTEGER NOT NULL DEFAULT 0,
  last_filled_at  TEXT,
  pharmacy        TEXT,
  created_at      TEXT NOT NULL,
  updated_at      TEXT NOT NULL
);

CREATE TABLE provider (
  provider_id TEXT PRIMARY KEY,
  npi         TEXT,
  name        TEXT NOT NULL,
  org         TEXT,
  phone       TEXT,
  created_at  TEXT NOT NULL,
  updated_at  TEXT NOT NULL
);

CREATE TABLE document (
  document_id TEXT PRIMARY KEY,
  person_id   TEXT NOT NULL REFERENCES person(person_id),
  doc_type    TEXT NOT NULL,        -- directive|insurance|other
  local_path  TEXT,                 -- until S3
  s3_key      TEXT,
  sha256      TEXT,
  uploaded_by TEXT NOT NULL,        -- user_id
  uploaded_at TEXT NOT NULL
);

-- Pre-rendered emergency snapshot
CREATE TABLE emergency_profile (
  person_id    TEXT PRIMARY KEY REFERENCES person(person_id),
  json_payload TEXT NOT NULL,
  generated_at TEXT NOT NULL
);

-- Access grants (tokenized links)
CREATE TABLE access_grant (
  grant_id     TEXT PRIMARY KEY,
  person_id    TEXT NOT NULL REFERENCES person(person_id),
  audience     TEXT NOT NULL,       -- guest|responder
  scope        TEXT NOT NULL,       -- emergency|read-only
  token_opaque TEXT NOT NULL,       -- server-side lookup
  expires_at   TEXT NOT NULL,
  created_by   TEXT NOT NULL,
  created_at   TEXT NOT NULL
);

-- Minimal audit trail (local)
CREATE TABLE audit_event (
  audit_id      TEXT PRIMARY KEY,
  person_id     TEXT,
  entity_type   TEXT NOT NULL,      -- medication, allergy, etc.
  entity_id     TEXT NOT NULL,
  action        TEXT NOT NULL,      -- create|update|delete|read
  actor_user_id TEXT,
  at            TEXT NOT NULL,
  before_json   TEXT,
  after_json    TEXT,
  ip            TEXT,
  user_agent    TEXT
);

-- Offline outbox
CREATE TABLE sync_outbox (
  outbox_id       TEXT PRIMARY KEY,
  method          TEXT NOT NULL,
  path            TEXT NOT NULL,
  body_json       TEXT,
  created_at      TEXT NOT NULL,
  attempts        INTEGER NOT NULL DEFAULT 0,
  last_attempt_at TEXT
);

CREATE INDEX idx_med_person ON medication(person_id);
CREATE INDEX idx_allergy_person ON allergy(person_id);
CREATE INDEX idx_cond_person ON condition(person_id);
CREATE INDEX idx_doc_person ON document(person_id);
CREATE INDEX idx_outbox_created ON sync_outbox(created_at);
```

### Local Audit Triggers (example — medication)
```sql
CREATE TRIGGER trg_med_insert AFTER INSERT ON medication
BEGIN
  INSERT INTO audit_event(
    audit_id, person_id, entity_type, entity_id, action, actor_user_id, at, before_json, after_json
  ) VALUES (
    lower(hex(randomblob(16))), NEW.person_id, 'medication', NEW.medication_id, 'create', NULL, datetime('now'), NULL,
    json_object('medication_id', NEW.medication_id, 'generic_name', NEW.generic_name, 'updated_at', NEW.updated_at)
  );
END;

CREATE TRIGGER trg_med_update AFTER UPDATE ON medication
BEGIN
  INSERT INTO audit_event(
    audit_id, person_id, entity_type, entity_id, action, actor_user_id, at, before_json, after_json
  ) VALUES (
    lower(hex(randomblob(16))), NEW.person_id, 'medication', NEW.medication_id, 'update', NULL, datetime('now'),
    json_object('medication_id', OLD.medication_id, 'generic_name', OLD.generic_name, 'updated_at', OLD.updated_at),
    json_object('medication_id', NEW.medication_id, 'generic_name', NEW.generic_name, 'updated_at', NEW.updated_at)
  );
END;

CREATE TRIGGER trg_med_delete AFTER DELETE ON medication
BEGIN
  INSERT INTO audit_event(
    audit_id, person_id, entity_type, entity_id, action, actor_user_id, at, before_json, after_json
  ) VALUES (
    lower(hex(randomblob(16))), OLD.person_id, 'medication', OLD.medication_id, 'delete', NULL, datetime('now'),
    json_object('medication_id', OLD.medication_id, 'generic_name', OLD.generic_name, 'updated_at', OLD.updated_at),
    NULL
  );
END;
```

---

## 6) API Contract (OpenAPI 3.0 – Phase 2)

```yaml
openapi: 3.0.3
info:
  title: Jerry API
  version: 0.1.0
servers:
  - url: https://api.jerry.health
paths:
  /v1/people:
    post:
      summary: Create a person profile
      requestBody:
        required: true
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/PersonCreate'
      responses:
        '201':
          description: Created
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/Person'
  /v1/people/{personId}:
    get:
      summary: Get person profile (auth required)
      parameters:
        - in: path
          name: personId
          required: true
          schema: { type: string }
      responses:
        '200':
          description: OK
          content:
            application/json:
              schema: { $ref: '#/components/schemas/Person' }
  /v1/people/{personId}/medications:
    post:
      summary: Add medication
      parameters:
        - in: path
          name: personId
          required: true
          schema: { type: string }
      requestBody:
        required: true
        content:
          application/json:
            schema: { $ref: '#/components/schemas/MedicationCreate' }
      responses:
        '201':
          description: Created
          content:
            application/json:
              schema: { $ref: '#/components/schemas/Medication' }
  /v1/emergency:
    get:
      summary: Emergency responder view (tokenized)
      parameters:
        - in: query
          name: token
          required: true
          schema: { type: string }
      responses:
        '200':
          description: Minimal ICE payload
          content:
            application/json:
              schema: { $ref: '#/components/schemas/EmergencyProfile' }
        '401': { description: Invalid or expired token }
components:
  schemas:
    PersonCreate:
      type: object
      required: [full_name]
      properties:
        full_name: { type: string }
        dob: { type: string, format: date }
    Person:
      allOf:
        - $ref: '#/components/schemas/PersonCreate'
        - type: object
          properties:
            person_id: { type: string }
            created_at: { type: string, format: date-time }
            updated_at: { type: string, format: date-time }
    MedicationCreate:
      type: object
      required: [generic_name]
      properties:
        generic_name: { type: string }
        brand_name: { type: string }
        strength: { type: string }
        route: { type: string }
        schedule: { type: string }
    Medication:
      allOf:
        - $ref: '#/components/schemas/MedicationCreate'
        - type: object
          properties:
            medication_id: { type: string }
            person_id: { type: string }
            created_at: { type: string, format: date-time }
            updated_at: { type: string, format: date-time }
    EmergencyProfile:
      type: object
      required: [person_id, allergies, medications, contacts, generated_at]
      properties:
        person_id: { type: string }
        full_name: { type: string }
        dob: { type: string, format: date }
        allergies:
          type: array
          items:
            type: object
            required: [substance_name, severity]
            properties:
              substance_name: { type: string }
              reaction: { type: string }
              severity: { type: string }
        medications:
          type: array
          items:
            type: object
            required: [generic_name, strength, schedule]
            properties:
              generic_name: { type: string }
              brand_name: { type: string }
              strength: { type: string }
              route: { type: string }
              last_taken_at: { type: string, format: date-time }
        contacts:
          type: array
          items:
            type: object
            properties:
              name: { type: string }
              relation: { type: string }
              phone: { type: string }
        code_status: { type: string }
        directive_url: { type: string, format: uri }
        generated_at: { type: string, format: date-time }
```

---

## 7) Angular 20 — Project Skeleton & Key Bits

### Install & Init
```bash
npm create @angular@latest jerry-web -- --routing --style=scss
cd jerry-web

npm i qrcode @zxing/browser
npm i @capacitor/core @capacitor/android @capacitor/ios
npm i @capacitor-community/sqlite
npx cap init Jerry com.jerry.app

# Optional
npm i pdfmake
```

### Suggested Structure
```
src/app/
  core/
    services/
      db.service.ts
      emergency.service.ts
      qr.service.ts
      outbox.service.ts
    guards/
      auth.guard.ts
  features/
    people/
      person-list.component.ts
      person-edit.component.ts
    meds/
      med-list.component.ts
      med-edit.component.ts
    emergency/
      emergency-card.component.ts
      emergency-qr.component.ts
    docs/
      doc-list.component.ts
  shared/
    ui/
    util/
  app.routes.ts
  app.component.ts
```

### SQLite Service (simplified)
```ts
import { Injectable } from '@angular/core';
import { Capacitor } from '@capacitor/core';
// @ts-ignore
import { CapacitorSQLite, SQLiteDBConnection } from '@capacitor-community/sqlite';

@Injectable({ providedIn: 'root' })
export class DbService {
  private db?: SQLiteDBConnection;

  async init() {
    if (Capacitor.isNativePlatform()) {
      const sqlite = CapacitorSQLite as any;
      const conn = await sqlite.createConnection({ database: 'jerry', version: 1, encrypted: false });
      this.db = conn;
      await this.db.open();
      await this.db.execute(`PRAGMA foreign_keys = ON;`);
      // TODO: run schema from assets/schema.sql
    } else {
      const sqlite = CapacitorSQLite as any;
      const conn = await sqlite.createConnection({ database: 'jerry', version: 1, encrypted: false });
      this.db = conn;
      await this.db.open();
      await this.db.execute(`PRAGMA foreign_keys = ON;`);
    }
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
```

### QR Builder
```ts
import { Injectable } from '@angular/core';
import QRCode from 'qrcode';

@Injectable({ providedIn: 'root' })
export class QrService {
  async makeEmergencyUrl(token: string) {
    const url = `https://api.jerry.health/emergency?v=1&token=${encodeURIComponent(token)}`;
    return url;
  }

  async renderToDataUrl(text: string) {
    return QRCode.toDataURL(text, { width: 512, margin: 1 });
  }
}
```

### Emergency QR Component (minimal)
```ts
import { Component, signal, computed } from '@angular/core';
import { QrService } from '../../core/services/qr.service';

@Component({
  selector: 'jerry-emergency-qr',
  standalone: true,
  template: `
    <div class="card">
      <h2>Emergency QR</h2>
      <img *ngIf="qrDataUrl()" [src]="qrDataUrl()!" alt="Emergency QR" />
      <button (click)="regenerate()">Regenerate</button>
    </div>
  `,
  styles: [`.card{padding:1rem;border:1px solid var(--mat-sys-outline);border-radius:12px;}`]
})
export class EmergencyQrComponent {
  private _qr = signal<string | null>(null);
  qrDataUrl = computed(() => this._qr());

  constructor(private qr: QrService) {}

  async regenerate() {
    const bytes = new Uint8Array(16);
    crypto.getRandomValues(bytes);
    const token = Array.from(bytes).map(b => b.toString(16).padStart(2, '0')).join('');
    const url = await this.qr.makeEmergencyUrl(token);
    const dataUrl = await this.qr.renderToDataUrl(url);
    this._qr.set(dataUrl);
  }
}
```

### Seed Data (optional)
```sql
INSERT INTO person(person_id, full_name, dob, created_at, updated_at)
VALUES ('11111111-1111-1111-1111-111111111111','Jane Doe','1942-05-06',datetime('now'),datetime('now'));

INSERT INTO medication(medication_id, person_id, generic_name, brand_name, strength, route, schedule, active, created_at, updated_at)
VALUES (lower(hex(randomblob(16))), '11111111-1111-1111-1111-111111111111','metformin', 'Glucophage', '500 mg', 'po', 'bid', 1, datetime('now'), datetime('now'));

INSERT INTO allergy(allergy_id, person_id, substance_name, reaction, severity, created_at, updated_at)
VALUES (lower(hex(randomblob(16))), '11111111-1111-1111-1111-111111111111','Penicillin','Anaphylaxis','severe',datetime('now'),datetime('now'));
```

---

## 8) Postgres Cutover Checklist

- Convert `TEXT` → `uuid` and timestamps → `timestamptz`.
- Enable **Row Level Security**; policies via `careteam_link`.
- Replace local audit with server-side triggers (e.g., `row_to_json(OLD/NEW)`).
- Rebuild/refresh `emergency_profile` on changes to person/allergy/medication.
- Set up **Cognito**, **API Gateway**, **Lambda**, **RDS**, **S3** (BAA + HIPAA-eligible services only).
- Configure **KMS**, **Secrets Manager**, **CloudWatch/CloudTrail** logging (PHI-aware).

---

## 9) Acceptance Criteria (MVP)

- Caregiver can create a **Person** profile and add **Medications** and **Allergies** offline.
- App can generate and display a **QR code** that resolves to a tokenized emergency URL (stubbed in MVP).
- **Emergency Card** screen shows a minimal ICE payload and supports **print/PDF**.
- All local CRUD operations are appended to **audit_event**.
- **Outbox** records unsent mutations; queue can be drained when online (hook API later).

---

## 10) Definition of Done (MVP)

- SQLite schema initialized on first load; seed data loads successfully.
- Angular routes: `/people`, `/meds`, `/emergency` reachable and functional.
- QR regeneration produces a scannable image; URL format matches Section 3.
- Lint passes; basic unit tests for services; build succeeds for Web + Android.
- Documentation included: this `spec.md` + `assets/schema.sql`.


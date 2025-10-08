-- Jerry MVP Schema (SQLite now, Postgres later)
-- Notes: UUIDs as TEXT, timestamps as ISO-8601 strings. Enable FKs with PRAGMA.
PRAGMA foreign_keys = ON;

-- === People & Access ===
CREATE TABLE IF NOT EXISTS person (
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

CREATE TABLE IF NOT EXISTS user_account (
  user_id     TEXT PRIMARY KEY,
  email       TEXT NOT NULL UNIQUE,
  display_name TEXT,
  created_at  TEXT NOT NULL,
  updated_at  TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS careteam_link (
  person_id   TEXT NOT NULL REFERENCES person(person_id),
  user_id     TEXT NOT NULL REFERENCES user_account(user_id),
  role        TEXT NOT NULL,        -- owner|caregiver|delegate
  permissions TEXT NOT NULL,        -- json
  created_at  TEXT NOT NULL,
  PRIMARY KEY (person_id, user_id)
);

-- === Clinical Core ===
CREATE TABLE IF NOT EXISTS condition (
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

CREATE TABLE IF NOT EXISTS allergy (
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

CREATE TABLE IF NOT EXISTS medication (
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

CREATE TABLE IF NOT EXISTS prescription (
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

CREATE TABLE IF NOT EXISTS provider (
  provider_id TEXT PRIMARY KEY,
  npi         TEXT,
  name        TEXT NOT NULL,
  org         TEXT,
  phone       TEXT,
  created_at  TEXT NOT NULL,
  updated_at  TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS document (
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
CREATE TABLE IF NOT EXISTS emergency_profile (
  person_id    TEXT PRIMARY KEY REFERENCES person(person_id),
  json_payload TEXT NOT NULL,
  generated_at TEXT NOT NULL
);

-- Access grants (tokenized links)
CREATE TABLE IF NOT EXISTS access_grant (
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
CREATE TABLE IF NOT EXISTS audit_event (
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
CREATE TABLE IF NOT EXISTS sync_outbox (
  outbox_id       TEXT PRIMARY KEY,
  method          TEXT NOT NULL,
  path            TEXT NOT NULL,
  body_json       TEXT,
  created_at      TEXT NOT NULL,
  attempts        INTEGER NOT NULL DEFAULT 0,
  last_attempt_at TEXT
);

-- Helpful indexes
CREATE INDEX IF NOT EXISTS idx_med_person ON medication(person_id);
CREATE INDEX IF NOT EXISTS idx_allergy_person ON allergy(person_id);
CREATE INDEX IF NOT EXISTS idx_cond_person ON condition(person_id);
CREATE INDEX IF NOT EXISTS idx_doc_person ON document(person_id);
CREATE INDEX IF NOT EXISTS idx_outbox_created ON sync_outbox(created_at);

-- === Lightweight Audit Triggers (example: medication) ===
CREATE TRIGGER IF NOT EXISTS trg_med_insert AFTER INSERT ON medication
BEGIN
  INSERT INTO audit_event(
    audit_id, person_id, entity_type, entity_id, action, actor_user_id, at, before_json, after_json
  ) VALUES (
    lower(hex(randomblob(16))), NEW.person_id, 'medication', NEW.medication_id, 'create', NULL, datetime('now'), NULL,
    json_object('medication_id', NEW.medication_id, 'generic_name', NEW.generic_name, 'updated_at', NEW.updated_at)
  );
END;

CREATE TRIGGER IF NOT EXISTS trg_med_update AFTER UPDATE ON medication
BEGIN
  INSERT INTO audit_event(
    audit_id, person_id, entity_type, entity_id, action, actor_user_id, at, before_json, after_json
  ) VALUES (
    lower(hex(randomblob(16))), NEW.person_id, 'medication', NEW.medication_id, 'update', NULL, datetime('now'),
    json_object('medication_id', OLD.medication_id, 'generic_name', OLD.generic_name, 'updated_at', OLD.updated_at),
    json_object('medication_id', NEW.medication_id, 'generic_name', NEW.generic_name, 'updated_at', NEW.updated_at)
  );
END;

CREATE TRIGGER IF NOT EXISTS trg_med_delete AFTER DELETE ON medication
BEGIN
  INSERT INTO audit_event(
    audit_id, person_id, entity_type, entity_id, action, actor_user_id, at, before_json, after_json
  ) VALUES (
    lower(hex(randomblob(16))), OLD.person_id, 'medication', OLD.medication_id, 'delete', NULL, datetime('now'),
    json_object('medication_id', OLD.medication_id, 'generic_name', OLD.generic_name, 'updated_at', OLD.updated_at),
    NULL
  );
END;

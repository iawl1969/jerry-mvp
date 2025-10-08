# Jerry MVP Starter

This bundle includes:
- `assets/schema.sql` — SQLite-first schema (Postgres-ready)
- `openapi/jerry.yaml` — Minimal API contract for Phase 2 (AWS)
- `angular-snippets/` — Drop-in Angular 20 snippets (services + Emergency QR component)

## Quick Start (Angular Workspace)

```bash
# 1) Scaffold Angular 20 workspace
npm create @angular@latest jerry-web -- --routing --style=scss
cd jerry-web

# 2) Install libs
npm i qrcode @zxing/browser @capacitor/core @capacitor/android @capacitor/ios @capacitor-community/sqlite

# 3) Copy snippets into your project
#   - src/app/core/services/db.service.ts
#   - src/app/core/services/qr.service.ts
#   - src/app/core/services/outbox.service.ts
#   - src/app/features/emergency/emergency-qr.component.ts

# 4) Add a route to test the QR component (src/app/app.routes.ts)
export const routes: Routes = [
  { path: 'emergency', loadComponent: () => import('./features/emergency/emergency-qr.component').then(m => m.EmergencyQrComponent) },
  { path: '', redirectTo: 'emergency', pathMatch: 'full' }
];

# 5) Put schema.sql somewhere accessible (e.g., src/assets/schema.sql)
#    and load it from DbService on app init (fetch + db.run).
```

## Notes
- DB initialization: on first app run, fetch `/assets/schema.sql` and execute sequentially.
- For native (Android/iOS), read `schema.sql` via Capacitor Filesystem or bundle prepopulated DB.
- API layer: point your future Lambda endpoints to match `openapi/jerry.yaml`.
- Security: do **not** embed PHI in QR codes—use tokenized URLs only.

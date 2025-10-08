import { Component, computed, signal } from '@angular/core';
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
  styles: [`.card{padding:1rem;border:1px solid var(--mat-sys-outline, #ddd);border-radius:12px;}`]
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

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

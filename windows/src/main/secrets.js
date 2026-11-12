// API keys, encrypted with Electron safeStorage (DPAPI on Windows: only this
// Windows user can decrypt them) — the stand-in for the mac Keychain. Stored
// in %APPDATA%\Udha\secrets.json as base64 ciphertext; never in config.json.
'use strict';

const fs = require('fs');
const path = require('path');
const { safeStorage } = require('electron');

const ACCOUNTS = ['elevenlabs_api_key', 'anthropic_api_key'];

class Secrets {
  constructor(dataDir) { this.file = path.join(dataDir, 'secrets.json'); }

  readAll() {
    try { return JSON.parse(fs.readFileSync(this.file, 'utf8')); } catch { return {}; }
  }

  get(account) {
    const enc = this.readAll()[account];
    if (!enc) return null;
    try { return safeStorage.decryptString(Buffer.from(enc, 'base64')); } catch { return null; }
  }

  set(account, value) {
    if (!ACCOUNTS.includes(account) && !/^slack_token:[A-Z0-9]+$/.test(account)) throw new Error('unknown secret');
    const all = this.readAll();
    if (value) {
      if (!safeStorage.isEncryptionAvailable()) throw new Error('Windows encryption is not available');
      all[account] = safeStorage.encryptString(String(value).trim()).toString('base64');
    } else {
      delete all[account];
    }
    fs.writeFileSync(`${this.file}.tmp`, JSON.stringify(all, null, 2));
    fs.renameSync(`${this.file}.tmp`, this.file);
  }

  /** Which keys are set — never the keys themselves. */
  status() {
    const all = this.readAll();
    return Object.fromEntries(ACCOUNTS.map((a) => [a, !!all[a]]));
  }
}

module.exports = { Secrets };

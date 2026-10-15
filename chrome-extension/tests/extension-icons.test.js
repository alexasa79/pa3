const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const manifest = require('../manifest.json');

test('Chrome identifies the extension and its settings as PA3', () => {
  assert.equal(manifest.name, 'PA3');
  assert.equal(manifest.action.default_title, 'PA3');
  assert.equal(manifest.description, 'Read web pages aloud with PA3.');
  assert.equal(manifest.commands['toggle-overlay'].description, 'Toggle PA3 overlays');
  const options = fs.readFileSync(path.join(__dirname, '..', manifest.options_page), 'utf8');
  assert.match(options, /<title>PA3 Settings<\/title>/);
  assert.match(options, /<h1>PA3 Settings<\/h1>/);
  assert.doesNotMatch(options, /Reedah/);
});

test('Chrome uses an exact copy of the canonical menu-bar icon', () => {
  assert.deepEqual(manifest.action.default_icon, manifest.icons);
  assert.deepEqual(Object.keys(manifest.icons), ['16', '32', '48', '128']);
  assert.deepEqual([...new Set(Object.values(manifest.icons))], ['icons/pa3-wave.png']);
  const canonical = fs.readFileSync(path.join(__dirname, '../../Resources/MenuBarIcon.png'));
  for (const file of new Set(Object.values(manifest.icons))) {
    const png = fs.readFileSync(path.join(__dirname, '..', file));
    assert.deepEqual(png, canonical);
    assert.equal(png.subarray(0, 8).toString('hex'), '89504e470d0a1a0a');
    assert.equal(png.toString('ascii', 12, 16), 'IHDR');
    assert.equal(png.readUInt32BE(16), 44);
    assert.equal(png.readUInt32BE(20), 44);
  }
});

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const css = fs.readFileSync(path.join(__dirname, '..', 'content.css'), 'utf8');
const block = selector => {
  const start = css.indexOf(selector + ' {');
  assert.ok(start >= 0, `Missing style: ${selector}`);
  return css.slice(start, css.indexOf('}', start));
};
const rgb = value => value.split(',').map(Number);
const blend = (color, background) => color.slice(0, 3).map((v, i) => v * (color[3] ?? 1) + background[i] * (1 - (color[3] ?? 1)));
const luminance = color => color.reduce((sum, value, i) => {
  const c = value / 255;
  return sum + [0.2126, 0.7152, 0.0722][i] * (c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4);
}, 0);
const contrast = (a, b) => (Math.max(luminance(a), luminance(b)) + 0.05) / (Math.min(luminance(a), luminance(b)) + 0.05);
for (const mode of ['light', 'dark']) {
  test(`Narration text remains readable through sentence and word tints on ${mode} pages`, () => {
    const styles = block(`.reedah-highlight.reedah-highlight-on-${mode}`);
    const base = rgb(styles.match(/--reedah-highlight-base: rgba\(([^)]+)\)/)[1]);
    const focus = rgb(styles.match(/--reedah-word-focus-rgb: ([^;]+)/)[1]);
    const alpha = Number(styles.match(/--reedah-word-focus-opacity: ([^;]+)/)[1]);
    const backgrounds = mode === 'light' ? [[255,255,255],[250,238,221]] : [[0,0,0],[41,43,41]];
    const text = mode === 'light' ? [41,43,41] : [250,238,221];
    for (const background of backgrounds) {
      const sentence = blend(base, background);
      const word = blend([...focus, alpha], sentence);
      assert.ok(contrast(text, sentence) >= 4.5, 'Sentence text contrast');
      assert.ok(contrast(text, word) >= 4.5, 'Focused word text contrast');
      assert.ok(Math.abs(luminance(word) - luminance(sentence)) > 0.04, 'Focused words visibly differ from the sentence');
    }
    for (const kind of ['sentence', 'focus']) {
      const rule = block(`::highlight(reedah-editor-${kind}-${mode})`);
      const color = rgb(rule.match(/rgba?\(([^)]+)\)/)[1]);
      assert.ok(contrast(text, blend(color, backgrounds[0])) >= 4.5, 'Editor highlight text contrast');
    }
  });
}

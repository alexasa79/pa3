const assert = require('node:assert/strict');
const test = require('node:test');
const { speakMathML } = require('../math_narration');
const n = (name, ...children) => ({name, children});
const t = (name, text) => ({name, text, children: []});
const attr = (node, attributes) => ({...node, attributes});
const x = () => t('mi', 'x');
const number = value => t('mn', String(value));

test('MathML semantics reads the presentation once, without TeX or alternative annotations', () => {
  assert.equal(speakMathML(n('math', n('semantics',
    n('mrow', x(), t('mo','≥'), number(0)), t('annotation','x \\geq 0'),
    n('annotation-xml', n('mrow', t('mi','duplicate')))
  ))), 'x is greater than or equal to 0');
});

test('fractions retain numerator/denominator boundaries, including nested fractions', () => {
  const fraction = n('mfrac', n('mrow', x(), t('mo','+'), number(1)),
    n('mfrac', number(2), t('mi','n')));
  assert.equal(speakMathML(fraction), 'fraction x plus 1 over fraction 2 over n end fraction end fraction');
  assert.equal(speakMathML(attr(n('mfrac', number(5), number(2)), {linethickness:'0px'})),
    'stack 5 above 2 end stack');
});

test('powers distinguish a compound base, exponent, subscript, and primes', () => {
  assert.equal(speakMathML(n('msup', x(), number(2))), 'x squared');
  assert.equal(speakMathML(n('msup', x(), number(3))), 'x cubed');
  assert.equal(speakMathML(n('msup', n('mrow', x(), t('mo','+'), number(1)), number(2))),
    'quantity x plus 1 end quantity squared');
  assert.equal(speakMathML(n('msup', x(), n('mrow', t('mi','n'), t('mo','−'), number(1)))),
    'x to the power of n minus 1 end power');
  assert.equal(speakMathML(n('msubsup', x(), t('mi','i'), number(2))),
    'x subscript i end subscript squared');
  assert.equal(speakMathML(n('msup', t('mi','f'), t('mo','′'))), 'f prime');
});

test('square, cube, and indexed roots delimit the radicand', () => {
  assert.equal(speakMathML(n('msqrt', x())), 'square root of x end root');
  assert.equal(speakMathML(n('mroot', x(), number(3))), 'cube root of x end root');
  assert.equal(speakMathML(n('mroot', x(), t('mi','n'))), 'root with index n of x end root');
});

test('sums and integrals retain both limits and following expressions', () => {
  const sum = n('munderover', t('mo','∑'), n('mrow',t('mi','i'),t('mo','='),number(0)), t('mi','n'));
  assert.equal(speakMathML(n('mrow',sum,n('msub',x(),t('mi','i')))),
    'sum from i equals 0 to n x subscript i end subscript');
  assert.equal(speakMathML(n('msubsup',t('mo','∫'),number(0),number(1))), 'integral from 0 to 1');
  assert.equal(speakMathML(attr(n('mover', x(), t('mo','→')), {accent:'true'})), 'vector x');
});

test('matrix/table rows and columns are not flattened together', () => {
  const table=n('mtable', n('mtr',n('mtd',number(1)),n('mtd',number(2))),
    n('mtr',n('mtd',number(3)),n('mtd',number(4))));
  assert.equal(speakMathML(table), 'table; row 1, column 1, 1, column 2, 2; row 2, column 1, 3, column 2, 4; end table');
});

test('fences, separators, Greek letters, and invisible operators have spoken meanings', () => {
  const fenced=attr(n('mfenced',t('mi','α'), t('mi','β')), {open:'[',close:']',separators:';'});
  assert.equal(speakMathML(fenced), 'open bracket alpha semicolon beta close bracket');
  assert.equal(speakMathML(n('mrow',number(2),t('mo','\u2062'),x())), '2 times x');
  assert.equal(speakMathML(n('mrow',t('mi','sin'),t('mo','\u2061'),x())), 'sine of x');
  assert.equal(speakMathML(n('mrow',t('mi','𝑥'),t('mo','∈'),t('mi','ℝ'))), 'x is an element of real numbers');
  assert.equal(speakMathML(t('mi','constructor')), 'constructor');
});

test('spacing, phantom layout, and selected alternatives are handled explicitly', () => {
  assert.equal(speakMathML(n('mrow', x(), n('mspace'), n('mphantom',number(999)))), 'x');
  assert.equal(speakMathML(attr(n('maction', number(1), number(2)), {selection:'2'})), '2');
  assert.equal(speakMathML(n('mtext', t('#text','such that'))), 'such that');
});

test('unsupported or malformed math stops instead of guessing a pronunciation', () => {
  assert.throws(()=>speakMathML(n('menclose',x())), /Unsupported MathML element.*menclose/);
  assert.throws(()=>speakMathML(n('mfrac',x())), /mfrac requires 2/);
  assert.throws(()=>speakMathML(t('mo','☃')), /Unsupported math operator/);
  assert.throws(()=>speakMathML(n('merror',t('mtext','bad input'))), /Math rendering error/);
  assert.throws(()=>speakMathML(n('semantics',t('annotation','x'))), /presentation/);
  let deep=x(); for(let i=0;i<70;i++) deep=n('mrow',deep);
  assert.throws(()=>speakMathML(deep), /too deeply nested/);
});

// A shortcut may only describe a scalar token, never the flattened text of an
// expression. These pairs look identical through textContent but mean different things.
for (const [description, tree, expected] of [
  ['root exponent', n('msup', x(), n('msqrt', number(2))), 'x to the power of square root of 2 end root end power'],
  ['root index', n('mroot', x(), n('msqrt', number(3))), 'root with index square root of 3 end root of x end root'],
  ['identifier exponent', n('msup', x(), t('mi', '2')), 'x to the power of 2 end power'],
  ['fraction exponent', n('msup', x(), n('mfrac', number(1), number(2))), 'x to the power of fraction 1 over 2 end fraction end power'],
  ['negative exponent', n('msup', x(), n('mrow', t('mo', '−'), number(2))), 'x to the power of minus 2 end power'],
  ['decimal exponent', n('msup', x(), number('2.5')), 'x to the power of 2.5 end power'],
  ['double prime', n('msup', x(), t('mo', '″')), 'x double prime'],
  ['plain superscript', attr(n('mover', x(), t('mo', '→')), {accent:'false'}), 'x overscript right arrow end overscript'],
  ['accent with compound content', attr(n('mover', x(), n('msqrt', t('mo', '→'))), {accent:'true'}), 'x overscript square root of right arrow end root end overscript'],
  ['generic underscript', n('munder', x(), number(1)), 'x underscript 1 end underscript'],
  ['generic under and over', n('munderover', x(), number(1), number(2)), 'x underscript 1 end underscript overscript 2 end overscript'],
  ['lower limit', n('msub', t('mo', '∏'), t('mi', 'i')), 'product from i'],
  ['upper limit', n('msup', t('mo', '∑'), t('mi', 'n')), 'sum to n'],
  ['under limit', n('munder', t('mi', 'lim'), n('mrow', x(), t('mo', '→'), number(0))), 'limit from x right arrow 0'],
  ['over limit', n('mover', t('mo', '∫'), number(1)), 'integral to 1'],
  ['text that resembles a limit', n('msub', t('mtext', 'lim'), number(0)), 'quantity lim end quantity subscript 0 end subscript'],
]) {
  test(`structural distinction: ${description}`, () => assert.equal(speakMathML(tree), expected));
}

// Renderer wrappers, indentation, and alternative annotations must not change
// speech. Supplying text on every node also mirrors the DOM serializer.
const wrappers = [
  ['row', node => n('mrow', node)],
  ['style', node => n('mstyle', node)],
  ['padding', node => n('mpadded', node)],
  ['semantics', node => n('semantics', node, t('annotation', 'duplicate TeX'))],
];
function withDOMText(node) {
  const children = (node.children || []).map(withDOMText);
  return {...node, children, text:node.text ?? '\n  '+children.map(child => child.text).join('\n  ')+'\n'};
}
for (const [label, wrap] of wrappers) {
  test(`presentation wrappers preserve powers and limits: ${label}`, () => {
    assert.equal(speakMathML(withDOMText(n('msup', wrap(x()), wrap(number(2))))), 'x squared');
    assert.equal(speakMathML(withDOMText(n('mroot', x(), wrap(number(3))))), 'cube root of x end root');
    assert.equal(speakMathML(withDOMText(n('munderover', wrap(t('mo', '∑')), number(0), t('mi', 'n')))), 'sum from 0 to n');
  });
}

for (const [symbol, phrase] of [['→','vector'],['¯','bar over'],['ˆ','hat over'],['˜','tilde over'],['˙','dot over']]) {
  test(`explicit accent ${symbol}`, () => {
    assert.equal(speakMathML(attr(n('mover', x(), t('mo', symbol)), {accent:'TRUE'})), `${phrase} x`);
  });
}

for (const thickness of ['0', '0px', '0.0em', ' .0pt ', '0rem', '0%', '-1px']) {
  test(`a fraction without a rule is a stack: ${JSON.stringify(thickness)}`, () => {
    assert.equal(speakMathML(attr(n('mfrac', number(5), number(2)), {linethickness:thickness})), 'stack 5 above 2 end stack');
  });
}

test('nonzero and invalid fraction thicknesses retain the fraction rule', () => {
  for (const thickness of [undefined, '1px', '50%', '0.5em', 'invalid', '0bogus']) {
    assert.equal(speakMathML(attr(n('mfrac', number(5), number(2)), {linethickness:thickness})), 'fraction 5 over 2 end fraction');
  }
});

test('fences support empty delimiters, repeated separators, and no separators', () => {
  assert.equal(speakMathML(n('mfenced', x())), 'open parenthesis x close parenthesis');
  assert.equal(speakMathML(attr(n('mfenced', number(1), number(2), number(3), number(4)),
    {open:'', close:'', separators:', ;'})), '1 comma 2 semicolon 3 semicolon 4');
  assert.equal(speakMathML(attr(n('mfenced', x(), t('mi', 'y')), {separators:''})), 'open parenthesis x y close parenthesis');
});

test('labeled, blank, ragged, and nested table cells retain their coordinates', () => {
  assert.equal(speakMathML(n('mtable', n('mlabeledtr', n('mtd', t('mtext', 'A')), n('mtd'), n('mtd', x())),
    n('mtr', n('mtd', number(2))))), 'table; row 1, label A, column 1, blank, column 2, x; row 2, column 1, 2; end table');
  const inner = n('mtable', n('mtr', n('mtd', x())));
  assert.equal(speakMathML(n('mtable', n('mtr', n('mtd', inner)))),
    'table; row 1, column 1, table; row 1, column 1, x; end table; end table');
});

test('invisible operators, Unicode spaces, and selected alternatives preserve content', () => {
  assert.equal(speakMathML(n('mrow', number(1), t('mo','\u2063'), number(2), t('mo','\u2064'), number(3))), '1 comma 2 plus 3');
  assert.equal(speakMathML(t('mtext', '  given\u00a0that\u200b\n x  ')), 'given that x');
  assert.equal(speakMathML(t('ms', 'literal')), 'literal');
  assert.equal(speakMathML(n('maction', x(), n('merror', t('mtext','unused')))), 'x');
});

for (const [label, tree, error] of [
  ['unsupported exponent', n('msup', x(), n('menclose', number(2))), /Unsupported MathML element/],
  ['error index', n('mroot', x(), n('merror', number(3))), /Math rendering error/],
  ['malformed exponent', n('msup', x(), n('mfrac', number(2))), /mfrac requires 2/],
  ['ambiguous semantics', n('semantics', x(), number(2)), /one presentation/],
  ['bad table row', n('mtable', x()), /table row/],
  ['bad table cell', n('mtable', n('mtr', x())), /table cell/],
  ['bad table label', n('mtable', n('mlabeledtr', x(), n('mtd', number(2)))), /table cell/],
  ['merged table cell', n('mtable', n('mtr', attr(n('mtd', x()), {columnspan:'2'}))), /table cell span/],
  ['empty labeled row', n('mtable', n('mlabeledtr')), /table label/],
  ['noninteger selection', attr(n('maction', x()), {selection:'1.5'}), /Invalid MathML selection/],
  ['zero selection', attr(n('maction', x()), {selection:'0'}), /Invalid MathML selection/],
  ['out of bounds selection', attr(n('maction', x()), {selection:'2'}), /Invalid MathML selection/],
  ['invalid node', null, /Invalid MathML node/],
  ['invalid children', {name:'math', children:{}}, /Invalid MathML children/],
  ['structured token', n('msup', x(), n('mn', n('menclose', number(2)))), /Unsupported MathML token contents/],
]) {
  test(`refuses misleading speech: ${label}`, () => assert.throws(() => speakMathML(tree), error));
}

test('all fixed-arity constructs reject missing and extra children', () => {
  for (const [tag, arity] of [['mfrac',2], ['mroot',2], ['msup',2], ['msub',2], ['msubsup',3], ['munder',2], ['mover',2], ['munderover',3]]) {
    for (const size of [arity-1, arity+1]) {
      assert.throws(() => speakMathML(n(tag, ...Array.from({length:size}, x))), new RegExp(`${tag} requires ${arity}`));
    }
  }
});

test('node and depth limits also apply to tables and shortcut operands', () => {
  assert.throws(() => speakMathML(n('mrow', ...Array.from({length:4096}, x))), /too many nodes/);
  assert.throws(() => speakMathML(n('mtable', ...Array.from({length:4096}, () => n('mtr')))), /too many nodes/);
  let deep = number(2);
  for(let i=0;i<70;i++) deep=n('mrow', deep);
  assert.throws(() => speakMathML(n('msup', x(), deep)), /too deeply nested/);
});

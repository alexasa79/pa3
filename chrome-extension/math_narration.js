(() => {
  const ROOT_SELECTOR = '.katex, mjx-container, .MathJax_Display, .MathJax, .MathJax_SVG, .MathJax_CHTML, .mwe-math-element, math';
  const HIDDEN_SELECTOR = "[hidden], .sr-only, .sr-only-focusable, .visually-hidden, .screen-reader-text";
  const METADATA_SELECTOR = 'script, style, annotation, annotation-xml, mjx-assistive-mml, .MJX_Assistive_MathML, .MathJax_Preview';
  const MAX_DEPTH = 64;
  const MAX_NODES = 4096;
  const OPERATORS = {
    '+':'plus', '-':'minus', '−':'minus', '±':'plus or minus', '∓':'minus or plus',
    '*':'times', '×':'times', '⋅':'times', '·':'times', '/':'divided by', '÷':'divided by',
    '=':'equals', '<':'is less than', '>':'is greater than',
    '≤':'is less than or equal to', '≥':'is greater than or equal to',
    '≠':'is not equal to', '≈':'is approximately equal to', '≡':'is equivalent to',
    '∈':'is an element of', '∉':'is not an element of', '⊂':'is a subset of', '⊆':'is a subset of or equal to',
    '∪':'union', '∩':'intersection', '∧':'and', '∨':'or', '¬':'not',
    '∑':'sum', '∏':'product', '∫':'integral', '∬':'double integral', '∮':'contour integral',
    '∞':'infinity', '∂':'partial', '∇':'nabla', '∀':'for all', '∃':'there exists',
    '→':'right arrow', '←':'left arrow', '↔':'left right arrow', '⇒':'implies', '⇔':'if and only if',
    '(':'open parenthesis', ')':'close parenthesis', '[':'open bracket', ']':'close bracket',
    '{':'open brace', '}':'close brace', '|':'vertical bar', '‖':'double vertical bar',
    '⌊':'floor of', '⌋':'end floor', '⌈':'ceiling of', '⌉':'end ceiling',
    ',':'comma', ';':'semicolon', ':':'colon', '.':'dot', '!':'factorial',
    '…':'ellipsis', '⋯':'ellipsis', '′':'prime', '″':'double prime', "'":'prime',
    '¯':'bar', '‾':'bar', '^':'hat', 'ˆ':'hat', '~':'tilde', '˜':'tilde', '˙':'dot',
    '\u2061':'of', '\u2062':'times', '\u2063':'comma', '\u2064':'plus'
  };
  const IDENTIFIERS = {
    α:'alpha', β:'beta', γ:'gamma', δ:'delta', ε:'epsilon', ζ:'zeta', η:'eta', θ:'theta',
    ι:'iota', κ:'kappa', λ:'lambda', μ:'mu', ν:'nu', ξ:'xi', ο:'omicron', π:'pi',
    ρ:'rho', σ:'sigma', τ:'tau', υ:'upsilon', φ:'phi', χ:'chi', ψ:'psi', ω:'omega',
    Γ:'capital gamma', Δ:'capital delta', Θ:'capital theta', Λ:'capital lambda', Ξ:'capital xi',
    Π:'capital pi', Σ:'capital sigma', Φ:'capital phi', Ψ:'capital psi', Ω:'capital omega',
    ℕ:'natural numbers', ℤ:'integers', ℚ:'rational numbers', ℝ:'real numbers', ℂ:'complex numbers',
    sin:'sine', cos:'cosine', tan:'tangent', log:'log', ln:'natural log', lim:'limit',
    min:'minimum', max:'maximum', '∞':'infinity'
  };
  const LARGE_OPERATORS = new Set(['∑','∏','∫','∬','∮','lim']);
  const ACCENTS = {'→':'vector', '¯':'bar over', '‾':'bar over', '^':'hat over', 'ˆ':'hat over', '~':'tilde over', '˜':'tilde over', '˙':'dot over'};
  const clean = text => String(text ?? '').replace(/[\u200b\ufeff]/gu,'').replace(/\s+/gu,' ').trim();
  const nodeText = node => node.text ?? (node.children || []).map(nodeText).join('');
  const presentation = node => (node.children || []).filter(child => !['annotation','annotation-xml'].includes(child.name));
  function unwrap(node) {
    while (['mrow','mstyle','mpadded','semantics'].includes(node.name)) {
      const children = node.name === 'semantics' ? presentation(node) : node.children || [];
      if (children.length !== 1) break;
      node = children[0];
    }
    return node;
  }
  const atomic = node => ['mi','mn','mo','msub','msubsup'].includes(unwrap(node).name);
  const token = (node, names) => {
    const value = unwrap(node);
    return names.includes(value.name) ? clean(nodeText(value)) : null;
  };
  const largeOperator = node => LARGE_OPERATORS.has(token(node, ['mi','mo']));
  function withoutFractionRule(thickness) {
    // MathML Core clamps a negative length to zero. Accept ordinary CSS length
    // units and percentages, including zero written as .0 or with whitespace.
    const match = String(thickness ?? '').trim().match(/^([+-]?(?:\d*\.\d+|\d+)(?:e[+-]?\d+)?)(%|px|em|ex|ch|rem|lh|rlh|cap|ic|vw|vh|vi|vb|vmin|vmax|cm|mm|q|in|pt|pc)?$/i);
    return !!match && Number(match[1]) <= 0 && (!!match[2] || Number(match[1]) === 0);
  }

  // Read presentation structure, rather than its flattened textContent. The tree
  // form keeps the speech rules testable without a browser or third-party code.
  function speakMathML(tree) {
    // Validate the entire tree before shortcuts inspect an operand. This also
    // bounds table rows and token children that the speech traversal can skip.
    let visited = 0;
    function validate(node, depth = 0) {
      if (!node || typeof node.name !== 'string') throw new Error('Invalid MathML node.');
      if (depth > MAX_DEPTH) throw new Error('MathML is too deeply nested.');
      if (++visited > MAX_NODES) throw new Error('MathML contains too many nodes.');
      if (node.children != null && !Array.isArray(node.children)) throw new Error('Invalid MathML children.');
      if (['mi','mn','mo','ms','mtext'].includes(node.name) && node.children?.some(child => child?.name !== '#text')) {
        throw new Error('Unsupported MathML token contents.');
      }
      for (const child of node.children || []) validate(child, depth + 1);
    }
    validate(tree);
    function read(node, depth = 0) {
      const children = node.children || [], attrs = node.attributes || {};
      const child = index => read(children[index], depth + 1);
      const all = () => children.map((_,i) => child(i)).filter(Boolean).join(' ');
      const count = size => {
        if (children.length !== size) throw new Error(`${node.name} requires ${size} children.`);
      };
      const base = () => atomic(children[0]) ? child(0) : `quantity ${child(0)} end quantity`;
      const power = (value, exponent) => {
        const raw = token(exponent, ['mn']);
        if (raw === '2') return `${value} squared`;
        if (raw === '3') return `${value} cubed`;
        const prime = token(exponent, ['mo']);
        if (['′','″',"'"].includes(prime)) return `${value} ${OPERATORS[prime]}`;
        return `${value} to the power of ${read(exponent, depth + 1)} end power`;
      };
      switch (node.name) {
        case 'math': case 'mrow': case 'mstyle': case 'mpadded': return all();
        case 'mtd':
          if (['rowspan','columnspan'].some(key => attrs[key] != null && attrs[key] !== '1')) {
            throw new Error('Unsupported MathML table cell span.');
          }
          return all();
        case 'mi': {
          const raw = clean(nodeText(node)), normalized = raw.normalize('NFKC');
          return Object.hasOwn(IDENTIFIERS,raw) ? IDENTIFIERS[raw]
            : Object.hasOwn(IDENTIFIERS,normalized) ? IDENTIFIERS[normalized] : normalized;
        }
        case 'mn': case 'mtext': case 'ms': return clean(nodeText(node));
        case 'mo': {
          const raw = clean(nodeText(node));
          if (!raw) return '';
          if (!Object.hasOwn(OPERATORS, raw)) throw new Error(`Unsupported math operator: ${raw}`);
          return OPERATORS[raw];
        }
        case 'semantics': {
          const content = presentation(node);
          if (content.length !== 1) throw new Error('MathML semantics requires one presentation.');
          return read(content[0], depth + 1);
        }
        case 'annotation': case 'annotation-xml': case 'mspace': case 'mphantom': return '';
        case 'mfrac':
          count(2);
          return withoutFractionRule(attrs.linethickness)
            ? `stack ${child(0)} above ${child(1)} end stack`
            : `fraction ${child(0)} over ${child(1)} end fraction`;
        case 'msqrt': return `square root of ${all()} end root`;
        case 'mroot': {
          count(2);
          const index = token(children[1], ['mn']);
          const label = index === '2' ? 'square root' : index === '3' ? 'cube root' : `root with index ${child(1)}`;
          return `${label} of ${child(0)} end root`;
        }
        case 'msup':
          count(2);
          return largeOperator(children[0]) ? `${child(0)} to ${child(1)}` : power(base(), children[1]);
        case 'msub':
          count(2);
          return largeOperator(children[0])
            ? `${child(0)} from ${child(1)}` : `${base()} subscript ${child(1)} end subscript`;
        case 'msubsup':
          count(3);
          return largeOperator(children[0])
            ? `${child(0)} from ${child(1)} to ${child(2)}`
            : power(`${base()} subscript ${child(1)} end subscript`, children[2]);
        case 'munder': case 'mover': case 'munderover': {
          count(node.name === 'munderover' ? 3 : 2);
          const large = largeOperator(children[0]);
          if (node.name === 'munderover') return large ? `${child(0)} from ${child(1)} to ${child(2)}`
            : `${base()} underscript ${child(1)} end underscript overscript ${child(2)} end overscript`;
          const accent = token(children[1], ['mo']);
          if (node.name === 'mover' && attrs.accent?.toLowerCase() === 'true') {
            if (Object.hasOwn(ACCENTS,accent)) return `${ACCENTS[accent]} ${base()}`;
          }
          const lower = node.name === 'munder';
          return large ? `${child(0)} ${lower ? 'from' : 'to'} ${child(1)}`
            : `${base()} ${lower ? 'underscript' : 'overscript'} ${child(1)} end ${lower ? 'underscript' : 'overscript'}`;
        }
        case 'mfenced': {
          const separator = [...(attrs.separators ?? ',').replace(/\s/gu,'')];
          const operator = text => text ? read({name:'mo',text}, depth + 1) : '';
          const parts = [operator(attrs.open ?? '(')];
          children.forEach((item,i) => {
            if (i && separator.length) parts.push(operator(separator[Math.min(i-1,separator.length-1)]));
            parts.push(child(i));
          });
          parts.push(operator(attrs.close ?? ')'));
          return parts.filter(Boolean).join(' ');
        }
        case 'mtable':
          return `table; ${children.map((row,i) => {
            if (!['mtr','mlabeledtr'].includes(row.name)) throw new Error('Unsupported MathML table row.');
            let cells = row.children || [], label = '';
            if (cells.some(cell => cell.name !== 'mtd')) throw new Error('Unsupported MathML table cell.');
            if (row.name === 'mlabeledtr') {
              if (!cells.length) throw new Error('Missing MathML table label.');
              label = `, label ${read(cells[0],depth+2) || 'blank'}`;
              cells = cells.slice(1);
            }
            return `row ${i+1}${label}, ${cells.map((cell,j) => {
              return `column ${j+1}, ${read(cell,depth+2) || 'blank'}`;
            }).join(', ')}`;
          }).join('; ')}; end table`;
        case 'maction': {
          const selection = Number(attrs.selection ?? 1);
          if (!Number.isInteger(selection) || selection < 1 || selection > children.length) throw new Error('Invalid MathML selection.');
          return child(selection - 1);
        }
        case 'merror': throw new Error(`Math rendering error: ${clean(nodeText(node))}`);
        default: throw new Error(`Unsupported MathML element: ${node.name}`);
      }
    }
    return clean(read(tree));
  }

  function mathMLTree(element) {
    let visited = 0;
    function copy(el, depth) {
      if (depth > MAX_DEPTH || ++visited > MAX_NODES) throw new Error('MathML exceeds the supported size or nesting depth.');
      const attributes = {};
      for (const key of ['linethickness','open','close','separators','selection','accent','rowspan','columnspan']) {
        if (el.hasAttribute(key)) attributes[key] = el.getAttribute(key);
      }
      return {name:el.localName, text:el.textContent, attributes,
        children:[...el.children].filter(child => !['annotation','annotation-xml'].includes(child.localName))
          .map(child => copy(child,depth+1))};
    }
    return copy(element,0);
  }

  function isVisible(element, allowAriaHidden = null) {
    for (let el = element; el; el = el.parentElement) {
      if (el.matches(HIDDEN_SELECTOR) || (el.getAttribute('aria-hidden') === 'true' && el !== allowAriaHidden)) return false;
      const style = el.ownerDocument.defaultView.getComputedStyle(el);
      if (style.display === 'none' || style.visibility !== 'visible' || style.opacity === '0') return false;
    }
    return true;
  }

  function isVisibleRoot(element) {
    // Legacy MathJax marks the visual frame itself aria-hidden; outer hidden
    // content still wins, just as for KaTeX's visual HTML representation.
    const legacy = element.matches('.MathJax, .MathJax_SVG, .MathJax_CHTML');
    return isVisible(element, legacy ? element : null);
  }

  function readFormula(element) {
    // Select the available representation before reading it. Errors in that
    // representation propagate; do not retry with a lossy alternative.
    const speechElements = [element, ...element.querySelectorAll(':scope > svg, :scope > mjx-math, :scope > .MathJax, :scope > .MathJax_SVG, :scope > .MathJax_CHTML')];
    for (const el of speechElements) {
      // MathJax 4's *-none attribute is plain text; its unqualified speech
      // attribute may contain SSML. MathJax 3 used the latter for plain text.
      for (const attr of ['aria-label','data-semantic-speech-none','data-semantic-speech']) {
        if (el.hasAttribute(attr)) {
          const speech = clean(el.getAttribute(attr));
          if (!speech) throw new Error(`Empty mathematical ${attr}.`);
          if (/<\/?[a-z][^>]*>/iu.test(speech)) throw new Error('Speech markup requires a plain-text math label.');
          return speech;
        }
      }
    }
    const math = element.localName === 'math' ? [element] : [...element.querySelectorAll('math')]
      .filter(node => !node.parentElement.closest('math, annotation, annotation-xml'));
    if (math.length > 1) throw new Error('Formula contains multiple MathML representations.');
    if (math.length === 1) {
      const speech = speakMathML(mathMLTree(math[0]));
      if (!speech) throw new Error('Empty mathematical expression.');
      return speech;
    }
    if (element.matches('.katex')) {
      const html = element.querySelector(':scope > .katex-html');
      if (!html) throw new Error('KaTeX formula has neither MathML nor rendered HTML.');
      if (!isVisible(html, html)) return '';
      const walker = element.ownerDocument.createTreeWalker(html, 4);
      let node, text = '';
      while ((node = walker.nextNode())) {
        if (isVisible(node.parentElement, html)) text += node.nodeValue;
      }
      return clean(text);
    }
    throw new Error(`${element.localName} formula has no supported MathML or speech label.`);
  }

  const api = {ROOT_SELECTOR, METADATA_SELECTOR, speakMathML, readFormula, isVisibleRoot};
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (typeof globalThis !== 'undefined') globalThis.ReedahMathNarration = api;
})();

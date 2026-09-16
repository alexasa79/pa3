// Reedah: Word Online DOM probe (manual diagnostic tool — not loaded by manifest)
// Run manually via the DevTools console or a temporary manifest entry to discover
// the document DOM structure inside the Word Online editor iframe.

(() => {
  // Only run inside iframes, not the outer SharePoint page
  if (window.top === window) return;

  // Skip non-editor iframes (OAuth, etc.)
  const url = window.location.href;
  if (url.includes("oauth.officeapps.live.com") || url.includes("WacOAuth")) {
    console.log("[Reedah Probe] Skipping OAuth iframe:", url);
    return;
  }

  console.log("[Reedah Probe] Running in frame:", url);

  const PROBE_DELAY_MS = 3000;
  const MAX_WAIT_MS = 30000;
  const POLL_INTERVAL_MS = 1000;

  function probe() {
    console.group("%c[Reedah Probe] Word Online DOM snapshot", "color: #e67e22; font-weight: bold");

    // 1. Log the frame URL
    console.log("Frame URL:", url);

    // 2. List all iframes in this frame (the real content may be nested deeper)
    const iframes = document.querySelectorAll("iframe");
    console.log(`\nNested iframes in this frame: ${iframes.length}`);
    iframes.forEach((iframe, i) => {
      console.log(`  [${i}] id="${iframe.id}" name="${iframe.name}" src="${(iframe.src || "").substring(0, 120)}"`);
    });

    // 3. Look for the document editing surface
    const editSurface = document.querySelector("[contenteditable='true']");
    console.log("\nContenteditable surface:", editSurface);
    if (editSurface) {
      console.log("  tag:", editSurface.tagName);
      console.log("  id:", editSurface.id);
      console.log("  className:", editSurface.className);
    }

    // 4. Find all unique tag+class combos that contain text
    const textHolders = new Map();
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    let node;
    while ((node = walker.nextNode())) {
      const text = node.nodeValue.trim();
      if (text.length < 3) continue;
      let el = node.parentElement;
      while (el && el !== document.body) {
        const display = window.getComputedStyle(el).display;
        if (display === "block" || display === "flex" || display === "list-item") break;
        el = el.parentElement;
      }
      if (!el || el === document.body) continue;

      const key = `${el.tagName}.${el.className.toString().split(" ").slice(0, 3).join(".")}`;
      if (!textHolders.has(key)) {
        textHolders.set(key, { count: 0, sampleText: "", sampleEl: el });
      }
      const entry = textHolders.get(key);
      entry.count++;
      if (!entry.sampleText) entry.sampleText = text.substring(0, 80);
    }

    console.log(`\nFound ${textHolders.size} distinct text-holding element types:`);
    for (const [key, info] of textHolders) {
      console.log(`  ${key} (×${info.count})`, info.sampleEl);
      console.log(`    sample: "${info.sampleText}"`);
    }

    // 5. Dump the body subtree (4 levels) to see overall structure
    console.log("\nBody subtree (4 levels):");
    dumpTree(document.body, 0, 4);

    // 6. Look for paragraph-like patterns
    const paragraphCandidates = document.querySelectorAll(
      "[class*='Paragraph'], [class*='paragraph'], [class*='OutlineElement'], [class*='TextRun'], [class*='textrun'], [data-content-type], [role='document'], [class*='Page'], [class*='page']"
    );
    console.log(`\nParagraph-like candidates (${paragraphCandidates.length}):`);
    paragraphCandidates.forEach((el, i) => {
      if (i < 30) {
        const text = el.textContent.trim().substring(0, 60);
        console.log(`  [${i}] <${el.tagName}> class="${el.className}" role="${el.getAttribute("role") || ""}"`, text ? `"${text}"` : "(empty)");
      }
    });
    if (paragraphCandidates.length > 30) {
      console.log(`  ... and ${paragraphCandidates.length - 30} more`);
    }

    // 7. Log aria roles that might identify paragraphs
    const ariaEls = document.querySelectorAll("[role]");
    const roleCounts = {};
    ariaEls.forEach(el => {
      const role = el.getAttribute("role");
      roleCounts[role] = (roleCounts[role] || 0) + 1;
    });
    console.log("\nARIA roles found:", roleCounts);

    console.groupEnd();
  }

  function dumpTree(el, depth, maxDepth) {
    if (depth >= maxDepth) return;
    const indent = "  ".repeat(depth + 1);
    const children = el.children;
    for (let i = 0; i < Math.min(children.length, 10); i++) {
      const child = children[i];
      const text = child.textContent.trim().substring(0, 40);
      const attrs = [];
      if (child.id) attrs.push(`id="${child.id}"`);
      if (child.className) attrs.push(`class="${child.className.toString().substring(0, 80)}"`);
      if (child.getAttribute("role")) attrs.push(`role="${child.getAttribute("role")}"`);
      if (child.getAttribute("contenteditable")) attrs.push(`contenteditable="${child.getAttribute("contenteditable")}"`);
      console.log(
        `${indent}<${child.tagName}> ${attrs.join(" ")} ${text ? `"${text}"` : ""}`
      );
      dumpTree(child, depth + 1, maxDepth);
    }
    if (children.length > 10) {
      console.log(`${indent}... and ${children.length - 10} more children`);
    }
  }

  // Wait for the document content to actually render before probing
  let waited = 0;
  function waitAndProbe() {
    const hasContent = document.querySelector(
      "[contenteditable='true'], [class*='Paragraph'], [class*='OutlineElement'], [class*='Page'], [role='document']"
    );
    if (hasContent) {
      setTimeout(probe, PROBE_DELAY_MS);
    } else if (waited < MAX_WAIT_MS) {
      waited += POLL_INTERVAL_MS;
      setTimeout(waitAndProbe, POLL_INTERVAL_MS);
    } else {
      console.warn("[Reedah Probe] Timed out waiting for document content. Dumping current state anyway.");
      probe();
    }
  }

  waitAndProbe();
})();

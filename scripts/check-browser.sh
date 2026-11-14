#!/usr/bin/env bash
# Browser checks of the built site (AGENTS.md rule 8) on the homepage, the glossary, the
# hackathon page and the Tools I Investigate index. Hackathon page: JavaScript off, no
# off-site requests, one LinkedIn share link with the exact href and text, its contrast
# in light and dark mode, and the computed styles of the share block. Every page: the
# skip link, the focus outline in light and dark mode, reflow at 320 px and at 200% zoom,
# and reduced motion. The homepage's screenshot must not change for the skip link (rule 7).
# Playwright runs in the image pinned in snapshot-site.sh. Its npm package comes from
# scripts/check-browser/package-lock.json (npm ci, so the tarballs are pinned by
# lockfile integrity), and the lockfile's version must match the image's. The site is
# served from inside the container on 127.0.0.1, so this works on native Linux Docker,
# where the host-gateway path that snapshot-site.sh uses does not. Needs Docker and
# network (npm). Build the site first.
#
# Usage: scripts/check-browser.sh [SITE]   (default: _site)
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
site="${1:-_site}"

# Setup errors are annotated on this script.
fail() {
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::error file=scripts/check-browser.sh::$1"
  else
    echo "error: $1" >&2
  fi
  exit 1
}

for built in index.html docs/edge-appliance/glossary.html docs/qodo-software-factory-hackathon/index.html docs/tools/index.html; do
  test -f "$site/$built" || fail "$built not built under $site; run scripts/build-site.sh first"
done
site_abs=$(cd "$site" && pwd)

image=$(sed -nE 's/^image="(mcr\.microsoft\.com\/playwright:[^"]+)"$/\1/p' "$root/scripts/snapshot-site.sh")
[[ -n "$image" ]] || fail "could not read the Playwright image from scripts/snapshot-site.sh"
version=${image#*:v}
version=${version%%-*}

pw_abs="$root/scripts/check-browser"
test -f "$pw_abs/package.json" && test -f "$pw_abs/package-lock.json" \
  || fail "scripts/check-browser/ must hold package.json and package-lock.json"

command -v docker >/dev/null 2>&1 || fail "docker not found; install Docker"
docker info >/dev/null 2>&1 || fail "cannot connect to the Docker daemon; is Docker running?"

# Node program run in the container. It uses the Playwright library that matches
# the image. GITHUB_ACTIONS (empty when unset) switches output to annotations.
read -r -d '' check_js <<'JS' || true
const fs = require('fs');
const http = require('http');
const path = require('path');
const { chromium } = require('playwright');

// Files problems are reported on, as annotations. Paths are relative to the repo root.
const pageFile = 'docs/qodo-software-factory-hackathon.md';
const layoutFile = '_layouts/docs.html';
const scriptFile = 'scripts/check-browser.sh';

// The built site, mounted read-only at /site. Nothing outside it is served.
const root = '/site';
const types = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.ico': 'image/x-icon',
};
const pagePath = '/docs/qodo-software-factory-hackathon/';
const shareHref = 'https://www.linkedin.com/sharing/share-offsite/?url=https%3A%2F%2Flioramilbaum.com%2Fdocs%2Fqodo-software-factory-hackathon%2F';
const ci = !!process.env.GITHUB_ACTIONS;
const problems = [];
const problem = (msg, file) => problems.push({ msg, file });
const need = (ok, msg, file = layoutFile) => {
  if (!ok) problem(msg, file);
};

const server = http.createServer((req, res) => {
  let file = null;
  try {
    const pathname = decodeURIComponent(new URL(req.url, 'http://127.0.0.1').pathname);
    file = path.normalize(path.join(root, pathname));
  } catch (err) {
    file = null;
  }
  if (!file || (file !== root && !file.startsWith(root + path.sep))) {
    res.writeHead(404).end();
    return;
  }
  if (fs.existsSync(file) && fs.statSync(file).isDirectory()) {
    file = path.join(file, 'index.html');
  }
  fs.readFile(file, (err, data) => {
    if (err) {
      res.writeHead(404).end();
      return;
    }
    res.writeHead(200, { 'Content-Type': types[path.extname(file)] || 'application/octet-stream' });
    res.end(data);
  });
});

// A fresh context with JavaScript off. Any request to another origin is aborted.
// opts: viewport, reducedMotion, and the file an off-site abort is reported on.
async function withPage(browser, origin, colorScheme, fn, opts = {}) {
  const context = await browser.newContext({
    javaScriptEnabled: false,
    viewport: opts.viewport || { width: 1280, height: 720 },
    colorScheme,
    reducedMotion: opts.reducedMotion || 'no-preference',
  });
  try {
    await context.route('**/*', (route) => {
      const target = route.request().url();
      if (new URL(target).origin === origin) return route.continue();
      problem(`off-site request: ${target}`, opts.file || pageFile);
      return route.abort();
    });
    await fn(await context.newPage());
  } finally {
    await context.close();
  }
}

async function pageChecks(browser, origin) {
  await withPage(browser, origin, 'light', async (page) => {
    const resp = await page.goto(origin + pagePath, { waitUntil: 'load' });
    if (!resp) problem(`did not load: no response for ${pagePath}`, pageFile);
    else if (!resp.ok()) problem(`did not load: HTTP ${resp.status()}`, pageFile);

    if ((await page.locator('script').count()) !== 0) problem('hackathon page has a <script>', pageFile);

    const share = page.locator('a[href*="share-offsite"]');
    const shares = await share.count();
    if (shares !== 1) {
      problem(`share link missing: expected one a[href*="share-offsite"], found ${shares}`, layoutFile);
      return;
    }
    const href = await share.getAttribute('href');
    if (href !== shareHref) problem(`share href is not ${shareHref} (got ${href})`, layoutFile);
    if (!(await share.isVisible())) problem('share link is not visible', layoutFile);
    const text = (await share.innerText()).trim();
    if (text !== 'Share on LinkedIn') problem(`share link text is "${text}", not "Share on LinkedIn"`, layoutFile);
  });
}

// Parses a computed colour such as rgb(0, 0, 0) or rgba(0, 0, 0, 0.5).
const parse = (s) => {
  const m = /^rgba?\((.*)\)$/.exec(s.trim());
  if (!m) throw new Error(`cannot parse colour: ${s}`);
  const v = m[1].split(/[\s,\/]+/).filter(Boolean).map(Number);
  return { r: v[0], g: v[1], b: v[2], a: v.length > 3 ? v[3] : 1 };
};

// WCAG relative luminance and contrast ratio.
const luminance = (c) => {
  const lin = (v) => {
    const x = v / 255;
    return x <= 0.03928 ? x / 12.92 : ((x + 0.055) / 1.055) ** 2.4;
  };
  return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b);
};

async function contrastCheck(browser, origin, scheme) {
  await withPage(browser, origin, scheme, async (page) => {
    await page.goto(origin + pagePath, { waitUntil: 'load' });
    const share = page.locator('a[href*="share-offsite"]');
    if ((await share.count()) !== 1) return;  // pageChecks reports the missing link
    const styles = await share.evaluate((el) => {
      const backgrounds = [];
      for (let n = el; n; n = n.parentElement) backgrounds.push(getComputedStyle(n).backgroundColor);
      return { color: getComputedStyle(el).color, backgrounds };
    });

    const fg = parse(styles.color);
    let translucent = fg.a > 0 && fg.a < 1;
    // The first opaque background, nearest first. Transparent layers are skipped.
    // No opaque one means the page is white.
    let bg = { r: 255, g: 255, b: 255, a: 1 };
    for (const s of styles.backgrounds) {
      const c = parse(s);
      if (c.a === 0) continue;
      if (c.a < 1) {
        translucent = true;
        continue;
      }
      bg = c;
      break;
    }
    if (translucent) {
      problem(`cannot check contrast: translucent colour in ${scheme} mode`, layoutFile);
      return;
    }

    const hi = Math.max(luminance(fg), luminance(bg));
    const lo = Math.min(luminance(fg), luminance(bg));
    const ratio = (hi + 0.05) / (lo + 0.05);
    if (ratio < 4.5) {
      problem(`share link contrast below 4.5:1 in ${scheme} mode: ${ratio.toFixed(2)} (${styles.color} on rgb(${bg.r}, ${bg.g}, ${bg.b}))`, layoutFile);
    }
  });
}

// Computed styles of the share block in _layouts/docs.html. Every declaration in the
// block is checked through its computed value, so a removed or changed rule fails.
async function shareStyleChecks(browser, origin, scheme) {
  await withPage(browser, origin, scheme, async (page) => {
    await page.goto(origin + pagePath, { waitUntil: 'load' });
    const share = page.locator('a[href*="share-offsite"]');
    if ((await share.count()) !== 1) return;  // pageChecks reports the missing link
    const para = page.locator('p.share');
    const svg = share.locator('svg');
    const computed = (loc, names) => loc.evaluate((el, props) => {
      const cs = getComputedStyle(el);
      return Object.fromEntries(props.map((p) => [p, cs[p]]));
    }, names);
    const expected = scheme === 'dark' ? 'rgb(88, 166, 255)' : 'rgb(3, 102, 214)';

    const a = await computed(share, [
      'display', 'alignItems', 'columnGap', 'rowGap', 'paddingTop', 'paddingLeft',
      'borderTopWidth', 'borderTopStyle', 'borderTopColor', 'borderTopLeftRadius',
      'fontWeight', 'textDecorationLine', 'color',
    ]);
    need(a.display === 'inline-flex', `share link display is "${a.display}", not inline-flex (.share a)`);
    need(a.alignItems === 'center', `share link align-items is "${a.alignItems}", not center (.share a)`);
    need(parseFloat(a.columnGap) > 0, `share link column-gap is "${a.columnGap}", not above 0 (.share a gap)`);
    need(parseFloat(a.rowGap) > 0, `share link row-gap is "${a.rowGap}", not above 0 (.share a gap)`);
    need(parseFloat(a.paddingTop) > 0, `share link padding-top is "${a.paddingTop}", not above 0 (.share a padding)`);
    need(parseFloat(a.paddingLeft) > 0, `share link padding-left is "${a.paddingLeft}", not above 0 (.share a padding)`);
    need(parseFloat(a.borderTopWidth) > 0 && a.borderTopStyle === 'solid',
      `share link border is ${a.borderTopWidth} ${a.borderTopStyle}, not a solid border above 0 (.share a border)`);
    need(a.borderTopColor === a.color,
      `share link border colour is ${a.borderTopColor}, not the link colour ${a.color} (.share a border currentColor)`);
    need(parseFloat(a.borderTopLeftRadius) > 0, `share link border-radius is "${a.borderTopLeftRadius}", not above 0 (.share a)`);
    need(parseInt(a.fontWeight, 10) >= 600, `share link font-weight is "${a.fontWeight}", not at least 600 (.share a)`);
    need(a.color === expected, `share link colour is ${a.color} in ${scheme} mode, not ${expected} (.share a)`);
    need(a.textDecorationLine === 'none',
      `share link text-decoration-line at rest is "${a.textDecorationLine}", not none (.share a)`);

    if ((await para.count()) !== 1) {
      problem('share paragraph p.share is missing', layoutFile);
    } else {
      const p = await computed(para, ['marginTop']);
      need(parseFloat(p.marginTop) > 0, `share paragraph margin-top is "${p.marginTop}", not above 0 (.share)`);
    }

    if ((await svg.count()) !== 1) {
      problem('share icon svg is missing', layoutFile);
    } else {
      const box = await svg.boundingBox();
      const size = box ? `${box.width}x${box.height}` : 'no box';
      need(!!box && box.width > 0 && box.height > 0 && box.width <= 24 && box.height <= 24,
        `share icon is ${size} CSS px, not above 0 and at most 24x24 (.share svg)`);
      const s = await computed(svg, ['fill']);
      need(s.fill === a.color, `share icon fill is ${s.fill}, not the link colour ${a.color} (.share svg currentColor)`);
    }

    // Hover: .share a:hover underlines the link.
    await share.hover();
    const hover = await computed(share, ['textDecorationLine']);
    need(hover.textDecorationLine === 'underline',
      `share link text-decoration-line on hover is "${hover.textDecorationLine}", not underline (.share a:hover)`);
    await page.mouse.move(0, 0);

    // Keyboard focus: Tab from the top of the page, through the body's links, until the
    // share link has focus. Tab focus is what :focus-visible is for; locator.focus() also
    // matched it in a probe on Chromium, so this is the stricter of the two.
    let focused = false;
    for (let i = 0; i < 50 && !focused; i++) {
      await page.keyboard.press('Tab');
      focused = await share.evaluate((el) => el === document.activeElement);
    }
    if (!focused) {
      problem('share link cannot be reached with Tab', layoutFile);
    } else {
      need(await share.evaluate((el) => el.matches(':focus-visible')),
        'share link is focused but :focus-visible does not match (.share a:focus-visible)');
      const focus = await computed(share, ['textDecorationLine']);
      need(focus.textDecorationLine === 'underline',
        `share link text-decoration-line on keyboard focus is "${focus.textDecorationLine}", not underline (.share a:focus-visible)`);
    }
  });
}

// Every built page, as a file under the site, its URL and the layout it uses. The four
// pages named in `required` must be built; the bash guard checks them too.
const required = [
  'index.html',
  'docs/edge-appliance/glossary.html',
  'docs/qodo-software-factory-hackathon/index.html',
  'docs/tools/index.html',
];
function builtPages(dir, base = '') {
  const out = [];
  for (const entry of fs.readdirSync(path.join(dir, base), { withFileTypes: true })) {
    const rel = base ? `${base}/${entry.name}` : entry.name;
    if (entry.isDirectory()) out.push(...builtPages(dir, rel));
    else if (entry.name.endsWith('.html')) out.push(rel);
  }
  return out.sort();
}
const pages = builtPages(root).map((name) => ({
  name,
  url: `/${name}`,
  layout: name === 'index.html' ? '_layouts/home.html' : '_layouts/docs.html',
}));
for (const name of required) {
  if (!pages.some((p) => p.name === name)) problem(`required page not built: ${name}`, scriptFile);
}

// Candidates for Tab: the elements that can take focus. __tabbable then decides which of them Tab
// reaches. A [tabindex] alternative of -1 is left out here; <main id="main" tabindex="-1"> takes
// focus from the skip link only, and the selector's other alternatives get the same check in __tabbable.
const focusable = 'a[href], button, input, select, textarea, summary, [tabindex]:not([tabindex="-1"])';

// Installs window.__tabbable: whether Tab reaches an element, as Chromium decides it. Not
// disabled, not inert, not out of the tab order (a negative tabindex), rendered (checkVisibility also covers visibility:hidden and the
// content of a closed <details>), and a <summary> only when it is its <details>' first.
// Written as one expression, since Playwright calls a bare function it is given.
const installTabbable = `(() => {
  window.__tabbable = (el) => {
    if (el.matches(':disabled') || el.closest('[inert]')) return false;
    if (el.hasAttribute('tabindex') && parseInt(el.getAttribute('tabindex'), 10) < 0) return false;
    if (!el.checkVisibility({ visibilityProperty: true })) return false;
    if (el.tagName === 'SUMMARY') {
      const details = el.parentElement;
      return !!details && details.tagName === 'DETAILS' && details.querySelector(':scope > summary') === el;
    }
    return true;
  };
  return true;
})()`;

// What the focus checks read from the focused element, in the page. `layers` is the
// element's background, then each ancestor's, nearest first.
const focusedInfo = () => {
  const el = document.activeElement;
  if (!el || el === document.body) return null;
  const cs = getComputedStyle(el);
  const layers = [];
  for (let n = el; n; n = n.parentElement) layers.push(getComputedStyle(n).backgroundColor);
  // A Tab stop the focus list does not name gets its own id, so a walk can tell it apart.
  if (!el.hasAttribute('data-focus-id') && !el.hasAttribute('data-unlisted-id')) {
    window.__unlisted = (window.__unlisted || 0) + 1;
    el.setAttribute('data-unlisted-id', String(window.__unlisted));
  }
  return {
    id: el.getAttribute('data-focus-id'),
    unlisted: el.getAttribute('data-unlisted-id'),
    desc: el.tagName.toLowerCase() + (el.getAttribute('class') ? '.' + el.getAttribute('class').split(' ').join('.') : ''),
    skip: el.matches('a.skip-link'),
    text: el.textContent.trim(),
    href: el.getAttribute('href'),
    focusVisible: el.matches(':focus-visible'),
    outlineStyle: cs.outlineStyle,
    outlineWidth: cs.outlineWidth,
    outlineColor: cs.outlineColor,
    color: cs.color,
    layers,
  };
};

// The opaque background behind a colour: the first layer that is not transparent. A
// translucent layer first gives null (no contrast can be read); no layer gives white.
function backdrop(layers) {
  for (const s of layers) {
    const c = parse(s);
    if (c.a === 0) continue;
    return c.a < 1 ? null : c;
  }
  return { r: 255, g: 255, b: 255, a: 1 };
}

// WCAG contrast ratio of two opaque colours.
const ratioOf = (a, b) => {
  const hi = Math.max(luminance(a), luminance(b));
  const lo = Math.min(luminance(a), luminance(b));
  return (hi + 0.05) / (lo + 0.05);
};

// Pages whose <main> may hold no focusable element. Anywhere else that is a failure.
const mayBeEmptyMain = ['docs/edge-appliance/glossary.html', 'docs/tools/index.html'];

// The skip link is the first Tab stop on every page. Focused, it is inside the viewport
// and readable, and activating it moves focus to <main id="main">.
async function skipLinkChecks(browser, origin, p, scheme) {
  await withPage(browser, origin, scheme, async (page) => {
    await page.goto(origin + p.url, { waitUntil: 'load' });
    await page.evaluate(installTabbable);
    await page.keyboard.press('Tab');
    const first = await page.evaluate(focusedInfo);
    if (!first || !first.skip || first.text !== 'Skip to content' || first.href !== '#main') {
      problem(`first Tab on ${p.url} does not focus the "Skip to content" link to #main (got ${first ? first.desc : 'nothing'})`, p.layout);
      return;
    }

    const box = await page.locator('a.skip-link').boundingBox();
    const vp = page.viewportSize();
    if (!box || box.x < 0 || box.y < 0 || box.x + box.width > vp.width || box.y + box.height > vp.height) {
      problem(`skip link is not inside the viewport when focused on ${p.url}`, p.layout);
    }

    const fg = parse(first.color);
    const bg = backdrop(first.layers);
    if (!bg || fg.a < 1) {
      problem(`cannot check skip link contrast on ${p.url}: translucent colour`, p.layout);
    } else if (ratioOf(fg, bg) < 4.5) {
      problem(`skip link contrast below 4.5:1 on ${p.url}: ${ratioOf(fg, bg).toFixed(2)} (${first.color})`, p.layout);
    }

    await page.keyboard.press('Enter');
    try {
      await page.waitForURL(/#main$/, { timeout: 5000 });
    } catch (err) {
      problem(`activating the skip link on ${p.url} does not change the URL to #main`, p.layout);
      return;
    }
    const target = await page.evaluate(() => {
      const el = document.activeElement;
      return el ? `${el.tagName.toLowerCase()}#${el.id}` : null;
    });
    if (target !== 'main#main') {
      problem(`skip link on ${p.url} does not move focus to <main id="main"> (focus is ${target})`, p.layout);
    } else {
      const outline = await page.evaluate(() => getComputedStyle(document.getElementById('main')).outlineStyle);
      if (outline !== 'none') {
        problem(`<main id="main"> draws a focus outline (outline-style ${outline}) when the skip link focuses it on ${p.url}; main:focus needs outline: none`, p.layout);
      }
    }

    const inside = await page.evaluate((sel) => {
      const main = document.getElementById('main');
      return main ? [...main.querySelectorAll(sel)].some((el) => window.__tabbable(el)) : null;
    }, focusable);
    if (inside === null) {
      problem(`no <main id="main"> on ${p.url}`, p.layout);
      return;
    }
    if (!inside && !mayBeEmptyMain.includes(p.name)) {
      problem(`${p.url} has no focusable element inside <main>, so the Tab after the skip link cannot be checked`, p.layout);
      return;
    }
    if (!inside) {
      console.log(`skipped: ${p.url} has no focusable element inside <main>, so the Tab after the skip link is not checked`);
      return;
    }
    await page.keyboard.press('Tab');
    const inMain = await page.evaluate(() => {
      const main = document.getElementById('main');
      return !!main && main !== document.activeElement && main.contains(document.activeElement);
    });
    if (!inMain) problem(`Tab after the skip link on ${p.url} does not reach a focusable element inside <main>`, p.layout);
  }, { file: p.layout });
}

// One focused element's outline: it matches :focus-visible, is solid, at least 2px wide,
// and its opaque colour has at least 3:1 contrast with the background it sits on.
function outlineChecks(info, scheme, p) {
  const at = `${info.desc} on ${p.url} (${scheme} mode)`;
  if (!info.focusVisible) problem(`no :focus-visible match for ${at}`, p.layout);
  if (info.outlineStyle !== 'solid') {
    problem(`outline-style is ${info.outlineStyle} for ${at}; it needs a solid outline`, p.layout);
  }
  if (!(parseFloat(info.outlineWidth) >= 2)) {
    problem(`outline is ${info.outlineWidth} for ${at}; it needs at least 2px`, p.layout);
  }
  if (!/^rgba?\(/.test(info.outlineColor)) {
    problem(`outline colour ${info.outlineColor} for ${at} cannot be read`, p.layout);
    return;
  }
  const oc = parse(info.outlineColor);
  const bg = backdrop(info.layers.slice(1));
  if (oc.a < 1) {
    problem(`outline colour is translucent for ${at}; it needs an opaque colour`, p.layout);
  } else if (!bg) {
    problem(`cannot check outline contrast for ${at}: translucent background`, p.layout);
  } else if (ratioOf(oc, bg) < 3) {
    problem(`outline contrast below 3:1 for ${at}: ${ratioOf(oc, bg).toFixed(2)} (${info.outlineColor})`, p.layout);
  }
}

// Tab through every focusable element on a page, in one colour scheme, and check each
// one's focus outline. Every focusable element must be reached.
async function focusOutlineChecks(browser, origin, p, scheme) {
  await withPage(browser, origin, scheme, async (page) => {
    await page.goto(origin + p.url, { waitUntil: 'load' });
    await page.evaluate(installTabbable);
    const { kept, excluded } = await page.evaluate((sel) => {
      const describe = (el) => el.tagName.toLowerCase() + (el.getAttribute('class') ? '.' + el.getAttribute('class').split(' ').join('.') : '');
      const kept = [];
      const excluded = [];
      for (const el of document.querySelectorAll(sel)) {
        if (window.__tabbable(el)) {
          el.setAttribute('data-focus-id', String(kept.length));
          kept.push(describe(el));
        } else {
          excluded.push(describe(el));
        }
      }
      return { kept, excluded };
    }, focusable);
    if (excluded.length) {
      console.log(`skipped: ${excluded.length} focusable-looking element(s) on ${p.url} (${scheme} mode) that Tab does not reach (disabled, hidden, inert, out of the tab order, or a second summary): ${excluded.join(', ')}`);
    }
    const elements = kept;
    if (elements.length === 0) {
      problem(`no focusable element on ${p.url}; the focus outline cannot be checked`, p.layout);
      return;
    }

    // A Tab stop the list does not name is reported once and the walk goes on, so the links
    // after it are still checked. The cap grows with each unlisted stop, so they do not use up
    // the room for the listed elements; a cycle or a focus exit still ends the walk.
    const reached = new Set();
    const unlisted = new Set();
    for (let i = 0; i < elements.length + unlisted.size + 5; i++) {
      await page.keyboard.press('Tab');
      const info = await page.evaluate(focusedInfo);
      if (!info) break;  // focus left the page
      if (info.id === null) {
        if (unlisted.has(info.unlisted)) break;  // cycled among unlisted stops
        unlisted.add(info.unlisted);
        problem(`Tab reached ${info.desc} on ${p.url} (${scheme} mode), which the focus check does not list; add it to the focusable selector or make it unfocusable`, p.layout);
        continue;
      }
      if (reached.has(info.id)) break;  // cycled
      reached.add(info.id);
      outlineChecks(info, scheme, p);
    }
    elements.forEach((desc, i) => {
      if (!reached.has(String(i))) problem(`focusable element not reached by Tab on ${p.url}: ${desc}`, p.layout);
    });
  }, { file: p.layout });
}

// Reflow: no horizontal scroll at 320 px, nor in a 640 px CSS viewport (what 1280 px of
// layout looks like at 200% zoom), and no <script> on the page.
async function reflowChecks(browser, origin, p) {
  const sizes = [
    { label: '320 px', width: 320, height: 640 },
    { label: '200% zoom (640 px CSS viewport, 1280 px of layout at 200%)', width: 640, height: 360 },
  ];
  for (const size of sizes) {
    await withPage(browser, origin, 'light', async (page) => {
      await page.goto(origin + p.url, { waitUntil: 'load' });
      const m = await page.evaluate(() => {
        const root = document.documentElement;
        const limit = root.clientWidth;
        const wide = [...document.querySelectorAll('body *')]
          .map((el) => ({
            desc: el.tagName.toLowerCase() + (el.getAttribute('class') ? '.' + el.getAttribute('class').split(' ').join('.') : ''),
            right: el.getBoundingClientRect().right,
          }))
          .filter((e) => e.right > limit + 0.5)
          .sort((a, b) => b.right - a.right)
          .slice(0, 3)
          .map((e) => `${e.desc} (right edge ${Math.round(e.right)} px)`);
        return { clientWidth: limit, scrollWidth: root.scrollWidth, scripts: document.querySelectorAll('script').length, wide };
      });
      if (m.clientWidth === 0 || m.clientWidth > size.width) {
        problem(`unreadable at ${size.label}: layout width is ${m.clientWidth} px on ${p.url}`, p.layout);
      } else if (m.scrollWidth > m.clientWidth) {
        problem(`horizontal scroll at ${size.label} on ${p.url}: scrollWidth ${m.scrollWidth} px > clientWidth ${m.clientWidth} px; widest: ${m.wide.join(', ') || 'none found'}`, p.layout);
      }
      if (m.scripts !== 0) problem(`${p.url} has ${m.scripts} <script> element(s)`, p.layout);
    }, { viewport: { width: size.width, height: size.height }, file: p.layout });
  }
}

// Elements that transition or animate under the current preference. The pseudo-elements
// count too, since they are where generated content would move.
const motionNames = () => {
  const out = [];
  const moves = (v) => v.split(',').some((d) => parseFloat(d) > 0);
  // A missing <body> is a failure, not an empty scan.
  if (!document.body) return null;
  for (const el of [document.documentElement, document.body, ...document.querySelectorAll('body *')]) {
    for (const pseudo of [null, '::before', '::after']) {
      const cs = getComputedStyle(el, pseudo);
      if (moves(cs.transitionDuration) || moves(cs.animationDuration)) out.push(el.tagName.toLowerCase() + (pseudo || ''));
    }
  }
  return out;
};

// Reduced motion: with the preference set, nothing transitions or animates. Without it,
// the homepage's social link transitions, which shows the preference is read at all.
// docs.html has no transitions of its own, so on the docs pages the scan below proves
// nothing moves, and the homepage's social-link comparison (0.2s without the preference,
// 0s with it) is what proves the rule applies. check-site.sh's identical shared-block
// assertion carries the same rule to docs.html.
async function reducedMotionChecks(browser, origin, p) {
  const social = 'nav[aria-label="Social links"] a';
  const isHome = p.name === 'index.html';
  const transition = async (page) => {
    if ((await page.locator(social).count()) === 0) {
      problem('social links missing from the homepage; the reduced-motion check cannot run', p.layout);
      return null;
    }
    return page.locator(social).first().evaluate((el) => getComputedStyle(el).transitionDuration);
  };
  if (isHome) {
    await withPage(browser, origin, 'light', async (page) => {
      await page.goto(origin + p.url, { waitUntil: 'load' });
      const d = await transition(page);
      if (d !== null && d !== '0.2s') problem(`social link transition is ${d} without the preference, not 0.2s; the reduced-motion check cannot prove the preference is read`, p.layout);
    }, { file: p.layout });
  }
  await withPage(browser, origin, 'light', async (page) => {
    await page.goto(origin + p.url, { waitUntil: 'load' });
    if (isHome) {
      const d = await transition(page);
      if (d !== null && d !== '0s') problem(`social link transition is ${d} with reduced motion, not 0s`, p.layout);
    }
    const moving = await page.evaluate(motionNames);
    if (moving === null) problem(`no <body> on ${p.url}; the reduced-motion scan cannot run`, p.layout);
    else if (moving.length) problem(`elements still transition or animate with reduced motion on ${p.url}: ${moving.slice(0, 5).join(', ')}`, p.layout);
  }, { reducedMotion: 'reduce', file: p.layout });
}

// The skip link is hidden until focused, so the homepage's full-page screenshot is the
// same with it and without it (rule 7).
async function screenshotInvarianceCheck(browser, origin, p) {
  await withPage(browser, origin, 'light', async (page) => {
    await page.goto(origin + p.url, { waitUntil: 'load' });
    const skip = page.locator('a.skip-link');
    if ((await skip.count()) !== 1) {
      problem('skip link missing from the homepage; the screenshot check cannot run', p.layout);
      return;
    }
    const box = await skip.boundingBox();
    if (!box || !(box.y + box.height <= 0 || box.x + box.width <= 0)) {
      problem(`skip link is visible at rest on the homepage (box ${JSON.stringify(box)}); it must sit above or left of the page`, p.layout);
    }
    const shown = await page.screenshot({ fullPage: true });
    await skip.evaluate((el) => { el.style.display = 'none'; });
    const hidden = await page.screenshot({ fullPage: true });
    if (!shown.equals(hidden)) problem('the skip link changes the homepage screenshot at rest; it must be hidden until focused (rule 7)', p.layout);
  }, { file: p.layout });
}

(async () => {
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const origin = `http://127.0.0.1:${server.address().port}`;
  const browser = await chromium.launch();
  try {
    await pageChecks(browser, origin);
    await contrastCheck(browser, origin, 'light');
    await contrastCheck(browser, origin, 'dark');
    await shareStyleChecks(browser, origin, 'light');
    await shareStyleChecks(browser, origin, 'dark');
    for (const p of pages) {
      await skipLinkChecks(browser, origin, p, 'light');
      await skipLinkChecks(browser, origin, p, 'dark');
      await focusOutlineChecks(browser, origin, p, 'light');
      await focusOutlineChecks(browser, origin, p, 'dark');
      await reflowChecks(browser, origin, p);
      await reducedMotionChecks(browser, origin, p);
    }
    const home = pages.find((p) => p.name === 'index.html');
    if (home) await screenshotInvarianceCheck(browser, origin, home);
  } finally {
    await browser.close();
    server.close();
  }

  const seen = new Map();
  for (const p of problems) seen.set(`${p.file}|${p.msg}`, p);
  for (const { msg, file } of seen.values()) {
    if (ci) console.log(`::error file=${file}::${msg}`);
    else console.error(`error: ${msg}`);
  }
  if (seen.size) process.exitCode = 1;
  else console.log(`ok ${pages.map((p) => p.name).join(', ')}`);
})().catch((err) => {
  if (ci) console.log(`::error file=${scriptFile}::${err.message}`);
  else console.error(`error: ${err.message}`);
  process.exitCode = 1;
});
JS

# Node program run in the container before npm ci. The image tag, package.json, and the
# lockfile's playwright and playwright-core must name the same version. argv: the image's version.
read -r -d '' lock_js <<'JS' || true
const fs = require('fs');
const want = process.argv[1];
const pkg = JSON.parse(fs.readFileSync('package.json', 'utf8'));
const lock = JSON.parse(fs.readFileSync('package-lock.json', 'utf8'));
const pinned = pkg.dependencies && pkg.dependencies.playwright;
const locked = lock.packages && lock.packages['node_modules/playwright'] && lock.packages['node_modules/playwright'].version;
const lockedCore = lock.packages && lock.packages['node_modules/playwright-core'] && lock.packages['node_modules/playwright-core'].version;
const bad = [];
if (pinned !== want) bad.push(`scripts/check-browser/package.json pins playwright ${pinned}`);
if (locked !== want) bad.push(`package-lock.json pins playwright ${locked}`);
if (lockedCore !== want) bad.push(`package-lock.json pins playwright-core ${lockedCore}`);
if (bad.length) {
  const msg = `Playwright version mismatch: the image is v${want}, but ${bad.join(', and ')}. Set all of them to ${want}.`;
  if (process.env.GITHUB_ACTIONS) console.log(`::error file=scripts/check-browser.sh::${msg}`);
  else console.error(`error: ${msg}`);
  process.exit(1);
}
JS

docker run --rm --init --ipc=host --tmpfs /tmp:rw,exec,size=1g --user "$(id -u):$(id -g)" \
  -e HOME=/tmp \
  -e npm_config_cache=/tmp/.npm \
  -e npm_config_update_notifier=false \
  -e npm_config_loglevel=error \
  -e GITHUB_ACTIONS="${GITHUB_ACTIONS:-}" \
  -v "$site_abs":/site:ro \
  -v "$pw_abs":/pw:ro \
  "$image" \
  bash -c 'set -euo pipefail; v=$1; js=$2; lock_js=$3; mkdir /tmp/pw; cp /pw/package.json /pw/package-lock.json /tmp/pw/; cd /tmp/pw; node -e "$lock_js" "$v"; npm ci --ignore-scripts --no-audit --no-fund; NODE_PATH=/tmp/pw/node_modules node -e "$js"' _ "$version" "$check_js" "$lock_js"

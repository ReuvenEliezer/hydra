#!/usr/bin/env node
/**
 * WCAG contrast verification for the Hydra UI design tokens (SC-004).
 *
 * Dependency-free by design: FR-015 forbids adding runtime dependencies, and the WCAG
 * formula plus an OKLCH->sRGB conversion is small enough that a package is not worth the
 * supply-chain surface. The tokens are authored in `oklch()`, so reading hex directly is
 * not an option -- the conversion below is the whole reason this file exists.
 *
 * Usage:  node scripts/check-contrast.mjs
 * Exits non-zero if any checked pair falls below its threshold in either theme.
 */

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const HERE = dirname(fileURLToPath(import.meta.url));
const CSS_PATH = resolve(HERE, "../src/styles/index.css");

/* ------------------------------------------------------------------ colour */

/** OKLCH -> linear sRGB. Returns channels clamped to the displayable gamut. */
function oklchToLinearRgb(L, C, H) {
  const hRad = (H * Math.PI) / 180;
  const a = C * Math.cos(hRad);
  const b = C * Math.sin(hRad);

  const l_ = L + 0.3963377774 * a + 0.2158037573 * b;
  const m_ = L - 0.1055613458 * a - 0.0638541728 * b;
  const s_ = L - 0.0894841775 * a - 1.291485548 * b;

  const l = l_ * l_ * l_;
  const m = m_ * m_ * m_;
  const s = s_ * s_ * s_;

  const rgb = [
    4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
    -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
    -0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s,
  ];
  // Out-of-gamut values would otherwise produce luminance outside [0,1] and make a
  // failing pair look like it passes.
  return rgb.map((v) => Math.min(1, Math.max(0, v)));
}

/** sRGB hex -> linear sRGB (the WCAG linearisation curve). */
function hexToLinearRgb(hex) {
  const h = hex.replace("#", "");
  const full = h.length === 3 ? [...h].map((c) => c + c).join("") : h;
  return [0, 2, 4].map((i) => {
    const v = parseInt(full.slice(i, i + 2), 16) / 255;
    return v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
  });
}

function parseColor(value) {
  const v = value.trim();

  const oklch = v.match(
    /^oklch\(\s*([\d.]+)%?\s+([\d.]+)\s+([\d.]+)(?:deg)?\s*(?:\/\s*[\d.]+%?\s*)?\)$/i,
  );
  if (oklch !== null) {
    let L = parseFloat(oklch[1]);
    // `oklch(96% ...)` and `oklch(0.96 ...)` are both legal; normalise to 0..1.
    if (v.includes("%")) L = L / 100;
    return oklchToLinearRgb(L, parseFloat(oklch[2]), parseFloat(oklch[3]));
  }

  if (/^#[0-9a-f]{3}([0-9a-f]{3})?$/i.test(v)) return hexToLinearRgb(v);

  return null; // unresolvable (var(), colour-mix, gradient, ...) -- caller skips it
}

/** WCAG 2.1 relative luminance from linear sRGB. */
const luminance = ([r, g, b]) => 0.2126 * r + 0.7152 * g + 0.0722 * b;

function contrastRatio(fg, bg) {
  const a = luminance(fg);
  const b = luminance(bg);
  const [hi, lo] = a > b ? [a, b] : [b, a];
  return (hi + 0.05) / (lo + 0.05);
}

/* ------------------------------------------------------------------- parse */

/**
 * Pulls `--token: value;` pairs out of a named block. The dark palette is expressed as
 * overrides on top of light, which mirrors how the stylesheet itself is written.
 */
function extractBlock(css, startPattern) {
  const start = css.search(startPattern);
  if (start === -1) return {};

  let i = css.indexOf("{", start);
  if (i === -1) return {};

  let depth = 0;
  let end = i;
  for (; end < css.length; end++) {
    if (css[end] === "{") depth++;
    else if (css[end] === "}") {
      depth--;
      if (depth === 0) break;
    }
  }

  const body = css.slice(i + 1, end);
  const tokens = {};
  for (const m of body.matchAll(/(--[\w-]+)\s*:\s*([^;]+);/g)) {
    tokens[m[1]] = m[2].trim();
  }
  return tokens;
}

/* ------------------------------------------------------------------- pairs */

/**
 * [foreground, background, minimum ratio, description, required?]
 *
 * 4.5:1 is the WCAG AA threshold for body text; 3:1 covers large text and the boundary
 * of a UI component. Pairs naming a token that does not exist yet are reported as
 * skipped rather than failing, so this script is useful while the palette is still
 * being built.
 *
 * `required: false` marks a pair reported for information but not gated. The only such
 * pair is the decorative hairline: WCAG 1.4.11 applies to "visual information required
 * to identify user interface components and states", which covers the boundary of a
 * control but not a divider drawn between two rows of a table. Holding a subtle divider
 * to 3:1 would force a heavy, high-contrast line that fights the intended design for no
 * accessibility gain. Control boundaries are gated instead via `--color-border-strong`,
 * so the requirement is relocated, not dropped -- this is stated here rather than
 * silently loosened.
 */
const PAIRS = [
  ["--color-content", "--color-surface", 4.5, "body text on surface"],
  ["--color-content", "--color-surface-muted", 4.5, "body text on muted surface"],
  ["--color-content", "--color-surface-raised", 4.5, "body text on raised surface"],
  ["--color-content-muted", "--color-surface", 4.5, "secondary text on surface"],
  ["--color-content-muted", "--color-surface-muted", 4.5, "secondary text on muted surface"],
  ["--color-brand-content", "--color-brand", 4.5, "text on accent (primary button)"],
  ["--color-brand", "--color-surface", 4.5, "accent text on surface"],
  ["--color-brand", "--color-brand-wash", 4.5, "accent text on accent wash"],
  ["--color-danger", "--color-surface", 4.5, "error text on surface"],
  ["--color-danger", "--color-danger-surface", 4.5, "error text on error surface"],
  ["--color-success", "--color-surface", 4.5, "success text on surface"],
  ["--color-warning", "--color-surface", 4.5, "warning text on surface"],
  ["--color-warning", "--color-warning-surface", 4.5, "warning text on warning surface"],
  ["--color-border-subtle", "--color-surface", 3, "decorative divider (informational)", false],
  ["--color-border-strong", "--color-surface", 3, "control boundary against surface"],
  ["--color-border-strong", "--color-surface-muted", 3, "control boundary against muted surface"],
  ["--color-brand", "--color-surface-muted", 3, "focus ring against muted surface"],
];

/* -------------------------------------------------------------------- main */

const css = readFileSync(CSS_PATH, "utf8");
const light = extractBlock(css, /@theme\b/);
const darkOverrides = extractBlock(css, /:root\[data-theme="dark"\]/);
const dark = { ...light, ...darkOverrides };

if (Object.keys(light).length === 0) {
  console.error(`No tokens found in ${CSS_PATH} -- is the @theme block present?`);
  process.exit(2);
}

let failures = 0;
let skipped = 0;

for (const [themeName, tokens] of [
  ["light", light],
  ["dark", dark],
]) {
  console.log(`\n  ${themeName.toUpperCase()}`);
  for (const [fgName, bgName, threshold, label, required = true] of PAIRS) {
    const fgRaw = tokens[fgName];
    const bgRaw = tokens[bgName];

    if (fgRaw === undefined || bgRaw === undefined) {
      console.log(`  SKIP  ${label} (missing ${fgRaw === undefined ? fgName : bgName})`);
      skipped++;
      continue;
    }

    const fg = parseColor(fgRaw);
    const bg = parseColor(bgRaw);
    if (fg === null || bg === null) {
      console.log(`  SKIP  ${label} (unresolvable value)`);
      skipped++;
      continue;
    }

    const ratio = contrastRatio(fg, bg);
    const ok = ratio >= threshold;
    if (!ok && required) failures++;
    const mark = ok ? "PASS" : required ? "FAIL" : "INFO";
    console.log(
      `  ${mark}  ${ratio.toFixed(2).padStart(5)}:1  (min ${threshold})  ${label}`,
    );
  }
}

console.log(
  `\n${failures === 0 ? "All checked pairs meet WCAG AA." : `${failures} pair(s) below threshold.`}` +
    (skipped > 0 ? ` ${skipped} skipped.` : ""),
);
process.exit(failures === 0 ? 0 : 1);

// @ts-check

// Renders ```mermaid fences to SVG files while the book is built, so readers
// get finished diagrams without running Mermaid in the browser. Rendering is
// done by mermaid-isomorphic — Mermaid inside headless Playwright.
//
// markdown-it fence rules are synchronous and rendering is not. The fence rule
// therefore leaves a placeholder and starts the render; the wrapped
// `md.renderAsync`, which VitePress uses for pages and for the search index,
// awaits the renders and swaps the placeholders for <figure> elements.
//
// The SVGs live in a content-addressed cache (diagram source plus theme). Each
// figure references its file as `@book-mermaid/<key>.svg`; Vue compiles that
// into an import, which the Vite plugin resolves to the cache, so Vite serves
// the file in dev and emits it as a hashed asset in the build. Files rather
// than inline markup: a chapter holds many diagrams in two palettes, and inline
// copies would land in both the page HTML and its JS chunk.

import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

/** @typedef {import('mermaid').MermaidConfig} MermaidConfig */

const CACHE_DIR = path.resolve('node_modules', '.cache', 'mermaid');

const IMPORT_PREFIX = '@book-mermaid/';

/**
 * The light palette and, when a dark file exists, the dark palette merged
 * over it. The dark file holds only what differs; nested sections merge key
 * by key.
 *
 * @param {string} lightFile
 * @param {string} darkFile
 * @returns {{ light: MermaidConfig, dark: MermaidConfig | null }}
 */
export function loadThemes(lightFile, darkFile) {
  const light = JSON.parse(fs.readFileSync(lightFile, 'utf8'));
  if (!fs.existsSync(darkFile)) {
    return { light, dark: null };
  }
  const overrides = JSON.parse(fs.readFileSync(darkFile, 'utf8'));
  const dark = { ...light, ...overrides };
  for (const section of ['themeVariables', 'flowchart', 'sequence', 'sankey']) {
    dark[section] = { ...light[section], ...overrides[section] };
  }
  return { light, dark };
}

/**
 * Cache key for a diagram: its source plus the theme it is rendered with.
 *
 * @param {string} source
 * @param {MermaidConfig} config
 * @returns {string}
 */
function digest(source, config) {
  return crypto
    .createHash('sha256')
    .update(JSON.stringify(config))
    .update(source)
    .digest('hex')
    .slice(0, 16);
}

/**
 * The diagram's caption from its frontmatter `title:`, used as alt text.
 *
 * @param {string} source
 * @returns {string}
 */
export function captionOf(source) {
  const frontmatter = /^\s*---\s*\n([\s\S]*?)\n\s*---/.exec(source);
  const title = frontmatter && /^\s*title:\s*(.+?)\s*$/m.exec(frontmatter[1]);
  return title ? title[1].replace(/^(['"])(.*)\1$/, '$2') : 'Diagram';
}

/**
 * @param {string} value
 * @returns {string}
 */
function escapeAttr(value) {
  return value
    .replace(/&/g, '&amp;')
    .replace(/"/g, '&quot;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');
}

/**
 * @param {object} options
 * @param {MermaidConfig} options.light
 * @param {MermaidConfig | null} options.dark
 */
export function createMermaid({ light, dark }) {
  /** @type {Promise<import('mermaid-isomorphic').MermaidRenderer> | null} */
  let rendererPromise = null;

  // Every renderer call opens its own browser tab, and pages render
  // concurrently. Unbounded parallel calls open dozens of tabs at once and
  // exhaust a CI runner's memory, so renders run one at a time.
  /** @type {Promise<unknown>} */
  let renderQueue = Promise.resolve();

  // The client bundle, the server bundle and the search index each render
  // every page, so the same diagram is requested several times at once.
  /** @type {Map<string, Promise<{ key: string, size: string }>>} */
  const inFlight = new Map();

  /**
   * Render (or reuse) one diagram and return its cache key and pixel size.
   *
   * @param {string} source
   * @param {MermaidConfig} config
   * @returns {Promise<{ key: string, size: string }>}
   */
  function render(source, config) {
    const key = digest(source, config);
    let result = inFlight.get(key);
    if (result === undefined) {
      result = renderOnce(source, config, key);
      inFlight.set(key, result);
      // Forget failures so the dev server retries after an edit.
      result.catch(() => inFlight.delete(key));
    }
    return result;
  }

  /**
   * @param {string} source
   * @param {MermaidConfig} config
   * @param {string} key
   * @returns {Promise<{ key: string, size: string }>}
   */
  async function renderOnce(source, config, key) {
    const file = path.join(CACHE_DIR, `${key}.svg`);
    let svg = fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : null;
    if (svg === null) {
      rendererPromise ??= import('mermaid-isomorphic').then(({ createMermaidRenderer }) =>
        createMermaidRenderer()
      );
      const renderer = await rendererPromise;
      // One diagram per call, so the SVG ids derive from the content and stay
      // unique on a page that mixes freshly rendered and cached diagrams.
      const run = renderQueue.then(() =>
        renderer([source], { mermaidConfig: config, prefix: `mermaid-${key}` })
      );
      renderQueue = run.catch(() => undefined);
      const [result] = await run;
      if (result.status === 'rejected') {
        const reason = result.reason?.message ?? String(result.reason);
        throw new Error(`Mermaid diagram failed to render: ${reason}\n\n${source}`);
      }
      svg = result.value.svg;
      fs.mkdirSync(CACHE_DIR, { recursive: true });
      fs.writeFileSync(file, svg);
    }
    const viewBox = /viewBox="[-\d.]+ [-\d.]+ ([\d.]+) ([\d.]+)"/.exec(svg);
    const size = viewBox
      ? ` width="${Math.ceil(Number(viewBox[1]))}" height="${Math.ceil(Number(viewBox[2]))}"`
      : '';
    return { key, size };
  }

  /**
   * @param {string} source
   * @param {MermaidConfig} config
   * @param {string} alt
   * @returns {Promise<string>}
   */
  async function image(source, config, alt) {
    const { key, size } = await render(source, config);
    return `<img src="${IMPORT_PREFIX}${key}.svg" alt="${alt}"${size} loading="lazy" decoding="async">`;
  }

  /**
   * @param {string} source
   * @returns {Promise<string>}
   */
  async function figure(source) {
    const alt = escapeAttr(captionOf(source));
    const lightImage = await image(source, light, alt);
    if (dark === null) {
      return `<figure class="mermaid">${lightImage}</figure>`;
    }
    // Both palettes are on the page; CSS shows the one matching the theme,
    // and a hidden lazy image is never downloaded.
    const darkImage = await image(source, dark, alt);
    return `<figure class="mermaid mermaid-themed"><div class="mermaid-light">${lightImage}</div><div class="mermaid-dark">${darkImage}</div></figure>`;
  }

  /**
   * markdown-it plugin for `markdown.config`.
   *
   * @param {import('vitepress').MarkdownRenderer} md
   */
  function markdown(md) {
    /** @type {Map<string, Promise<string>>} */
    const pending = new Map();
    let nextId = 0;

    const fence = md.renderer.rules.fence;
    md.renderer.rules.fence = (tokens, index, options, env, self) => {
      const token = tokens[index];
      if (token.info.trim().split(/\s+/)[0] !== 'mermaid') {
        return fence
          ? fence(tokens, index, options, env, self)
          : self.renderToken(tokens, index, options);
      }
      const id = String(nextId++);
      const result = figure(token.content);
      // Surfaced when renderAsync awaits it; not an unhandled rejection meanwhile.
      result.catch(() => undefined);
      pending.set(id, result);
      return `<!--mermaid:${id}-->\n`;
    };

    const renderAsync = md.renderAsync.bind(md);
    md.renderAsync = async (src, env) => {
      const html = await renderAsync(src, env);
      /** @type {Map<string, string>} */
      const figures = new Map();
      for (const [, id] of html.matchAll(/<!--mermaid:(\d+)-->/g)) {
        const result = pending.get(id);
        if (result === undefined) {
          throw new Error(`Unknown Mermaid placeholder ${id}`);
        }
        pending.delete(id);
        figures.set(id, await result);
      }
      return html.replace(/<!--mermaid:(\d+)-->/g, (_, id) => figures.get(id) ?? '');
    };
  }

  /**
   * Vite plugin resolving the figures' image imports to the cached SVGs.
   *
   * @returns {import('vite').Plugin}
   */
  function vitePlugin() {
    return {
      name: 'book-mermaid',
      resolveId(id) {
        if (!id.startsWith(IMPORT_PREFIX)) {
          return null;
        }
        const key = id.slice(IMPORT_PREFIX.length).replace(/\.svg$/, '');
        return /^[0-9a-f]{16}$/.test(key) ? path.join(CACHE_DIR, `${key}.svg`) : null;
      }
    };
  }

  return { markdown, vitePlugin };
}

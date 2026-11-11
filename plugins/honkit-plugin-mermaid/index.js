// @ts-check
'use strict';

// Renders ```mermaid fences into inline SVG while the book is built, so the
// diagrams survive both the HTML output and `honkit pdf` (which never runs JS).
// Rendering is done by mermaid-isomorphic — Mermaid inside headless Playwright.
//
// CommonJS on purpose: honkit loads plugins with a synchronous `require()`, so
// the entry point cannot be an ES module. The ESM-only renderer is pulled in
// with a dynamic `import()` instead.
//
// The `page` hook reads the HTML honkit has already produced, so in book.json
// this plugin must stay after any plugin that rewrites <pre> blocks.

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const cheerio = require('cheerio');

const CACHE_DIR = path.join(process.cwd(), 'node_modules', '.cache', 'honkit-mermaid');

/** @type {import('mermaid').MermaidConfig} */
let mermaidConfig = {};

// Palette for the night reader theme, or null when the book has none.
/** @type {import('mermaid').MermaidConfig | null} */
let darkConfig = null;

/** @type {Promise<import('mermaid-isomorphic').MermaidRenderer> | null} */
let rendererPromise = null;

// Every renderer call opens its own browser tab. Pages are generated
// concurrently and a chapter can hold many diagrams in two themes, so unbounded
// parallel calls open dozens of tabs at once and exhaust a CI runner's memory.
// Renders therefore run one at a time through this chain.
/** @type {Promise<unknown>} */
let renderQueue = Promise.resolve();

/**
 * Cache key for a diagram: its source plus the theme it is rendered with.
 *
 * @param {string} source
 * @param {import('mermaid').MermaidConfig} config
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
 * @param {string} key
 * @returns {string | null}
 */
function readCached(key) {
  try {
    return fs.readFileSync(path.join(CACHE_DIR, `${key}.svg`), 'utf8');
  } catch {
    return null;
  }
}

/**
 * @param {string} source
 * @param {import('mermaid').MermaidConfig} config
 * @returns {Promise<string>}
 */
async function render(source, config) {
  const key = digest(source, config);
  const cached = readCached(key);
  if (cached !== null) {
    return cached;
  }
  // Memoised as a promise: a page with several fences renders them in parallel,
  // and each of those calls must reuse the one browser the renderer manages.
  rendererPromise ??= import('mermaid-isomorphic').then(({ createMermaidRenderer }) =>
    createMermaidRenderer()
  );
  const renderer = await rendererPromise;
  // One diagram per call, so the SVG ids are derived from the content and stay
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
  fs.mkdirSync(CACHE_DIR, { recursive: true });
  fs.writeFileSync(path.join(CACHE_DIR, `${key}.svg`), result.value.svg);
  return result.value.svg;
}

/**
 * The diagram's caption from its frontmatter `title:`, used as the image's alt text.
 *
 * @param {string} source
 * @returns {string}
 */
function captionOf(source) {
  const frontmatter = /^\s*---\s*\n([\s\S]*?)\n\s*---/.exec(source);
  const title = frontmatter && /^\s*title:\s*(.+?)\s*$/m.exec(frontmatter[1]);
  return title ? title[1].replace(/^(['"])(.*)\1$/, '$2') : 'Diagram';
}

/**
 * Embed a rendered SVG as an <img> with a data URI rather than inline markup.
 * Inline SVG carries a large <style> block, and the built-in search plugin
 * indexes page text after this hook with tags stripped but style text kept, so
 * every diagram's CSS ended up in the search index. As an image attribute the
 * SVG is invisible to the indexer; the caption stays searchable as alt text.
 *
 * @param {string} svg
 * @param {string} caption
 * @returns {string}
 */
function asImage(svg, caption) {
  const viewBox = /viewBox="[-\d.]+ [-\d.]+ ([\d.]+) ([\d.]+)"/.exec(svg);
  const size = viewBox
    ? ` width="${Math.ceil(Number(viewBox[1]))}" height="${Math.ceil(Number(viewBox[2]))}"`
    : '';
  const alt = caption.replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;');
  const src = `data:image/svg+xml;base64,${Buffer.from(svg, 'utf8').toString('base64')}`;
  return `<img src="${src}" alt="${alt}"${size}>`;
}

module.exports = {
  website: {
    assets: './assets',
    css: ['mermaid.css']
  },

  ebook: {
    assets: './assets',
    css: ['mermaid.css']
  },

  hooks: {
    init: function () {
      const options = this.config.get('pluginsConfig.mermaid', {});
      const configFile = path.resolve(process.cwd(), options.configFile || 'mermaid.config.json');
      mermaidConfig = fs.existsSync(configFile)
        ? JSON.parse(fs.readFileSync(configFile, 'utf8'))
        : {};

      // The dark file holds only what differs; nested sections merge key by key.
      const darkFile = path.resolve(
        process.cwd(),
        options.darkConfigFile || 'mermaid.config.dark.json'
      );
      if (fs.existsSync(darkFile)) {
        const dark = JSON.parse(fs.readFileSync(darkFile, 'utf8'));
        darkConfig = { ...mermaidConfig, ...dark };
        for (const section of ['themeVariables', 'flowchart', 'sequence', 'sankey']) {
          darkConfig[section] = { ...mermaidConfig[section], ...dark[section] };
        }
      }
    },

    // Honkit has already turned the chapter's Markdown into HTML by this point,
    // so the fences arrive as <pre><code class="lang-mermaid">. Walk that HTML
    // with cheerio (honkit's own HTML parser) rather than matching it by hand.
    page: async function (page) {
      const $ = cheerio.load(page.content, null, false);
      const fences = $('pre > code.lang-mermaid');
      if (fences.length === 0) {
        return page;
      }

      // The PDF has no reader themes, so only the website gets the dark copy.
      const withDark = darkConfig !== null && this.output.name === 'website';

      const figures = await Promise.all(
        fences.toArray().map(async (element) => {
          const source = $(element).text();
          const caption = captionOf(source);
          const light = asImage(await render(source, mermaidConfig), caption);
          if (!withDark) {
            return `<figure class="mermaid">${light}</figure>`;
          }
          const dark = asImage(
            await render(source, /** @type {import('mermaid').MermaidConfig} */ (darkConfig)),
            caption
          );
          return `<figure class="mermaid mermaid-themed"><div class="mermaid-light">${light}</div><div class="mermaid-dark">${dark}</div></figure>`;
        })
      );

      fences.each((index, element) => {
        $(element).parent().replaceWith(figures[index]);
      });

      page.content = $.html();
      return page;
    }
  }
};

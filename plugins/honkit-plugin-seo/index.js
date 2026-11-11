// @ts-check
'use strict';

// Search and link-preview metadata for the website: meta description,
// canonical URL, hreflang alternates, Open Graph / Twitter tags and a sitemap.
//
// Honkit's theme can render only what a page's frontmatter holds. It cannot
// derive a description from the text or see which other locales translated a
// page. So the work runs in the root book's `finish` hook: honkit generates
// every language book before it, so all pages of all locales are on disk, and
// the hreflang sets come from the pages that were actually built.
//
// Pages are only read with cheerio. Tags are spliced in as strings so the
// rest of each page, including the base64 diagrams, is never re-serialised.
// The splice is idempotent, so a rebuild under `honkit serve` that leaves
// unchanged pages on disk does not duplicate tags.

const fs = require('node:fs');
const path = require('node:path');

const cheerio = require('cheerio');

const START = '<!-- seo:start -->';
const END = '<!-- seo:end -->';
const DESCRIPTION_LIMIT = 200;

/** @type {Record<string, string>} */
const OG_LOCALES = { en: 'en_US', ru: 'ru_RU', es: 'es_ES' };

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
 * Absolute URL of an output file; `index.html` maps to its directory.
 *
 * @param {string} siteUrl
 * @param {string} file path relative to the output root, with forward slashes
 * @returns {string}
 */
function urlOf(siteUrl, file) {
  return siteUrl + file.replace(/(^|\/)index\.html$/, '$1');
}

/**
 * Shorten text to a full first sentence, or cut it on a word boundary.
 *
 * @param {string} text
 * @returns {string}
 */
function summarize(text) {
  const clean = text.replace(/\s+/g, ' ').trim();
  if (clean.length <= DESCRIPTION_LIMIT) {
    return clean;
  }
  // A sentence ends at . ! ? … followed by a capital letter; "e.g. the" and
  // the ellipsis in "SELECT ... FOR UPDATE" do not end one.
  const sentence = /^.{60,}?(?<!\.)[.!?…](?=\s+["«(¿¡]?\p{Lu})/u.exec(clean);
  if (sentence && sentence[0].length <= DESCRIPTION_LIMIT) {
    return sentence[0];
  }
  const cut = clean.slice(0, DESCRIPTION_LIMIT - 1);
  return `${cut.slice(0, cut.lastIndexOf(' ')).replace(/[\s,;:—–-]+$/, '')}…`;
}

/**
 * Description of a page: frontmatter `description` if the theme rendered one,
 * else the page's first paragraph — a pattern's Intent, the lead of an
 * introduction or appendix. Anti-patterns open with "Also known as" rather
 * than an intent, so their chapters set `description` in frontmatter.
 *
 * @param {import('cheerio').CheerioAPI} $
 * @returns {string}
 */
function describe($) {
  const rendered = $('meta[name="description"]').attr('content')?.trim();
  if (rendered) {
    return rendered;
  }
  return summarize($('.markdown-section > p').first().text());
}

/**
 * Every HTML page under a directory, relative to it.
 *
 * @param {string} dir
 * @returns {string[]}
 */
function listPages(dir) {
  return fs
    .readdirSync(dir, { recursive: true, encoding: 'utf8' })
    .filter((file) => file.endsWith('.html'))
    .map((file) => file.split(path.sep).join('/'));
}

/**
 * Locale ids in LANGS.md order, e.g. `* [English](en/)` → `en`.
 *
 * @param {string} langs
 * @returns {string[]}
 */
function parseLocales(langs) {
  return [...langs.matchAll(/\]\(([^)/]+)\/?\)/g)].map((match) => match[1]);
}

/**
 * @typedef {object} PageInfo
 * @property {string} file output path relative to the output root
 * @property {string | null} locale
 * @property {string} local output path relative to the locale folder
 */

/**
 * @param {object} options
 * @param {string} options.root output root
 * @param {string} options.siteUrl
 * @param {string[]} options.locales
 * @param {string} options.bookTitle
 * @param {string} options.bookDescription
 * @param {{ path: string, width: number, height: number } | null} options.image
 *   `{locale}` in the path is replaced with the page's locale
 * @returns {string[]} absolute URLs of every page
 */
function annotate({ root, siteUrl, locales, bookTitle, bookDescription, image }) {
  if (image) {
    for (const locale of locales.length > 0 ? locales : ['']) {
      const file = image.path.replace('{locale}', locale);
      if (!fs.existsSync(path.join(root, file))) {
        throw new Error(`Open Graph image ${file} is missing from the build`);
      }
    }
  }

  /** @type {PageInfo[]} */
  const pages = [{ file: 'index.html', locale: null, local: 'index.html' }];
  for (const locale of locales) {
    const dir = path.join(root, locale);
    if (!fs.existsSync(dir)) {
      continue;
    }
    for (const local of listPages(dir)) {
      pages.push({ file: `${locale}/${local}`, locale, local });
    }
  }
  const built = new Set(pages.map((page) => page.file));

  // Each edition's own name, from the heading of its introduction.
  /** @type {Record<string, string>} */
  const siteNames = {};
  for (const locale of locales) {
    const index = path.join(root, locale, 'index.html');
    if (fs.existsSync(index)) {
      const $ = cheerio.load(fs.readFileSync(index, 'utf8'));
      siteNames[locale] = $('.markdown-section h1').first().text().trim() || bookTitle;
    }
  }

  for (const page of pages) {
    const target = path.join(root, page.file);
    let html = fs.readFileSync(target, 'utf8');
    const startAt = html.indexOf(START);
    if (startAt !== -1) {
      html = html.slice(0, startAt) + html.slice(html.indexOf(END) + END.length + 1);
    }

    const $ = cheerio.load(html);
    const siteName = (page.locale && siteNames[page.locale]) || bookTitle;
    // The theme titles a page "<page> · <book title>"; a previous run already
    // put the edition's own name there.
    const fullTitle = $('title').text();
    const suffix = [` · ${bookTitle}`, ` · ${siteName}`].find((end) => fullTitle.endsWith(end));
    const title = suffix ? fullTitle.slice(0, -suffix.length) : fullTitle;
    const description = describe($) || bookDescription;
    const lang = page.locale ?? $('html').attr('lang') ?? 'en';
    const url = urlOf(siteUrl, page.file);
    const isIndex = page.local === 'index.html';

    // A page has alternates where other locales built the same file; the
    // language chooser at the root is the alternate of every introduction.
    /** @type {Array<[string, string]>} */
    const alternates = locales
      .filter((locale) => built.has(`${locale}/${page.local}`))
      .map((locale) => [locale, urlOf(siteUrl, `${locale}/${page.local}`)]);
    const fallback = isIndex
      ? urlOf(siteUrl, 'index.html')
      : alternates.find(([locale]) => locale === locales[0])?.[1];

    const tags = [
      `<link rel="canonical" href="${escapeAttr(url)}">`,
      ...(alternates.length > 1 || page.locale === null
        ? [
            ...alternates.map(
              ([locale, href]) =>
                `<link rel="alternate" hreflang="${locale}" href="${escapeAttr(href)}">`
            ),
            ...(fallback
              ? [`<link rel="alternate" hreflang="x-default" href="${escapeAttr(fallback)}">`]
              : [])
          ]
        : []),
      `<meta property="og:type" content="${isIndex ? 'website' : 'article'}">`,
      `<meta property="og:site_name" content="${escapeAttr(siteName)}">`,
      `<meta property="og:title" content="${escapeAttr(title)}">`,
      `<meta property="og:description" content="${escapeAttr(description)}">`,
      `<meta property="og:url" content="${escapeAttr(url)}">`,
      `<meta property="og:locale" content="${OG_LOCALES[lang] ?? lang}">`,
      ...alternates
        .filter(([locale]) => locale !== page.locale)
        .map(
          ([locale]) =>
            `<meta property="og:locale:alternate" content="${OG_LOCALES[locale] ?? locale}">`
        ),
      ...(image
        ? [
            `<meta property="og:image" content="${escapeAttr(siteUrl + image.path.replace('{locale}', page.locale ?? locales[0] ?? ''))}">`,
            `<meta property="og:image:width" content="${image.width}">`,
            `<meta property="og:image:height" content="${image.height}">`,
            `<meta property="og:image:alt" content="${escapeAttr(siteName)}">`
          ]
        : []),
      `<meta name="twitter:card" content="${image ? 'summary_large_image' : 'summary'}">`
    ];

    html = html
      .replace(
        /<meta name="description" content="[^"]*">/,
        `<meta name="description" content="${escapeAttr(description)}">`
      )
      .replace(/<title>[^<]*<\/title>/, (match) =>
        suffix ? `<title>${escapeAttr(title)} · ${escapeAttr(siteName)}</title>` : match
      )
      // The theme forbids zooming, which fails accessibility audits.
      .replace(', user-scalable=no', '')
      // The block ends in a newline so that removing it restores the page exactly.
      .replace('</head>', `${START}\n    ${tags.join('\n    ')}\n    ${END}\n</head>`);
    fs.writeFileSync(target, html);
  }

  return pages.map((page) => urlOf(siteUrl, page.file));
}

module.exports = {
  hooks: {
    finish: async function () {
      // Language books finish before the root one; only the root sees every locale.
      if (this.output.name !== 'website' || this.isLanguageBook()) {
        return;
      }
      const options = this.config.get('pluginsConfig.seo', {});
      if (!options.siteUrl) {
        throw new Error('pluginsConfig.seo.siteUrl is required');
      }
      const siteUrl = options.siteUrl.endsWith('/') ? options.siteUrl : `${options.siteUrl}/`;
      const root = this.output.root();
      const locales = this.isMultilingual()
        ? parseLocales(await this.readFileAsString(this.config.get('structure.langs', 'LANGS.md')))
        : [];

      const image = options.image
        ? { path: options.image, width: options.imageWidth, height: options.imageHeight }
        : null;

      const urls = annotate({
        root,
        siteUrl,
        locales,
        bookTitle: this.config.get('title', ''),
        bookDescription: this.config.get('description', ''),
        image
      });

      const entries = urls
        .sort()
        .map((url) => `  <url><loc>${escapeAttr(url)}</loc></url>`)
        .join('\n');
      fs.writeFileSync(
        path.join(root, 'sitemap.xml'),
        `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${entries}\n</urlset>\n`
      );
      this.log.info.ln(`seo: annotated ${urls.length} pages, wrote sitemap.xml`);
    }
  }
};

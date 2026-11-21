// @ts-check

// Search and link-preview metadata: meta description, canonical URL, hreflang
// alternates, Open Graph / Twitter tags and schema.org JSON-LD. The sitemap is
// VitePress's own; its lastmod and dateModified come from git (`lastUpdated`).

const DESCRIPTION_LIMIT = 200;

/** @type {Record<string, string>} */
const OG_LOCALES = { en: 'en_US', ru: 'ru_RU', es: 'es_ES' };

/**
 * Pages kept out of search results: each edition's SUMMARY.md duplicates the
 * sidebar. Readers still reach it from the introduction, and crawlers follow
 * its links.
 *
 * @param {string} page output-relative `.md` path, e.g. `en/SUMMARY.md`
 * @returns {boolean}
 */
export function isNoindex(page) {
  return page === '404.md' || /(^|\/)SUMMARY\.md$/.test(page);
}

/**
 * Shorten text to a full first sentence, or cut it on a word boundary.
 *
 * @param {string} text
 * @returns {string}
 */
export function summarize(text) {
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
 * markdown-it plugin: a page without a frontmatter `description` gets its
 * first top-level paragraph — a pattern's Intent, the lead of an introduction
 * or appendix. Anti-patterns open with "Also known as" rather than an intent,
 * so their chapters set `description` in frontmatter.
 *
 * VitePress takes the page description from the frontmatter after rendering,
 * so the rule fills it in there.
 *
 * @param {import('vitepress').MarkdownRenderer} md
 */
export function describePlugin(md) {
  md.core.ruler.push('book_description', (state) => {
    const frontmatter = state.env.frontmatter;
    if (!frontmatter || frontmatter.description) {
      return;
    }
    const at = state.tokens.findIndex(
      (token) => token.type === 'paragraph_open' && token.level === 0
    );
    const inline = at === -1 ? null : state.tokens[at + 1];
    const text = (inline?.children ?? [])
      .map((child) => {
        if (child.type === 'text' || child.type === 'code_inline') {
          return child.content;
        }
        return child.type === 'softbreak' || child.type === 'hardbreak' ? ' ' : '';
      })
      .join('');
    if (text.trim()) {
      frontmatter.description = summarize(text);
    }
  });
}

/**
 * Absolute URL of a page from its output-relative `.md` path.
 *
 * @param {string} siteUrl
 * @param {string} page e.g. `en/index.md`, `en/soft-delete.md`
 * @returns {string}
 */
function urlOf(siteUrl, page) {
  return siteUrl + page.replace(/(^|\/)index\.md$/, '$1').replace(/\.md$/, '.html');
}

/**
 * @param {object} options
 * @param {string} options.siteUrl deployed URL, ending in a slash
 * @param {string[]} options.locales locale ids; the first one is the x-default
 * @param {Record<string, string>} options.siteNames each edition's own name
 * @param {string} options.bookTitle
 * @param {{ path: string, width: number, height: number }} options.image
 *   `{locale}` in the path is replaced with the page's locale
 * @param {Record<string, Person>} options.authors the book's author, per locale
 * @returns {NonNullable<import('vitepress').UserConfig['transformHead']>}
 */
export function seoHead({ siteUrl, locales, siteNames, bookTitle, image, authors }) {
  /** @type {Set<string> | null} */
  let built = null;

  return ({ siteConfig, pageData, title }) => {
    // Output paths of every page, after README.md → index.md rewrites.
    built ??= new Set(siteConfig.pages.map((page) => siteConfig.rewrites.map[page] ?? page));
    const page = pageData.relativePath;
    if (isNoindex(page)) {
      return [['meta', { name: 'robots', content: 'noindex, follow' }]];
    }
    if (!built.has(page)) {
      return [];
    }
    const head = /** @type {import('vitepress').HeadConfig[]} */ ([]);
    const prefix = page.split('/')[0];
    const locale = locales.includes(prefix) ? prefix : null;
    const local = locale ? page.slice(locale.length + 1) : page;
    const isIndex = local === 'index.md';
    const url = urlOf(siteUrl, page);
    const siteName = (locale && siteNames[locale]) || bookTitle;
    const pageTitle = pageData.title || title;
    const description = pageData.description;

    // A page has alternates where other editions built the same file; the
    // language chooser at the root is the alternate of every introduction.
    const alternates = locales
      .filter((other) => built?.has(`${other}/${local}`))
      .map((other) => [other, urlOf(siteUrl, `${other}/${local}`)]);
    const fallback = isIndex ? siteUrl : alternates.find(([other]) => other === locales[0])?.[1];

    head.push(['link', { rel: 'canonical', href: url }]);
    if (alternates.length > 1 || locale === null) {
      for (const [other, href] of alternates) {
        head.push(['link', { rel: 'alternate', hreflang: other, href }]);
      }
      if (fallback) {
        head.push(['link', { rel: 'alternate', hreflang: 'x-default', href: fallback }]);
      }
    }

    const lang = locale ?? locales[0];
    const imageUrl = siteUrl + image.path.replace('{locale}', lang);
    /** @type {Array<[string, string]>} */
    const properties = [
      ['og:type', isIndex ? 'website' : 'article'],
      ['og:site_name', siteName],
      ['og:title', pageTitle],
      ...(description ? [/** @type {[string, string]} */ (['og:description', description])] : []),
      ['og:url', url],
      ['og:locale', OG_LOCALES[lang] ?? lang],
      ['og:image', imageUrl],
      ['og:image:width', String(image.width)],
      ['og:image:height', String(image.height)],
      ['og:image:alt', siteName]
    ];
    for (const [property, content] of properties) {
      head.push(['meta', { property, content }]);
    }
    // VitePress keeps one meta tag per property, so the repeated alternates
    // carry a leading attribute of their own to stay distinct.
    for (const [other] of alternates.filter(([other]) => other !== lang)) {
      head.push([
        'meta',
        {
          'data-locale': other,
          property: 'og:locale:alternate',
          content: OG_LOCALES[other] ?? other
        }
      ]);
    }
    if (pageData.lastUpdated) {
      head.push([
        'meta',
        {
          property: 'article:modified_time',
          content: new Date(pageData.lastUpdated).toISOString()
        }
      ]);
    }
    head.push(['meta', { name: 'twitter:card', content: 'summary_large_image' }]);

    const editionUrl = locale ? urlOf(siteUrl, `${locale}/index.md`) : siteUrl;
    const graph = structuredData({
      kind: locale === null ? 'root' : isIndex ? 'edition' : 'chapter',
      url,
      editionUrl,
      siteUrl,
      siteName,
      lang,
      title: pageTitle,
      description,
      image: imageUrl,
      author: authors[lang],
      modified: pageData.lastUpdated ? new Date(pageData.lastUpdated).toISOString() : undefined,
      editions: alternates.map(([other]) => other)
    });
    head.push(['script', { type: 'application/ld+json' }, jsonLd(graph)]);
    return head;
  };
}

/** @typedef {{ name: string, url: string }} Person */

/**
 * schema.org graph of a page: the language chooser is the WebSite, an
 * edition's introduction is the Book, a chapter is a TechArticle within it.
 *
 * @param {object} page
 * @param {'root' | 'edition' | 'chapter'} page.kind
 * @param {string} page.url
 * @param {string} page.editionUrl the introduction of the page's edition
 * @param {string} page.siteUrl
 * @param {string} page.siteName
 * @param {string} page.lang
 * @param {string} page.title
 * @param {string | undefined} page.description
 * @param {string} page.image
 * @param {Person | undefined} page.author
 * @param {string | undefined} page.modified ISO date of the last change
 * @param {string[]} page.editions locales that have this page
 * @returns {Record<string, unknown>}
 */
export function structuredData(page) {
  const author = page.author ? { '@type': 'Person', ...page.author } : undefined;
  const website = { '@type': 'WebSite', '@id': `${page.siteUrl}#website`, url: page.siteUrl };
  const book = {
    '@type': 'Book',
    '@id': `${page.editionUrl}#book`,
    name: page.siteName,
    url: page.editionUrl,
    inLanguage: page.lang,
    bookFormat: 'https://schema.org/EBook',
    isAccessibleForFree: true,
    author,
    image: page.image
  };

  if (page.kind === 'root') {
    return {
      '@context': 'https://schema.org',
      '@graph': [
        {
          ...website,
          name: page.title,
          description: page.description,
          inLanguage: page.editions
        }
      ]
    };
  }
  if (page.kind === 'edition') {
    return {
      '@context': 'https://schema.org',
      '@graph': [{ ...book, description: page.description, dateModified: page.modified }]
    };
  }
  return {
    '@context': 'https://schema.org',
    '@graph': [
      {
        '@type': 'TechArticle',
        '@id': `${page.url}#article`,
        headline: page.title,
        description: page.description,
        url: page.url,
        mainEntityOfPage: page.url,
        inLanguage: page.lang,
        image: page.image,
        author,
        dateModified: page.modified,
        isPartOf: { '@id': book['@id'] }
      },
      book,
      {
        '@type': 'BreadcrumbList',
        itemListElement: [
          { '@type': 'ListItem', position: 1, name: page.siteName, item: page.editionUrl },
          { '@type': 'ListItem', position: 2, name: page.title, item: page.url }
        ]
      }
    ]
  };
}

/**
 * JSON for a `<script>` element: undefined fields drop out, and `<` is
 * escaped so text such as `</script>` cannot end the element.
 *
 * @param {unknown} value
 * @returns {string}
 */
export function jsonLd(value) {
  return JSON.stringify(value).replace(/</g, '\\u003c');
}

/**
 * Sitemap hook: VitePress gives the language chooser at the root the default
 * language, so it and the English introduction would both claim `en`. The
 * chooser is the x-default instead, as in the pages' own hreflang tags.
 * Pages kept out of search results are left out.
 *
 * @param {Array<{ url: string, links?: Array<{ lang: string, url: string }> }>} items
 */
export function sitemapItems(items) {
  return items
    .filter((item) => !isNoindex(item.url.replace(/\.html$/, '.md')))
    .map((item) => ({
      ...item,
      links: item.links?.map((link) => (link.url === '' ? { ...link, lang: 'x-default' } : link))
    }));
}

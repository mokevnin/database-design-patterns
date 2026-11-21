import assert from 'node:assert/strict';
import { test } from 'node:test';

import { isNoindex, jsonLd, sitemapItems, structuredData, summarize } from '../.vitepress/seo.mjs';
import { sidebarFromSummary } from '../.vitepress/summary.mjs';

test('SUMMARY.md becomes a grouped sidebar', () => {
  const summary = [
    '# Summary',
    '',
    '* [Introduction](README.md)',
    '',
    '## Identity',
    '',
    '* [Surrogate Key](surrogate-key.md)',
    '* [Natural Key](natural-key.md)',
    '',
    '## Appendices',
    '',
    '* [SQL Lab](sql-lab.md)',
    ''
  ].join('\n');
  assert.deepEqual(sidebarFromSummary(summary, '/en/'), [
    { text: 'Introduction', link: '/en/' },
    {
      text: 'Identity',
      items: [
        { text: 'Surrogate Key', link: '/en/surrogate-key' },
        { text: 'Natural Key', link: '/en/natural-key' }
      ]
    },
    { text: 'Appendices', items: [{ text: 'SQL Lab', link: '/en/sql-lab' }] }
  ]);
});

test('a long description is cut at the first full sentence', () => {
  const first =
    'Soft delete marks a row as deleted instead of removing it, so the data can be restored.';
  const text = `${first} ${'The chapter shows the costs of that choice. '.repeat(5)}`;
  assert.equal(summarize(text), first);
});

test('a description without a sentence break is cut on a word boundary', () => {
  const result = summarize('word '.repeat(60));
  assert.ok(result.length <= 200);
  assert.match(result, /word…$/);
});

test('a short description is kept whole', () => {
  assert.equal(summarize('  A catalog\n of patterns. '), 'A catalog of patterns.');
});

test('the language chooser is the sitemap x-default', () => {
  const [item] = sitemapItems([
    {
      url: 'en/',
      links: [
        { lang: 'en', url: '' },
        { lang: 'en', url: 'en/' },
        { lang: 'ru', url: 'ru/' }
      ]
    }
  ]);
  assert.deepEqual(
    item.links?.map((link) => link.lang),
    ['x-default', 'en', 'ru']
  );
});

test('the tables of contents and the 404 page stay out of the sitemap', () => {
  assert.ok(isNoindex('en/SUMMARY.md'));
  assert.ok(isNoindex('404.md'));
  assert.ok(!isNoindex('en/summary-table.md'));
  const items = sitemapItems([{ url: 'en/SUMMARY.html' }, { url: 'en/summary-table.html' }]);
  assert.deepEqual(
    items.map((item) => item.url),
    ['en/summary-table.html']
  );
});

test('a chapter is a TechArticle within its edition', () => {
  const graph = structuredData({
    kind: 'chapter',
    url: 'https://example.org/en/soft-delete.html',
    editionUrl: 'https://example.org/en/',
    siteUrl: 'https://example.org/',
    siteName: 'Database Design Patterns',
    lang: 'en',
    title: 'Soft Delete',
    description: undefined,
    image: 'https://example.org/og-en.png',
    author: { name: 'Author', url: 'https://example.org/author' },
    modified: '2026-11-11T12:07:43.000Z',
    editions: ['en', 'ru']
  });
  const [article, book, breadcrumbs] = /** @type {any[]} */ (graph['@graph']);
  assert.equal(article['@type'], 'TechArticle');
  assert.deepEqual(article.isPartOf, { '@id': 'https://example.org/en/#book' });
  assert.equal(book['@id'], 'https://example.org/en/#book');
  assert.deepEqual(
    breadcrumbs.itemListElement.map((/** @type {any} */ item) => item.item),
    ['https://example.org/en/', 'https://example.org/en/soft-delete.html']
  );
  assert.ok(!('description' in JSON.parse(jsonLd(graph))['@graph'][0]));
});

test('JSON-LD cannot close its script element', () => {
  assert.equal(jsonLd({ text: '</script>' }), '{"text":"\\u003c/script>"}');
});

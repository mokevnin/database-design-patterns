import assert from 'node:assert/strict';
import { test } from 'node:test';

import { sitemapItems, summarize } from '../.vitepress/seo.mjs';
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

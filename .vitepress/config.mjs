// @ts-check

import fs from 'node:fs';
import path from 'node:path';

import { defineConfig } from 'vitepress';

import { mermaidMarkdown } from '@mokevnin/vitepress-mermaid/markdown';
import { describePlugin, seoHead, sitemapItems } from './seo.mjs';
import { sidebarFromSummary } from './summary.mjs';

const root = path.resolve(import.meta.dirname, '..');
const srcDir = path.join(root, 'book');

// Must match the deployed URL: canonical, hreflang, Open Graph and the sitemap use it.
const siteUrl = 'https://mokevnin.github.io/database-design-patterns/';
const base = new URL(siteUrl).pathname;

const bookTitle = 'Database Design Patterns';
const bookDescription = 'Database design patterns in the spirit of the Gang of Four';
const repoUrl = 'https://github.com/mokevnin/database-design-patterns';
const authorUrl = 'https://github.com/mokevnin';

/**
 * UI strings of each edition. The order is the language menu's order, and the
 * first edition is the hreflang x-default.
 */
const editions = {
  en: {
    label: 'English',
    lang: 'en',
    author: 'Kirill Mokevnin',
    ui: {}
  },
  ru: {
    label: 'Русский',
    lang: 'ru',
    author: 'Кирилл Мокевнин',
    ui: {
      outline: { label: 'На этой странице' },
      lastUpdated: { text: 'Обновлено' },
      docFooter: { prev: 'Предыдущая', next: 'Следующая' },
      darkModeSwitchLabel: 'Оформление',
      lightModeSwitchTitle: 'Светлая тема',
      darkModeSwitchTitle: 'Тёмная тема',
      sidebarMenuLabel: 'Меню',
      returnToTopLabel: 'Наверх',
      langMenuLabel: 'Язык',
      skipToContentLabel: 'К содержанию',
      notFound: {
        title: 'Страница не найдена',
        quote: 'Такой страницы нет. Возможно, глава ещё не переведена.',
        linkLabel: 'На главную',
        linkText: 'На главную'
      }
    },
    search: {
      button: { buttonText: 'Поиск', buttonAriaLabel: 'Поиск' },
      modal: {
        displayDetails: 'Подробный список',
        resetButtonTitle: 'Сбросить поиск',
        backButtonTitle: 'Закрыть поиск',
        noResultsText: 'Ничего не найдено по запросу',
        footer: { selectText: 'выбрать', navigateText: 'перейти', closeText: 'закрыть' }
      }
    }
  },
  es: {
    label: 'Español',
    lang: 'es',
    author: 'Kirill Mokevnin',
    ui: {
      outline: { label: 'En esta página' },
      lastUpdated: { text: 'Actualizado' },
      docFooter: { prev: 'Anterior', next: 'Siguiente' },
      darkModeSwitchLabel: 'Apariencia',
      lightModeSwitchTitle: 'Modo claro',
      darkModeSwitchTitle: 'Modo oscuro',
      sidebarMenuLabel: 'Menú',
      returnToTopLabel: 'Volver arriba',
      langMenuLabel: 'Idioma',
      skipToContentLabel: 'Ir al contenido',
      notFound: {
        title: 'Página no encontrada',
        quote: 'Esta página no existe. Puede que el capítulo aún no esté traducido.',
        linkLabel: 'Ir al inicio',
        linkText: 'Ir al inicio'
      }
    },
    search: {
      button: { buttonText: 'Buscar', buttonAriaLabel: 'Buscar' },
      modal: {
        displayDetails: 'Lista detallada',
        resetButtonTitle: 'Restablecer búsqueda',
        backButtonTitle: 'Cerrar búsqueda',
        noResultsText: 'Sin resultados para',
        footer: { selectText: 'seleccionar', navigateText: 'navegar', closeText: 'cerrar' }
      }
    }
  }
};

const locales = Object.keys(editions);

/**
 * @param {string} file path under book/
 * @returns {string}
 */
function read(file) {
  return fs.readFileSync(path.join(srcDir, file), 'utf8');
}

/**
 * Each edition's own name: the heading of its introduction.
 *
 * @param {string} locale
 * @returns {string}
 */
function siteNameOf(locale) {
  return /^#\s+(.+?)\s*$/m.exec(read(`${locale}/README.md`))?.[1] ?? bookTitle;
}

/**
 * Pages of an edition, relative to its folder, for the language menu.
 *
 * @param {string} locale
 * @returns {string[]}
 */
function pagesOf(locale) {
  return fs
    .readdirSync(path.join(srcDir, locale))
    .filter((file) => file.endsWith('.md'))
    .map((file) => file.replace(/^README\.md$/, 'index.md'));
}

const siteNames = Object.fromEntries(locales.map((locale) => [locale, siteNameOf(locale)]));

export default defineConfig({
  srcDir,
  outDir: path.join(root, 'dist'),
  cacheDir: path.join(root, 'node_modules', '.cache', 'vitepress'),
  // book/assets holds the chapters' SQL scripts and cover images; VitePress's
  // own bundles get a separate directory.
  assetsDir: 'static',
  base,
  title: bookTitle,
  description: bookDescription,
  lang: 'en',
  // Git commit dates: the sitemap's lastmod, the pages' dateModified and the
  // "Last updated" line. Pages CI checks out the full history for them.
  lastUpdated: true,

  head: [
    ['link', { rel: 'icon', type: 'image/svg+xml', href: `${base}assets/cover/favicon.svg` }],
    ['link', { rel: 'apple-touch-icon', href: `${base}assets/cover/apple-touch-icon.png` }]
  ],

  // GitHub renders README.md as a folder's page; the site serves it as index.
  rewrites: {
    'README.md': 'index.md',
    ':locale/README.md': ':locale/index.md'
  },

  locales: Object.fromEntries(
    Object.entries(editions).map(([locale, edition]) => [
      locale,
      {
        label: edition.label,
        lang: edition.lang,
        title: siteNames[locale],
        titleTemplate: `:title · ${siteNames[locale]}`,
        themeConfig: edition.ui
      }
    ])
  ),

  sitemap: { hostname: siteUrl, transformItems: sitemapItems },

  markdown: {
    config(md) {
      md.core.ruler.push('book_links', (state) => {
        for (const token of state.tokens) {
          for (const child of token.children ?? []) {
            const href = child.type === 'link_open' ? child.attrGet('href') : null;
            if (!href || /^[a-z]+:|^\/\/|^#/i.test(href)) {
              continue;
            }
            // Links to README.md (the introduction, from SUMMARY.md) point at
            // the rewritten index page.
            child.attrSet('href', href.replace(/(^|\/)README\.md(?=$|#)/, '$1index.md'));
            // Files such as ../assets/<slug>/<slug>.sql are not pages: a
            // target keeps VitePress from treating them as routes.
            if (/\.(?!md$|html$)[a-z0-9]+$/i.test(href.replace(/[?#].*$/, ''))) {
              child.attrSet('target', '_self');
            }
          }
        }
      });
      describePlugin(md);
      md.use(mermaidMarkdown);
    }
  },

  vite: {
    build: {
      // The local search index of a long edition is one chunk of about a
      // megabyte; it loads only when the reader opens search.
      chunkSizeWarningLimit: 2000
    }
  },

  // An edition's introduction is titled with the edition's own name; the
  // template would repeat it.
  transformPageData(pageData) {
    if (/(^|\/)index\.md$/.test(pageData.relativePath)) {
      return { titleTemplate: false };
    }
  },

  transformHead: seoHead({
    siteUrl,
    locales,
    siteNames,
    bookTitle,
    image: { path: 'assets/cover/og-{locale}.png', width: 1200, height: 630 },
    authors: Object.fromEntries(
      Object.entries(editions).map(([locale, edition]) => [
        locale,
        { name: edition.author, url: authorUrl }
      ])
    )
  }),

  buildEnd(siteConfig) {
    // Vite copies only what pages import; chapters link to these files directly.
    fs.cpSync(path.join(srcDir, 'assets'), path.join(siteConfig.outDir, 'assets'), {
      recursive: true
    });
  },

  themeConfig: {
    sidebar: Object.fromEntries(
      locales.map((locale) => [
        `/${locale}/`,
        sidebarFromSummary(read(`${locale}/SUMMARY.md`), `/${locale}/`)
      ])
    ),
    outline: { level: [2, 3] },
    socialLinks: [
      { icon: 'github', link: repoUrl, ariaLabel: 'GitHub' },
      {
        icon: 'telegram',
        link: 'https://t.me/orgprog',
        ariaLabel: 'Organized Programming (Telegram)'
      },
      {
        icon: 'youtube',
        link: 'https://www.youtube.com/@mokevnin',
        ariaLabel: 'Organized Programming (YouTube)'
      }
    ],
    // Read by i18nRouting: an untranslated page switches to the edition's start.
    editionPages: Object.fromEntries(locales.map((locale) => [locale, pagesOf(locale)])),
    // Serialized into the client bundle, so it may only use its arguments.
    i18nRouting: (data, route, targetLocale) => {
      const current = route.data.relativePath;
      const local = current.includes('/') ? current.slice(current.indexOf('/') + 1) : current;
      const pages = data.theme.value.editionPages?.[targetLocale] ?? [];
      return pages.includes(local) && local !== 'index.md'
        ? `/${targetLocale}/${local.replace(/\.md$/, '.html')}`
        : `/${targetLocale}/`;
    },
    search: {
      provider: 'local',
      options: {
        locales: Object.fromEntries(
          Object.entries(editions)
            .filter(([, edition]) => 'search' in edition)
            .map(([locale, edition]) => [locale, { translations: edition.search }])
        )
      }
    }
  }
});

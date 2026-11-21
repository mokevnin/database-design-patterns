// @ts-check

import { enhanceAppWithMermaid } from '@mokevnin/vitepress-mermaid/client';
import DefaultTheme from 'vitepress/theme';

import dark from '../../mermaid.config.dark.json';
import light from '../../mermaid.config.json';

import '@mokevnin/vitepress-mermaid/style.css';

/** @typedef {import('mermaid').MermaidConfig} MermaidConfig */

/**
 * The dark palette merged over the light one. The dark file holds only what
 * differs; nested sections merge key by key.
 *
 * @type {MermaidConfig}
 */
const darkConfig = { ...light, ...dark };
for (const section of /** @type {const} */ ([
  'themeVariables',
  'flowchart',
  'sequence',
  'sankey'
])) {
  darkConfig[section] = { ...light[section], ...dark[section] };
}

/**
 * vitepress-mermaid takes one config and redraws every diagram when the page
 * theme toggles, spreading the config afresh on each draw. Getters make that
 * spread pick the palette of the current theme.
 *
 * @param {MermaidConfig} lightConfig
 * @param {MermaidConfig} darkConfigValue
 * @returns {MermaidConfig}
 */
function themedConfig(lightConfig, darkConfigValue) {
  const isDark = () => document.documentElement.classList.contains('dark');
  const keys = new Set([...Object.keys(lightConfig), ...Object.keys(darkConfigValue)]);
  /** @type {PropertyDescriptorMap} */
  const properties = {};
  for (const key of keys) {
    properties[key] = {
      enumerable: true,
      get: () =>
        (isDark() ? darkConfigValue : lightConfig)[/** @type {keyof MermaidConfig} */ (key)]
    };
  }
  return Object.defineProperties({}, properties);
}

/** @type {import('vitepress').Theme} */
export default {
  extends: DefaultTheme,
  enhanceApp({ app }) {
    enhanceAppWithMermaid(app, themedConfig(/** @type {MermaidConfig} */ (light), darkConfig));
  }
};

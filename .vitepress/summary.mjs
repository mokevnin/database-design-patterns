// @ts-check

// Each edition's SUMMARY.md is the single source of the chapter order and
// grouping; the sidebar is generated from it rather than kept in the config.

/** @typedef {import('vitepress').DefaultTheme.SidebarItem} SidebarItem */

/**
 * Sidebar link of a SUMMARY.md target, e.g. `soft-delete.md` → `/en/soft-delete`.
 *
 * @param {string} target
 * @param {string} prefix locale prefix such as `/en/`
 * @returns {string}
 */
function linkOf(target, prefix) {
  return prefix + target.replace(/(^|\/)README\.md$/, '$1').replace(/\.md$/, '');
}

/**
 * Parse a Honkit-style summary: `## Group` headings, each followed by a
 * bulleted list of `[Title](file.md)` links. Links above the first heading
 * become top-level entries.
 *
 * @param {string} summary contents of SUMMARY.md
 * @param {string} prefix locale prefix such as `/en/`
 * @returns {SidebarItem[]}
 */
export function sidebarFromSummary(summary, prefix) {
  /** @type {SidebarItem[]} */
  const sidebar = [];
  /** @type {SidebarItem | null} */
  let group = null;
  for (const line of summary.split('\n')) {
    const heading = /^##\s+(.+?)\s*$/.exec(line);
    if (heading) {
      group = { text: heading[1], items: [] };
      sidebar.push(group);
      continue;
    }
    const entry = /^\s*[*-]\s+\[(.+?)\]\((.+?)\)\s*$/.exec(line);
    if (entry) {
      const item = { text: entry[1], link: linkOf(entry[2], prefix) };
      (group?.items ?? sidebar).push(item);
    }
  }
  return sidebar;
}

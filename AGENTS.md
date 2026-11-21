# AGENTS.md

Operating guide for agents (and humans) working in this repository.

## Language

- Book content lives in `book/<locale>/` (ru/en/es); localized chapter skeletons in `templates/<locale>/`.
- Everything else — READMEs, configs, CI, and the `book/` chrome outside locale folders — is written in **English**.
- Book prose addresses the reader as «вы» in `ru` ("you" in `en`), never «ты». The `es` edition addresses the reader as «tú».

## Diagrams

- Use diagrams generously: a chapter has 3–5 of different types, each showing a real mechanism, never decoration. Schema is shown as `erDiagram`; besides it, typical ones are a `sequenceDiagram` of two sessions racing and where a constraint or lock stops one, the steps of a migration, a lifecycle as `stateDiagram-v2`, a decision flowchart leading to sibling patterns, and before/after schemas for anti-patterns. Each has a `title:` caption stating its point and a sentence or two after it saying what to notice.
- Diagrams are written as ```` ```mermaid ```` fences directly in the chapter, so the labels are translated together with the prose and GitHub renders them in the repo.
- [`@mokevnin/vitepress-mermaid`](https://github.com/mokevnin/vitepress-mermaid) turns the fences into a `<Mermaid>` component that draws the diagram in the browser and redraws it when the theme toggles. `vitepress build` therefore does not catch Mermaid syntax errors: open the changed pages and look for a red source block (`[data-mermaid-error]`).
- Shared palette and theme live in `mermaid.config.json`. Use the `accent`, `warn` and `muted` classes (`node:::accent`) instead of per-diagram `classDef`.
- Every diagram also comes in a dark palette for the VitePress dark mode (wired in `.vitepress/theme/index.mjs`): `mermaid.config.dark.json` holds only the keys that differ and is merged over `mermaid.config.json`. A new color or class in the light config needs its dark counterpart there, including the `accent`/`warn`/`muted` rules in `themeCSS`.
- Use the widest range of Mermaid diagram types the content allows; every type is allowed. `erDiagram` is the main one for this book: tables with key columns, PK/FK/UK markers and crow's-foot cardinalities wherever a chapter shows a schema. Beyond it, pick the type that fits the mechanism: `sequenceDiagram` for concurrent sessions and message flows, `stateDiagram-v2` for lifecycles, `flowchart` for decisions and migration steps, `timeline` and `gantt` for periods and validity over time, `block-beta` and `packet-beta` for physical layouts and bit layouts of identifiers, `gitGraph` for schema versions, `quadrantChart` for trade-off maps, `xychart-beta` and `pie` for measurements and shares, `sankey-beta` for flows of values, `mindmap` for families of patterns, `classDiagram` for the object-to-table mapping.
- `sankey-beta` accepts **ASCII only in node names** (Mermaid 12.0.0) — quoting does not help, and Cyrillic or even Spanish accents raise a parse error. Its `title:` and `%%` comments do take non-ASCII. Where it is used, node labels stay English with a `%% TODO` to localize them once upstream is fixed.
- Types that silently drop the frontmatter `title:` the book uses as a caption: `sankey-beta`, `mindmap`, `timeline`, `kanban`, `block-beta`, `architecture-beta`. Put the thesis in the paragraph under the diagram instead. `treemap-beta` scales label size with box area, so the smallest — usually most important — share is the least readable.
- A diagram is read inside a ~690px column (the VitePress content width). Keep it under ~1200px wide — prefer `flowchart TB` over a long left-to-right chain, and remember that a note hung off a node with `-.-` widens the diagram.

## Markdown formatting

- Do not hard-wrap prose to a fixed column width. Keep each paragraph, list item, and blockquote on one physical source line; use line breaks only for intentional Markdown structure such as headings, separate list items, tables, fenced code, and paragraph boundaries.

## Commits

- Follow [Conventional Commits](https://www.conventionalcommits.org/), written in **English**.
- Enforced by [commitlint](https://commitlint.js.org/) in the `commit-msg` git hook ([hk](https://hk.jdx.dev), `hk.pkl`, installed by the `postinstall` hook in `mise.toml` on every `mise install`) and over the PR range in CI.
- Examples: `feat: add soft delete pattern`, `docs: translate preface to es`, `ci: bump actions to latest`.

## Checks

- `mise run check` runs every check (jactionlint, betterleaks, typos, rumdl, agnix, oxlint, oxfmt, syncpack, local links, merge/case conflicts and symlinks) and must pass before a change is done; CI runs the same task, and the hk `pre-commit` hook runs the same steps on staged files. Steps live in `hk.pkl`. `mise run fix` applies the safe autofixes. Tool versions are pinned in `mise.toml` and `mise.lock`; pnpm is read from `package.json`. Oxfmt formats code and configuration; rumdl owns Markdown.
- `.agents/skills/` (and the `.claude/skills/` symlinks into it) are vendored and pinned by hash in `skills-lock.json`: never edit them by hand.
- Prefer an existing tool over a hand-written script, and install tools through `mise`, never through shell fallback chains.
- Never disable a lint rule to get a change through. An exception is narrow (one path, one rule), carries a reason in the config, and needs a human decision.

## Build / preview

- Use mise 2026.11.3 or newer; CI pins 2026.11.8. Commit `mise.lock` alongside tool updates; it covers Linux x64 and macOS arm64.
- `mise run setup` — install locked deps, pinned linters and git hooks
- `mise run serve` — local preview (VitePress dev server)
- `mise run build` — static build into `./dist`
- `mise run preview` — serve `./dist` under the deployed base path
- The site is VitePress 2 with `srcDir: book`; config lives in `.vitepress/`. Each `README.md` is served as its folder's `index.html` (`rewrites`), and `book/assets/` is copied into the build as is, so chapters link to scripts with plain relative paths.
- `.vitepress/seo.mjs` fills each page's `<head>`: meta description, canonical, hreflang, Open Graph/Twitter tags and schema.org JSON-LD (WebSite at the root, Book for an edition's introduction, TechArticle with breadcrumbs for a chapter); VitePress writes the sitemap. `SUMMARY.md` pages and the 404 page are `noindex` and left out of the sitemap. Dates (sitemap `lastmod`, `dateModified`) come from git via `lastUpdated`, so the Pages workflow checks out the full history. The description is the frontmatter `description:` or else the first paragraph (see CONTRIBUTING.md); the preview image is `book/assets/cover/og-<locale>.png`, the favicon `book/assets/cover/favicon.svg`. `siteUrl` in `.vitepress/config.mjs` must match the deployed URL. A project site under a path has no `robots.txt` of its own: the sitemap is submitted in Google Search Console and Yandex Webmaster.
- Chapters are compiled as Vue templates: `{{ ... }}` in prose outside code spans and fences is evaluated, so keep such text inside backticks.
- `mise run update` — bump project tools and dependencies; when hk changes, also update both versioned Pkl imports in `hk.pkl`

## Structure conventions

- Chapter titles are short GoF-style noun names, 1–3 words per locale; the source's long name goes under «Также известен как».
- Write chapters in `en` first, each with its `SUMMARY.md` entry, and maintain the `ru` translation with matching files, navigation and `source_rev`. The `es` edition is deferred to a separate translation pass; until then leave its folder, `SUMMARY.md` and `candidates.md` untouched.
- Patterns are flat files `book/<locale>/<slug>.md`; grouping lives only in `book/<locale>/SUMMARY.md`.
- Shared binary assets and code samples in `book/assets/<slug>/`, referenced via `../assets/<slug>/...`. Diagrams are not assets — see above.
- Canonical locale is `en`: write a pattern in English first; translations follow from it.
- New pattern ideas are tracked in [CANDIDATES.md](CANDIDATES.md) — check it before writing a chapter, and record accepted/rejected there.
- See [CONTRIBUTING.md](CONTRIBUTING.md) for the full authoring workflow.

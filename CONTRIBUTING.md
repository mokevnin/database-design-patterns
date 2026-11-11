# Contributing

The book is built from markdown with [Honkit](https://github.com/honkit/honkit). Navigation and grouping come from `book/<locale>/SUMMARY.md` — a separate file per language.

## Add a new pattern

0. Check [CANDIDATES.md](CANDIDATES.md) first. New ideas start there as a `candidate` row; adding a chapter means moving the idea to `accepted`. Rejected ideas stay documented so we don't reconsider them by accident.
1. Pick a kebab-case `slug` (e.g. `soft-delete`). It becomes the file name in every locale and the key under `book/assets/`.
2. Create the chapter in the canonical locale: copy [`templates/en/pattern.md`](templates/en/pattern.md) to `book/en/<slug>.md` and fill it in. Do not change the section headings — they are the same across all chapters of that language.
3. Add a link in `book/en/SUMMARY.md` under the right group heading (line order = order in the book).
4. Draw diagrams as ```` ```mermaid ```` fences right in the chapter — they are rendered to SVG at build time and translated together with the surrounding text. Use the shared `accent` / `warn` / `muted` classes (`node:::accent`) so every diagram in the book shares one palette; the theme lives in `mermaid.config.json`, and its night-theme counterpart in `mermaid.config.dark.json`.
5. Anything that is genuinely a file — images, runnable SQL scripts with the engine version they were checked on — goes in `book/assets/<slug>/` and is referenced with a relative path `../assets/<slug>/...`.
6. Preview with `pnpm start`.

## Extend an existing pattern

The book has no margin notes or comment threads: an addition becomes part of the chapter text.

1. Decide where it belongs. A new step, variant, consequence, or pitfall of the same technique goes into the matching template section of that chapter (`Implementation`, `Consequences and trade-offs`, `Anti-patterns and common mistakes`, and so on). If the idea works on its own and is useful outside this pattern, it is a candidate for a separate chapter — add it to [CANDIDATES.md](CANDIDATES.md) and link it from `Related patterns` instead.
2. For anything larger than a wording fix, open an issue first and describe the addition and the experience behind it, so the placement can be agreed before you write.
3. Edit `book/en/<slug>.md` first. Keep the template headings; extend a section rather than adding a new one.
4. Translations are deferred for now (see below). Once `ru` and `es` editions exist, update them in the same PR if you can and refresh `source_rev` in every translation you touch.

Anti-patterns go into the "Anti-patterns" group of `SUMMARY.md` and use `templates/<locale>/anti-pattern.md`. Name the harmful condition, say when the original choice is defensible, and give the source's term (for example, Karwin's) under "Also known as".

## Chapter front matter (optional but useful)

Honkit takes the title from the first `#` and navigation from `SUMMARY.md`. A small front matter is handy as metadata and reads well on GitHub:

```yaml
---
group: data-modeling     # area (mirrors the heading in SUMMARY.md)
status: draft            # draft | review | translated | done
related: [some-slug]
source_rev:              # for NON-canonical locales only (see below)
---
```

## Translation

- The canonical locale is `en` (`language` in `book/book.json`). A pattern is written in English first. For now the book is written in `en` only; `ru` and `es` are translated later in a separate pass.
- To translate, copy `book/en/<slug>.md` to `book/<locale>/<slug>.md`, translate the text, and add a link to `book/<locale>/SUMMARY.md` in the same group. Use the matching template under `templates/<locale>/` for the localized headings.
- In the translation's front matter set `source_rev` — the git SHA of the en chapter at the time of translating, so staleness can be tracked:

  ```sh
  git log -1 --format=%H -- book/en/<slug>.md
  ```

## Conventions

- Do not hard-wrap Markdown prose to a fixed column width. Keep each paragraph, list item, and blockquote on one physical source line; use line breaks only for intentional Markdown structure.
- Inside `book/<locale>/` chapters are a flat list — no group folders.
- Once a locale's translation is complete, its set of `<slug>.md` files and `SUMMARY.md` structure should match the canonical English edition. Until translation begins, leave the deferred `ru` and `es` editions unchanged.
- Assets are shared in `book/assets/` — do not duplicate images per locale.
- All text outside the language folders (`book/<locale>/`) and the localized templates is in English.

For environment setup and commit conventions, see [AGENTS.md](AGENTS.md).

## Reader-facing candidates

`CANDIDATES.md` is the authoritative backlog. Keep the brief candidate list in `book/en/candidates.md` synchronized (the `ru` and `es` lists follow when those editions are translated) when a candidate is added, renamed, accepted, completed, or rejected. Include rows with status `candidate`; once a topic leaves that status, remove it from the brief list and update its existing discussion with the outcome and the chapter link, if available.

Reader discussions use GitHub Issues with the title `[Candidate] <slug>`. Search open and closed issues before creating one; reuse the existing thread to preserve votes. Readers vote with a thumbs-up reaction on the opening post. Keep the slug consistent across locales so all three editions link to the same discussion. The issue template supplies the common format; votes inform editorial priority rather than automatically accepting chapters.

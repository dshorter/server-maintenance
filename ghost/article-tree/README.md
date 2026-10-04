# Ghost article tree

The homepage and paginated post list use a two-branch browse tree within Source
1.5.0's existing sidebar layout. It adds one Handlebars partial and small
edits to `home.hbs`, `index.hbs`, and `post-list.hbs`. Native `<details>`
elements provide expand/collapse behavior. There is no client-side API call,
JavaScript navigation library, route change, or duplicate post database.

Ghost owns the membership of each branch. Give each post exactly one of these
internal tags when it joins the editorial library:

- `#nav-predictor-suite` — Predictor Suite articles.
- `#nav-beyond-predictor` — other Uzelhub articles.

Public topic tags remain separate. The theme's `{{#get "posts"}}` queries
return published posts only; assigned drafts do not appear in the tree.
The old `Coming soon` post has neither navigation tag. The article tree is
shown on the homepage and paginated post list. The normal top navigation,
article routes, tag archives, and existing Predictor branding remain intact.

The two queries each have Ghost's 100-post maximum. If either branch approaches
that size, split it into a few named subbranches with their own internal tags
and add a paginated browse page. Do not put the draft corpus into the menu.

The deployment helper checks the exact prior theme files, compiles every
Handlebars template, backs up changed files under
`/var/backups/ghost-article-tree/`, applies only these four files, restarts
Ghost, and verifies the live pages. It restores the prior files on failure.
The existing branding partials in `ghost/predictor-branding/` are unaffected.

Run preflight from the host:

```sh
python3 /opt/server-maintenance/scripts/deploy-article-tree.py
```

Apply after reviewing the four-file diff:

```sh
python3 /opt/server-maintenance/scripts/deploy-article-tree.py --apply
```

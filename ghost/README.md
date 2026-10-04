> **2026-10-04 article navigation:** The homepage and paginated post list now
> use a two-branch browse tree driven by Ghost internal tags and `{{#get}}`.
> See [article-tree/README.md](article-tree/README.md) for the tag contract,
> scoped Source templates, and the backed-up deployment helper. Theme upgrades
> must preserve this partial as well as the Predictor branding below.

> **2026-10-04 follow-up — current source:** The operator clarified that this
> blog records the creation of Predictor Ingest and Predictor Explorer through
> zero-code AI orchestration. The active header/footer source and manifest are
> now in `predictor-branding/`. Use
> `python3 /opt/server-maintenance/scripts/deploy-predictor-branding.py` for
> preflight and add `--apply` for deployment. It backs up and verifies the
> affected theme files and six explicitly scoped Ghost settings, with recovery
> on failure. The first footer files and helper below are retained as history;
> do not use them to overwrite the current branding. Explicit theme replacement
> still requires reviewing and preserving these custom partials.

# Uzelhub Ghost footer

Added 2026-10-04 at the operator's request. `source-footer.hbs` replaces Source
1.5.0's shared `partials/components/footer.hbs`. It explains the publication's
product and AI-orchestration purpose, links to the public Uzelhub site, and
preserves the native subscription component, custom signup text settings, and
Ghost attribution. Scoped CSS is kept with the partial so the change has one
maintained template and no additional client-side script.

The bundled Source theme originally lived behind a symlink into the Ghost
container image. Deployment first copies that theme into the persistent content
volume, then replaces the verified symlink with the copy. It keeps the active
theme name `source`; no Ghost settings or article records are changed.

Run preflight on the host:

```sh
python3 /opt/server-maintenance/scripts/deploy-ghost-footer.py
```

Deploy after previewing the proposed footer:

```sh
python3 /opt/server-maintenance/scripts/deploy-ghost-footer.py --apply
```

The helper checks the prior footer hash and Handlebars syntax, preserves the
original theme and footer in a dated `/var/backups/ghost-footer/` directory,
restarts only Ghost, and verifies the homepage, a published article, About, and
a tag archive. A failed verification restores the prior footer or theme link,
restarts Ghost, and checks recovery. Repeating the same deployment verifies
the live result without another restart.

The copy survives container replacement because it lives in the content volume.
An explicit theme replacement or upload may overwrite it. Re-review theme
compatibility and this footer before a theme upgrade; the helper refuses an
unexpected footer revision. For manual recovery, use the dated manifest and
original-theme copy in the backup directory rather than restoring a database.

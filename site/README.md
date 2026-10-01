# tallmadge.dev

The project hub for Tallmadge (`clpr`) and related projects, built with
[Eleventy](https://www.11ty.dev/) and deployed to GitHub Pages via GitHub
Actions (no `gh-pages` branch, no Jekyll).

## Local development

Node is pinned in the repo-root `.mise.toml` (CI installs the same version
via `jdx/mise-action`, so the two can't drift):

```bash
mise install        # once, to get the pinned Node
cd site
npm install
npm run dev         # dev server at http://localhost:8080
npm run build       # static output in site/_site
```

Note: pages link assets and anchors with relative paths (`styles.css`,
`#projects`), so single pages can be previewed by opening the built HTML
directly. If you add pages in subdirectories, switch the layout to absolute
paths or Eleventy's `url` filter.

## Deployment

`.github/workflows/site.yml` builds the site and deploys it to Pages on every
push to `main` that touches `site/**` (or manually via `workflow_dispatch`).

One-time setup in GitHub:

1. **Settings → Pages → Build and deployment → Source**: select
   **GitHub Actions**.
2. After the first deploy, verify `tallmadge.dev` under **Settings → Pages**
   and tick **Enforce HTTPS** (required — `.dev` is on the HSTS preload list).

## DNS

Point the domain at GitHub Pages:

| Record | Name | Value |
| --- | --- | --- |
| A | `@` | `185.199.108.153` |
| A | `@` | `185.199.109.153` |
| A | `@` | `185.199.110.153` |
| A | `@` | `185.199.111.153` |
| CNAME | `www` | `kplawver.github.io` |

The `site/src/CNAME` file is copied into the build output so the custom
domain survives every deploy.

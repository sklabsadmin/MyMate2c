# Brand & source art

Kept in the repo, deliberately **outside `assets/images/`** — `pubspec.yaml`
globs that whole directory, so anything left in it is bundled into every
deploy even when no code references it. (Flutter only *downloads* an asset
when something loads it, so dead art costs deploy payload rather than user
bandwidth — still worth keeping out.)

- `MythCompIcon.jpg` — the Mythos Companion logo lockup. Source for the web
  icons, the native launcher icons and the splash. Regenerate from this rather
  than editing the outputs.
- `MythosNOtextLogo.png` — the Mythos Live medallion, no wordmark. Source for
  the web favicons (`web/favicon-32/48.png`), `web/icons/*` and the native
  launcher icons. Regenerate from this rather than editing the outputs.
- `MythosLiveLogo.png` — the same medallion with the wordmark. Splash art.
- `splash_logo.png` — superseded splash art, kept for reference.
- `avatar_andromache_real-v3-source.jpg` — full-resolution source for the
  current Andromache portrait. The shipped copy in `assets/images/` is
  downscaled to 1024px to match the rest of the roster; re-crop from this.
- `avatar_andromache_real-v2.jpg`, `avatar_andromache_real-v1.png` —
  superseded portraits, kept for reference.
- `legacy/` — earlier avatar versions no code refers to any more.

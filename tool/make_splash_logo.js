#!/usr/bin/env node
/**
 * Regenerate the web splash logo variants from the brand source.
 *
 *   node tool/make_splash_logo.js
 *
 * Why WebP: the logo is a dense pastel illustration, which PNG encodes badly —
 * the previous PNG splash cost 886KB at 3x, on a screen whose entire purpose is
 * to appear before the 3MB bundle does. The same art as WebP is ~79KB. The 1x
 * PNG is kept only as a <picture> fallback for anything without WebP support.
 *
 * The source lives in brand/ rather than assets/images/ because pubspec.yaml
 * globs assets/images/ wholesale, so anything there is bundled into every
 * build whether or not Dart references it (see brand/README.md).
 */
const sharp = require("sharp");
const fs = require("fs");

const SRC = "brand/mythoslive_logoDark.png";
const OUT = "web/splash/img";
const SIZES = { "1x": 256, "2x": 512, "3x": 768, "4x": 1024 };

if (!fs.existsSync(SRC)) {
  console.error(`missing source: ${SRC}`);
  process.exit(1);
}

(async () => {
  for (const [name, px] of Object.entries(SIZES)) {
    const out = `${OUT}/logodark-${name}.webp`;
    const { size } = await sharp(SRC)
      .resize(px, px, { fit: "contain" })
      .webp({ quality: 82, effort: 6 })
      .toFile(out);
    console.log(`  ${out}  ${px}px  ${(size / 1024).toFixed(0)} KB`);
  }
  // Fallback only — never referenced when the browser understands WebP.
  const fallback = `${OUT}/logodark-1x.png`;
  const { size } = await sharp(SRC)
    .resize(SIZES["1x"], SIZES["1x"], { fit: "contain" })
    .png({ compressionLevel: 9 })
    .toFile(fallback);
  console.log(`  ${fallback}  ${SIZES["1x"]}px  ${(size / 1024).toFixed(0)} KB  (fallback)`);
})();

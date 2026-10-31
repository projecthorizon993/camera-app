# Extraction notes (Task 22a)

Tooling + inventory for deriving clean-room colour looks, lens profiles and
watermark template geometry from the read-only camera-app dumps.

> **Clean-room status.** These notes describe *measured* structure and *derived*
> numbers only. No vendor code, binary, image, logo or trademark string is
> reproduced here or elsewhere in this repository. Vendor names are replaced by
> generic labels:
>
> * **vendor A** — the phone-camera app whose decompiled Java **sources +
>   resources** live under the local dump's `*-jadx/` tree (premium-lens
>   partnership brand).
> * **vendor B** — the medium-format camera brand whose **split APK set** lives
>   under the local dump's `*-mobile/` tree (app product name withheld).
>
> The exact local folder names are recorded in the task report (kept outside the
> repo, under `.superpowers/`); they are intentionally not written here.

Local note: the task brief stated Python is not installed on the dev machine.
In practice a `py`-launcher **Python 3.13.3** (with numpy 2.4.6 +
opencv 5.0.0) was available, so `python -m compileall scripts`, `selftest.py`
and the read-only scans below were **actually executed locally** against the
dumps (outputs written to the system temp dir only — nothing dump-derived was
committed). CI still targets Python 3.12; the code avoids 3.13-only features.
The syntax gate and happy-path gate below remain the CI contract.

---

## 1. Toolchain

| Script | Purpose |
|--------|---------|
| `scripts/extract_apk_assets.py` | Unpack an APK / split-APK set / XAPK into a scratch dir + print an inventory (counts by extension, top dirs, total size). Handles `config.*.apk` split naming and `.xapk` bundles. Pure stdlib. |
| `scripts/parse_luts.py` | Find colour-look candidates: `.cube`, **tiled 3D-LUT PNGs** (primary), binary float/half grids, Java numeric tables. `--inventory` reports; extraction mode emits `.cube` + provenance sidecar. Stdlib PNG decode (8-bit RGB/RGBA); OpenCV fallback for 16-bit/palette. |
| `scripts/parse_watermarks.py` | Convert watermark **template geometry** (layout JSON / resource XML / Java view classes) into the `WatermarkTemplate` schema. Sanitises vendor tokens to `vendor_a`… before output. |
| `scripts/validate_looks.py` | Apply a `.cube` to an image (trilinear default, tetrahedral optional) via numpy (+ opencv-python-headless for I/O); also `--make-gradients` to create tiny test inputs. |
| `scripts/ghidra_find_tables.py` | **Skeleton** (not implemented) for locating native LUT/lens tables in `.so` files with Ghidra headless. |
| `scripts/selftest.py` | CI happy-path checks over `scripts/testdata/`. |

Typical workflow:

```bash
# 0) unpack to scratch (never into the repo)
python scripts/extract_apk_assets.py --apk <dump>/<vendorB>-mobile --out /tmp/vb
python scripts/extract_apk_assets.py --apk <dump>/<vendorA>-jadx --out /tmp/va

# 1) inventory colour looks (no extraction)
python scripts/parse_luts.py --scan /tmp/va --inventory --out /tmp/luts.json

# 2) extract tiled PNG LUTs to a scratch dir
python scripts/parse_luts.py --scan /tmp/va --extract-dir /tmp/cubes

# 3) watermark geometry
python scripts/parse_watermarks.py --scan /tmp/va --out /tmp/wm.json
```

---

## 2. Inventory highlights (measured)

### 2.1 Colour LUTs — **found, cleartext** (vendor A)

The decisive find: the app ships its picture-style / filter 3D LUTs as
**plain tiled PNGs under `resources/res/raw/`** (names `lut_*.png`).

* `versionName`-style naming: `lut_normal_*`, `lut_video_*`, `lut_cg_*`,
  `lut_effect_*`, `lut_log_*`, `lut_makeup_*`, `lut_portrait_*`,
  `lut_cvstyle_*`, `lut_aiscene_*`, `lut_ai_mode_*`, `lut_lighting_*`,
  `lut_n_*` (tuning deltas), … (~276 `lut_*` files).
* **Tile layout** (confirmed from IHDR + tile-count arithmetic):
  * `512×512`, RGB (colour type 2) — **64³ LUT**, 8×8 tiles of 64 px → **143 files**.
  * `64×64`, RGB — **16³ LUT**, 4×4 tiles of 16 px → **103 files**.
  * `512×512`, RGBA (colour type 6) → 1 file.
* `assets/hdrLut.png` — `512×512` RGBA → a 64³ LUT with an alpha channel
  (HDR transfer / gamut mapping candidate).
* `assets/cloudfilter/cloud_filter_{custom,not_custom}.json` — **catalogue
  metadata only** (category ids, filter ordering, a CDN `translation` URL). The
  actual downloaded filter payloads are not in the dump.
* `assets/cg/cg*.zip` — "cg" template packs; contents are `cover*.webp` +
  `info.json` only (thumbnail/metadata, **no LUT payload**).
* `assets/icc/wcg.icc` — a tiny (632 B) ICC profile (wide-gamut container;
  header `mntr`/`acsp`), byte entropy ≈ 4.0. A display/working-space profile,
  not a 3D LUT.
* Shaders (`fragmentShader.frag`, `vertexShader.vert`, `waveformCompute.glsl`,
  `music_player_tracker*.frag`) — viewfinder/waveform GLSL; no LUT sampling
  shader is present in cleartext (see follow-ups).

**Obfuscated subset (flagged + excluded by `parse_luts`).** Of the 276 `lut_*`
files, **29 are not PNGs** despite the extension: 5 are JPEG (`FFD8`), and 24
have high-entropy, non-image magic bytes (e.g. leading bytes `04 F0`, `2F 42`,
`7C 04`, …). These are almost certainly obfuscated/encrypted variants.
`parse_luts.py` reports them as `obfuscated_container` with `excluded: true`
and a reason instead of guessing.

**Measured inventory** (`parse_luts.py --scan <vendorA>/resources --inventory`):
`png_lut` 253 (145 × 64³ incl. the RGBA file, 103 × 16³, 5 × 128×128 secondary
guess), `obfuscated_container` 27, `image_not_lut` 258, `png_unclassified` 6.
Real extraction was verified end-to-end on one cleartext file: a 512×512 LUT
decoded to a 64³ `.cube` (7.3 MB) + provenance sidecar (SHA-256 of the source).

### 2.2 Watermark templates — **found, declarative** (vendor A)

Watermark geometry is fully declarative and cleanly scannable:

* `assets/watermarks/**/config.json` (still photos) and
  `assets/video_watermarks/**/config.json` (video) — a `layout_group` view tree
  (`Layout` / `TextView` / `ImageView` / divider `Layout`s) plus a `wmRes` block
  of font specs and colour palettes. Example geometry observed:
  * root `all_content` gravity `center`; bottom bar with `left_bottom_group`
    (`margin_left 50dp`) and `right_bottom_group` (`margin_left -50dp`);
  * `bottom_padding1` height `39dp`, `bottom_padding2` height `41dp`;
  * **vertical dividers** `*_line_layout` = `2dp` wide × `24dp` tall,
    coloured via `@foreground=1`;
  * fonts `f1…f4` = sizes `36/24/22/28`, weights from a variable-font axis
    (`'wght' 451–501`), small `letterSpacing` (0.01–0.04);
  * background palettes `white` (`#FFFFFFFF`), `black` (`#FF141414`),
    `light_blur`/`dark_blur` (`@algo=…`) with foreground ramps such as
    `#FF000000 / #4D000000 / #BF000000 / #80000000`.
  `parse_watermarks.py` turns these into `WatermarkTemplate` JSON
  (`id / displayName / lines[] / divider / alignment / fontScale /
  textColorHex / backgroundBar`), preserving the **line order** and dp geometry.
  Measured on the real tree: **47 templates**, 481 resource candidates,
  62 layout candidates, 194 AI-catalogue entries, and **no vendor token leaks**
  (all mapped to `vendor_a`/`vendor_d`). Caveat: a template's `lines[]` flattens
  every `layout_group` variant, so multi-ratio configs repeat their line set —
  acceptable for geometry, noted for a future ratio-aware pass.
* `res/raw/ai_watermark.xml` — an AI-spot catalogue (`<watermark><key><type>`),
  geography-keyed (generic place names, no brand marks).
* `res/values/strings.xml`, `colors.xml`, `arrays.xml` — watermark UI strings,
  `watermark_*` colour resources, and a watermark-style enum
  (`watermark_off / watermark_regular / watermark_<vendorA-product-lines> / …`).
  The enum items are reported only as **resource candidates** and are sanitised.
* `assets/obfu_res/res/*.xml` — obfuscated resource XML (single-letter names);
  scanned on a best-effort keyword basis, not relied upon.

### 2.3 vendor B (split APK set) — colour data is **encrypted**

`extract_apk_assets.py` unpacked the full split set (4 archives → **1 442
files / 313.8 MiB**; top dirs `res` 1139, `META-INF` 130, `assets` 113,
`lib` 29). Measured:

* `assets/Colormaps/*.dat` — **26 files**, ~0.9–3.1 MiB each.
* `assets/GMaps/*.dat` — **59 files**, ~0.1–0.44 MiB each.
* Neither has a recognisable header; **byte entropy H ≈ 8.0/8** (measured),
  i.e. ciphertext/compressed. `parse_luts.py` flags all **85** as
  `opaque_binary`, `excluded: true`.
* The same scan also reports 14 `png_lut` candidates (square UI/gradient PNGs
  that satisfy the dimension heuristic) — these are **likely false positives**;
  confidence is reported per candidate and only tiled-LUT-shaped files are ever
  extracted. Not treated as vendor-B colour data.
* `assets/models/solution.json.eng.enc` and the platform DSP vendor's
  `*Skel.so` skeletons — model/DSP payloads, unrelated to LUTs.
* `assets/Display P3.icc`, `*.json` UI assets, comparison JPEGs — not LUTs.

**Conclusion: vendor B's colour maps are encrypted at rest and are out of scope
for 22a. We do not attempt crypto.** Follow-up options are in §4.

### 2.4 Lens tables — **not in cleartext; native-only (documented, not decompiled)**

No cleartext lens/focal-profile table was found in either scanned tree.
`parse_luts.py --scan <vendorA>/sources --inventory` (22 671 Java files, ~81 s)
returned only **8 low-confidence `source_table` candidates** (large resource-id
or unrelated numeric arrays; generated `R.java` is skipped). No Java-side LUT
array was found — the colour data lives in the PNGs, not in source constants.
The candidate homes for native tables are JNI libraries, e.g. (vendor A) a
filter-SDK `.so`, a render-engine `.so`, and several watermark `.so`s
(effect / native-tool / cloud-native); the additional phone dumps include a
dedicated filter-LUT JNI `.so`. Exact filenames are recorded in the
out-of-repo implementer report, not here. Locating the exact float arrays
requires static analysis of the binaries — **explicitly out of scope for 22a**.
`scripts/ghidra_find_tables.py` is provided as a skeleton entry point.

---

## 3. Clean-room guardrails in the tooling

* `extract_apk_assets.py` is documented to unpack to a **scratch dir only**; it
  never targets the repo and validates every member path (rejects zip-slip).
* `parse_luts.py` emits only DERIVED grids (`.cube`) + a provenance sidecar
  (source path, size, SHA-256 of the first 1 MiB, method, confidence). For real
  dumps `--extract-dir` must point outside the repo.
* `parse_watermarks.py` runs every emitted string through a sanitiser that maps
  known vendor tokens to `vendor_a`… The token block-list is stored as **split
  string fragments**, so the names themselves never appear in this repository.
* `scripts/testdata/` contains only tool-generated, brand-free fixtures.

### Deviation from the brief (documented)

The brief describes extraction emitting a **`.cube` (33³ default)**.
`parse_luts.py` instead emits the **detected native size** (16³ or 64³ for the
PNGs actually present) and never silently resamples — resampling to 33³ would
destroy information and is not what the source encodes. `--lut-size N` overrides
the tile-grid *interpretation*; it does not resample values. If a fixed 33³
output is required downstream, that should be an explicit resample step.

---

## 4. Follow-ups

1. **vendor B `.dat` decryption** — keys/transform are not in cleartext assets.
   Requires dynamic analysis (capture the decrypted buffer at runtime) or
   locating the key material in Kotlin/`classes.dex` or native code. Keep out of
   scope unless a later task explicitly authorises it. Note: do **not** commit
   any decrypted payload regardless.
2. **Obfuscated vendor-A LUT PNGs (29)** — diff an obfuscated file against its
   cleartext sibling (same `lut_*` base name) to identify the transform (likely
   a block cipher or LZ-style framing); extend `parse_luts` once known.
3. **Confirm PNG tile-axis convention** — the decoder defaults to
   `tile→B, x→R, y→G`. The LUT-sampling shader was not found in cleartext;
   confirm against a `.cube` rendered by the app or a native shader before
   treating extracted cubes as pixel-exact. `--tile-axis/--x-axis/--y-axis`
   allow switching without code changes.
4. **Native lens/LUT tables** — implement `scripts/ghidra_find_tables.py`
   against the `.so` files listed in §2.4 (Ghidra headless).
5. **ICC handling** — `wcg.icc` is a display profile; if wide-gamut export is
   needed, add an ICC apply step (out of scope here).

---

## 5. Runtime validation plan (CI)

CI is the source of truth. (Locally a `py`-launcher Python 3.13 was available
and both gates below were run and pass; CI re-runs them on Python 3.12.)

```yaml
# CI job (ubuntu, Python 3.12)
- run: python -m compileall scripts              # SYNTAX GATE (required)
- run: python -m pip install -r scripts/requirements.txt
- run: python scripts/selftest.py --verbose      # HAPPY-PATH GATE
```

`selftest.py` proves the tool paths without any dump content:

* **extract_apk_assets** — builds a tiny split-APK set in a temp dir and asserts
  the inventory (member counts, extension buckets, base-before-config ordering,
  and that a `../escape` zip-slip member is rejected + recorded).
* **parse_luts** — encodes a known **8³ LUT into a tiled PNG** (24×24 = 3×3
  tiles of 8 px), runs `scan_tree` → `extract_candidates`, reloads the emitted
  `.cube`, and asserts it round-trips the original grid (8-bit tolerance
  ≤ 1/255). Also runs `--inventory` over `scripts/testdata`.
* **parse_watermarks** — parses a synthetic `config.json`, asserting line order,
  roles, divider thickness (2 dp), resolved text colour, font scale, and that a
  vendor token (assembled from fragments at runtime) is sanitised to `vendor_a`
  with none leaking into the output.
* **validate_looks** — an identity LUT is a no-op on the committed gradient
  (both trilinear and tetrahedral); the warm LUT provably changes the image.

Under CI, `validate_looks.py` is also exercised directly against the tiny
inputs under `scripts/testdata/` (`gradient_rgb.png`,
`identity_8.cube`, `warm_8.cube`). These fixtures are gradients and derived
LUTs only — **no dump-derived binaries** — per the brief.

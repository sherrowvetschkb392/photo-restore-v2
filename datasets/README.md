# Validation datasets

Downloaded images are deliberately kept outside Git under:

```text
data/validation/<dataset-name>/raw/
```

Only source manifests belong in this directory. Each manifest must record the
original page URL, direct asset URL, author/owner, license or public-domain
status, retrieval date and SHA-256 checksum. A file without verifiable reuse
terms must not be added to the validation set.

The required manifest format is defined by `manifest.schema.json`. The batch
runner independently enforces the required fields, HTTPS URLs, safe and unique
filenames, exact file-list matching, and SHA-256 values without requiring an
extra JSON Schema package.

Board outputs and reports are kept separately under:

```text
benchmarks/validation/<dataset-name>/
```

The first image-worker implementation accepts PNG/JPEG inputs containing no
more than 2,000,000 pixels. Keep initial validation images small so a failed
experiment cannot exhaust the RK3588's 4 GB RAM.

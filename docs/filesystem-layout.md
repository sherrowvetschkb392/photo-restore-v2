# Filesystem layout

The project uses three deliberately separate workspaces.

## 1. Windows: versioned source

```text
C:\Users\LJD\rk\photo-restore-v2\
├── apps\                    application code
│   └── worker\              board inference worker
├── benchmarks\              ignored local reports
├── config\                  versioned configuration examples
├── docs\                    architecture and operating documentation
├── models\validation\       ignored deployment staging cache
├── scripts\                 PowerShell and shell automation
├── tests\                   automated tests
└── tools\model\             ONNX/RKNN conversion tools
```

Only source code, scripts and documentation belong in Git. Models, validation
tensors and benchmark results are ignored.

## 2. WSL2: model conversion factory

```text
/home/ljd/photo-restore-rknn232/
├── packages/                pinned RKNN Toolkit wheel
├── models/
│   ├── source/              official Real-ESRGAN PTH
│   ├── onnx/                fixed-shape ONNX models
│   └── rknn/                RK3588-compiled models
├── workspace/
│   ├── scripts/             copies of versioned conversion tools
│   ├── samples/             deterministic validation tensors
│   └── reports/             compiler logs and conversion reports
└── manifests/               future artifact manifests
```

This is the canonical model-build workspace. It is not a Git repository.

## 3. RK3588: runtime and user data

```text
/userdata/photo-restore-v2/
├── app/
│   ├── backend/             deployed FastAPI source and requirements
│   ├── frontend/            deployed browser UI
│   └── worker/              image inference and tiling workers
├── repo/                    standalone diagnostic/validation scripts
├── venv/                    isolated Python 3.9 environment
├── models/                  verified RKNN runtime models
├── database/                SQLite job metadata
├── storage/
│   ├── jobs/                isolated API job directories and artifacts
│   ├── incoming/            reserved upload staging area
│   ├── outputs/             reserved derivative area
│   ├── reports/             reserved report area
│   └── tmp/                 bounded processing and deployment scratch data
├── data/
│   ├── validation/          temporary model validation tensors
│   ├── validation-batches/  isolated development batch jobs
│   └── benchmarks/          isolated driver/performance diagnostics
├── benchmarks/              board-generated JSON reports
├── logs/                    runtime logs
└── packages/                cached board packages and installers
```

The deployed API currently keeps each user-visible job together under
`storage/jobs/<job-id>/`. This is intentional: the input, previews, output,
report, worker log and temporary state can be checked and removed as one bounded
unit. The API database stores metadata and paths but not media bytes.

The target multi-user/video layout is defined conceptually in
`product-requirements-roadmap.md`. Do not move live files into a speculative
layout before the database migration, backup and rollback design is complete.

The following older proposed layout is superseded and must not be created by
new code:

```text
data/
├── originals/               immutable uploaded originals
├── derivatives/             completed restoration versions
├── previews/                thumbnails and browser previews
├── work/                    recoverable per-job temporary data
└── validation/              development-only test tensors
```

It remains in this document only to explain references in early project history.

## Retention policy after tile benchmarking

Recommended long-term artifacts:

- Windows: source, docs and small benchmark reports;
- WSL: official PTH, tile96 ONNX, tile96 RKNN, package wheel and reports;
- RK3588: tile96 RKNN, project venv, runtime code and reports.

Production API job data follows the configured seven-day terminal retention,
4 GiB storage quota and 2 GiB free-space reserve. `QUEUED` and `RUNNING` jobs
must not be removed by automatic cleanup. Development validation and diagnostic
directories are separate and are cleaned only by their exact owning scripts.

Candidates for removal after explicit approval:

- Windows `check*_*.onnx` compiler intermediates;
- Windows `models/validation` staging cache;
- WSL non-selected tile 64/80/112/128 ONNX and RKNN models;
- WSL compiler intermediate `check*_*.onnx` files;
- RK3588 non-selected tile 64/80/112/128 models;
- validation tensors after the inference pipeline is stable.

Do not remove old pre-existing projects outside `/userdata/photo-restore-v2`.

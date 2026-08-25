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
├── repo/                    deployed runtime scripts/application
├── venv/                    isolated Python 3.9 environment
├── models/                  verified RKNN runtime models
├── data/
│   └── validation/          temporary model validation tensors
├── benchmarks/              board-generated JSON reports
├── logs/                    runtime logs
└── packages/                board RKNNLite2 wheel
```

Future user data will be split further:

```text
data/
├── originals/               immutable uploaded originals
├── derivatives/             completed restoration versions
├── previews/                thumbnails and browser previews
├── work/                    recoverable per-job temporary data
└── validation/              development-only test tensors
```

## Retention policy after tile benchmarking

Recommended long-term artifacts:

- Windows: source, docs and small benchmark reports;
- WSL: official PTH, tile96 ONNX, tile96 RKNN, package wheel and reports;
- RK3588: tile96 RKNN, project venv, runtime code and reports.

Candidates for removal after explicit approval:

- Windows `check*_*.onnx` compiler intermediates;
- Windows `models/validation` staging cache;
- WSL non-selected tile 64/80/112/128 ONNX and RKNN models;
- WSL compiler intermediate `check*_*.onnx` files;
- RK3588 non-selected tile 64/80/112/128 models;
- validation tensors after the inference pipeline is stable.

Do not remove old pre-existing projects outside `/userdata/photo-restore-v2`.


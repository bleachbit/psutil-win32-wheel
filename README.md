# psutil-win32-wheel

Reproducible 32-bit Windows wheel builds of psutil for BleachBit.

Current artifact: `psutil-7.2.2-cp37-abi3-win32.whl`

Upstream psutil does not publish current 32-bit Windows wheels. This repository builds one from the pinned psutil source distribution using the 32-bit Python runtime from `bleachbit/pygtkwin` and the MSVC toolchain on the GitHub `windows-2025` runner.

## Supply chain properties

- All build inputs are pinned by URL and SHA256 in `build-inputs.json`.
- pip and setuptools are bootstrapped only from pinned, hash-verified wheels.
- GitHub Actions are pinned by full commit SHA.
- Two independent Windows build jobs must produce bit-for-bit identical wheels.
- The wheel is smoke tested with the real 32-bit Windows Python before comparison.
- Release publication verifies GitHub release and asset attestations.

## Release assets

Each release contains exactly:

- `psutil-7.2.2-cp37-abi3-win32.whl`
- `SHA256SUMS.txt`
- `BUILD-INFO.txt`

The replica artifacts visible in workflow runs are build evidence. Only the unsuffixed wheel is a release asset.

## Making a release

Immutable releases must be enabled in the repository settings before tagging.

```sh
git tag vYYYY-MM-DD
git push origin vYYYY-MM-DD
```

For a second release on the same date, use a suffix such as `vYYYY-MM-DD-r2`.

## Scope

This repository does not fork or patch psutil, upload to PyPI, or provide a general package index.

## License

Build scripts and documentation are GPLv3 or later. The psutil wheel retains psutil's BSD license.

# psutil-win32-wheel

Reproducible 32-bit Windows wheel builds of psutil for BleachBit.

Current artifact: `psutil-7.2.2-cp37-abi3-win32.whl`

Upstream psutil does not publish current 32-bit Windows wheels. This repository builds one from the pinned psutil source distribution using the 32-bit Python runtime from `bleachbit/pygtkwin` and the MSVC toolchain on the GitHub `windows-2025` runner.

## Supply chain properties

- Downloaded package and Python runtime inputs are pinned by URL and SHA256 in `build-inputs.json`.
- pip and setuptools are bootstrapped only from pinned, hash-verified wheels.
- External GitHub Actions are pinned by full commit SHA. The reusable replica
  workflow comes from the same commit as the caller.
- Two separate Windows jobs must produce bit-for-bit identical wheels. Each
  job's bundle is downloaded by artifact ID and extracted separately. The
  release job downloads only the compare job's bundle, also by artifact ID.
- The wheel is smoke tested with the real 32-bit Windows Python before comparison.
- Release publication verifies GitHub release and asset attestations.

## Release assets

Each release contains exactly:

- `psutil-7.2.2-cp37-abi3-win32.whl`
- `SHA256SUMS.txt`
- `BUILD-INFO.txt`

The replica artifacts visible in workflow runs are build evidence. Only the unsuffixed wheel is a release asset.

## Making a release

Before the first release, enable immutable releases and configure active
rulesets under **Settings > Rules > Rulesets**:

1. Target `main` with a branch ruleset. Require pull requests and the
   `Compare independent builds` status check, and block force pushes and
   deletion. Require an approving review if a second maintainer is available.
2. Target `v*` with a tag ruleset that restricts creations. Grant bypass only
   to trusted release maintainers.
3. Target `v*` with a separate tag ruleset that restricts updates and deletions,
   without routine bypass. This keeps the permission to create tags from also
   granting permission to move them.

After the release changes are merged, wait for the build workflow triggered
by the push to `main` to pass. Tag that exact reviewed commit, not the current
local `HEAD` by default:

```sh
git tag vYYYY-MM-DD REVIEWED_COMMIT_SHA
git push origin vYYYY-MM-DD
```

Only a new, protected tag can publish. It must point to a commit on `main`
with a successful build workflow run for that exact SHA from a push to `main`.
These checks are in the tagged workflow, so the GitHub rulesets are still the
trust boundary. For a second release on the same date, use a suffix such as
`vYYYY-MM-DD-r2`.

## Scope

This repository does not fork or patch psutil, upload to PyPI, or provide a general package index.

## License

Build scripts and documentation are GPLv3 or later. The psutil wheel retains psutil's BSD license.

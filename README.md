# setup-ghoten

GitHub Actions composite action that installs the [Ghoten CLI](https://github.com/vmvarela/ghoten) (a Go OpenTofu fork) on the runner, with an interface modeled after `opentofu/setup-opentofu` v2.0.2.

Implemented as a pure bash composite action: no Node runtime, no committed `dist/`.

## Quick start

```yaml
steps:
  - uses: vmvarela/setup-ghoten@v1
```

## Pinning a version

```yaml
steps:
  - uses: vmvarela/setup-ghoten@v1
    with:
      ghoten_version: '1.12.5'
```

`ghoten_version` accepts `latest` (the default) or an exact `X.Y.Z` version with an optional leading `v`. Semver ranges are deliberately not supported.

### Version file

Set `ghoten_version_file` (default `.ghoten-version`) to have the action read the version from a file in the repo. A non-empty file wins over `ghoten_version`. Plain value files and asdf-style `.tool-versions` lines (`ghoten 1.12.5`) are both accepted. Set it to `''` to disable:

```yaml
- uses: vmvarela/setup-ghoten@v1
  with:
    ghoten_version_file: ''
```

## Inputs

| Input | Default | Description |
|---|---|---|
| `ghoten_version` | `latest` | Version to install: `latest` or an exact `X.Y.Z` (optional leading `v`). |
| `ghoten_version_file` | `.ghoten-version` | File whose content takes precedence over `ghoten_version` when non-empty. |
| `ghoten_wrapper` | `true` | Wrap the binary to capture stdout, stderr and exit code of every invocation into the calling step's outputs. |
| `checksums` | `''` | Multiline SHA-256 list; when set it replaces the release checksum file. |
| `github_token` | `''` | Token for the GitHub API call resolving `latest`; falls back to `GITHUB_TOKEN`. |
| `cli_config_credentials_hostname` | `app.terraform.io` | Hostname written to the CLI credentials block. |
| `cli_config_credentials_token` | `''` | Token written to the CLI credentials block. |
| `provider_acceptance_tests` | `false` | Export `TF_ACC*` variables pointing at the installed binary. |

## Outputs

| Output | Description |
|---|---|
| `version` | The installed ghoten version. |

Note: the action does **not** declare `stdout`, `stderr` or `exitcode` outputs. When `ghoten_wrapper` is `true` (the default), the wrapper writes them into the **calling step's** outputs — composite actions cannot pipe these back to the action level. Example:

```yaml
steps:
  - id: plan
    uses: vmvarela/setup-ghoten@v1
    # other inputs omitted

  # an invocation of the installed binary (or a step that runs ghoten):
  - id: run-ghoten
    run: ghoten plan -out=tfplan
    # after this step:
    #   steps.run-ghoten.outputs.stdout
    #   steps.run-ghoten.outputs.stderr
    #   steps.run-ghoten.outputs.exitcode

  - if: steps.run-ghoten.outputs.exitcode != '0'
    run: echo "${{ steps.run-ghoten.outputs.stderr }}"
```

Exit code `2` (produced by `-detailed-exitcode` when there are pending changes) is reported as success by the wrapper. To guarantee complete capture, the wrapper records the child's stdout/stderr to files during the run and replays them when the command finishes: live output is not streamed while the child runs.

## CLI credentials

```yaml
- uses: vmvarela/setup-ghoten@v1
  with:
    cli_config_credentials_hostname: 'app.terraform.io'
    cli_config_credentials_token: '${{ secrets.TERRAFORM_CREDENTIALS_TOKEN }}'
```

This writes a `credentials "<hostname>" { token = "..." }` block to the ghoten CLI configuration file (`$TF_CLI_CONFIG_FILE` when that variable is already set by you, else `%APPDATA%\ghoten.rc` on Windows, else `~/.ghotenrc`). This makes private provider installs work.

**Note:** the CLI `credentials` block does not authenticate OCI/ORAS state backends (e.g. GHCR). Those need Docker credentials (`docker login ghcr.io`) or an `oci_credentials` block; this action does not configure them.

## Combining with the `vmvarela/ghoten` action

The `vmvarela/ghoten` action reads step outputs named `stdout` and `exitcode`. If you use both this action and that one in the same workflow, invocations of the installed binary will collide on those output names. In that combination, use:

```yaml
- uses: vmvarela/setup-ghoten@v1
  with:
    ghoten_wrapper: 'false'
```

With the wrapper disabled, the binary is left untouched and no `stdout`/`stderr`/`exitcode` outputs are written.

## Supported platforms

Linux, macOS and Windows runners (`ubuntu-latest`, `macos-latest`, `windows-latest`) in the architectures published by ghoten release archives. On Windows, `shell: bash` is required for this action and for any step that runs the installed binary.

## Checksum verification

Releases ship a checksum file; the archive's SHA-256 is verified against it before extraction. Two deliberate differences from `opentofu/setup-opentofu`:

- **Strict verification**: if the checksum file cannot be fetched or does not list the archive, the step **fails** (setup-opentofu only warns).
- Supplying `checksums` replaces the release checksum file entirely; the archive must match one of the provided entries or the step fails.

## Requirements

- `shell: bash` on Windows.
- `curl` or `wget`, `tar`, and a SHA-256 tool (`sha256sum` or `shasum`); `jq` for `ghoten_version: latest` (GitHub-hosted runners ship all of these).

## Deliberately unsupported

- Semver ranges (`latest` or exact versions only).
- Sigstore/cosign signature verification (SHA-256 checksums only).
- A standalone curl installer (`curl ... \| bash`) outside GitHub Actions.

## Local development and testing

```sh
# end-to-end smoke test (downloads a real ghoten release)
bash tests/smoke.sh

# static analysis
shellcheck -x lib/*.sh tests/*.sh
docker run --rm -v "$PWD:/repo" --workdir /repo rhysd/actionlint:latest
```

## License

MPL-2.0. See [LICENSE](LICENSE).

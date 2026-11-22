# NDK

The Noderalis development kit in GitHub Actions. One job takes a module
repository from its spec to a signed, tested package, running `nod ci`: the
same command you run on your own machine, so CI and local never drift.

## Use

```yaml
# .github/workflows/ndk.yml in your module repository
on: [push, pull_request]
jobs:
  ndk:
    uses: Blackfall-Labs/ndk-ci/.github/workflows/ndk.yml@v1
    secrets: inherit
```

Your repository declares its module in `ndk.toml`:

```toml
[module]
package = "my-module"          # the cdylib crate to build
spec    = "spec/my-module.json" # required: no spec, no build
policy  = "config/policy.iam"   # what the module may do
```

`nod ci` runs these stages in order, and a failure stops the rest:
spec, doctor, build, conform, sign, install, boot, package. The run is refused
before anything is built when no spec is declared, and a build that departs
from its spec is never signed. The report is the job summary and an uploaded
artifact, along with the signed package.

## Secrets

Both are optional, and both are read from the environment only.

| Secret | What it does |
|---|---|
| `NOD_LICENSE_KEY` | Your NDK license key. Needed to sign with a release key. |
| `NOD_SIGNING_KEY` | Your release signing seed, 64 hex digits. Used only with a valid license. |

Without them every stage still runs, and the module is signed with a key
minted for that run. The report says which key signed. Pull requests from
forks receive no secrets, so they always run this way.

## Only the nod binary

```yaml
steps:
  - uses: actions/checkout@v4
  - uses: Blackfall-Labs/ndk-ci@v1
  - run: nod ci
```

The action downloads nod from this repository's releases and checks its
signature against the Blackfall release key before running it.

## Status

The first nod release has not been published yet. Until it is, the action
stops with a message saying so.

## License

See [LICENSE](LICENSE).

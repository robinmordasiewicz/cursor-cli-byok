# Independent fork builds and Apple notarization

This fork is owned by `robinmordasiewicz/cursor-cli-byok`. Its initial source is
`shiqkuangsan/cursor-cli-byok` commit
`48bee0bbfb7aec5578724672384475576209c5ac`, under the retained MIT license.
The Go module now belongs to this fork. Cursor CLI remains a separate official
dependency; it is neither modified, bundled, nor signed by this project.

## Build identity

`Fork CI` builds native Linux amd64/arm64 and macOS amd64/arm64 binaries from
the checked-out commit. Each development artifact has a source SHA, target and
SHA-256 receipt explicitly identifying it as unsigned and unnotarized.

The imported `CI` and `Release` workflows are manual historical references.
They no longer run automatically on pushes or tags. They retain their original
Linux acceptance contracts; the fork's workflows own new builds.

Build locally with the Homebrew Go toolchain:

```sh
make build VERSION=dev.internal
dist/cursor-cli-byok --version
```

## Current compatibility gate

On 2026-11-17 the inherited bridge passed serialized Go unit tests and built on
Darwin arm64. Official Cursor CLI `2026.11.13-eacade1` startup/model discovery
passed, but the real interactive E2E failed while reconnecting. A separate
read-tool capture reproduced `invalid client stream frame`. Capturing a valid
initial Run does not qualify the full stream or a completed provider turn.

`packaging/cursor-version.txt` records this candidate version, not a claim of
acceptance. `Internal macOS release` runs the full official-Cursor E2E on each
architecture and requires the exact candidate version before signing. Until
this protocol failure is fixed and both runs pass, signed release artifacts
cannot be produced. The existing July verified-version manifest is preserved.

Failure evidence is retained privately on the acceptance Mac. Raw captures
and local state must not be uploaded to releases or GitHub logs.

## Apple credentials

Create the GitHub environment `macos-release` and add:

| Environment secret | Purpose |
| --- | --- |
| `APPLE_CERTIFICATE_BASE64` | Base64-encoded Developer ID Application P12, including its private key |
| `APPLE_CERTIFICATE_PASSWORD` | P12 password |
| `APPLE_ID` | Apple Developer account used by notarytool |
| `APPLE_PASSWORD` | Apple app-specific password |
| `APPLE_TEAM_ID` | Developer team matching the imported signing identity |

Forks do not inherit upstream secrets. This Mac has no valid Developer ID
signing identity. Credentials must be provisioned through the user's existing
secret-management process; do not commit certificates, keys or passwords.
Environment reviewers and a `build-internal` deployment branch restriction can
be configured according to the user's existing release governance.

## Signed release workflow

After this workflow is merged into the fork's default branch, compatibility
and credentials are ready, tag a reviewed fork commit with
an internal version, such as `v0.2.0-internal.1`. Dispatch:

```sh
gh workflow run macos-release.yml --repo robinmordasiewicz/cursor-cli-byok \
  --ref build-internal -f tag=v0.2.0-internal.1
```

The tag must belong to `build-internal`. Verification runs against its resolved
SHA; both signing jobs check out that same SHA. The workflow then:

1. Builds each macOS architecture with the internal version embedded.
2. Runs the full official-Cursor compatibility gate on that build.
3. Imports the fork owner's Developer ID Application certificate into a
   temporary runner keychain and requires the matching Apple team.
4. Signs the CLI with a secure timestamp and hardened runtime.
5. Packages the CLI and license into a signed DMG.
6. Requires Apple's explicit `Accepted` notarization response, staples and
   validates the ticket, and passes Gatekeeper's disk-image assessment.
7. Calculates checksums after stapling and records source SHA, signing team,
   notarization ID, signed binary hash and final DMG hash.
8. Creates a draft fork release only after both architecture jobs succeed and
   the publication job independently verifies the final checksums. It includes
   the fork's Linux binaries and their receipts/checksums for the existing Linux
   installer contract; Linux binaries are not Apple signed or notarized.

A bare Mach-O CLI cannot carry a stapled ticket. The DMG carries that ticket
and supports copying or Homebrew staging without an administrator installer.
It needs a Developer ID Application certificate; no Developer ID Installer
certificate or machine-wide CA installation is required.

The release script tests use fake Apple tools to prove rejection boundaries
and post-staple checksum ordering. They do not prove Apple notarization.
Only actual Apple acceptance plus staple and Gatekeeper checks establishes it.

## Internal LiteLLM route

The existing internal gateway catalog was checked on 2026-11-17 and listed
`gpt-6.1-sol` and `claude-opus-5-5` at
the configured internal OpenAI-compatible `/models` endpoint. No provider inference was requested.
Once Cursor compatibility passes, both model families can be configured using
the bridge's OpenAI-compatible streaming adapter:

```sh
cursor-cli-byok config init --non-interactive \
  --name internal-opus \
  --base-url https://litellm.example.internal/openai \
  --endpoint /v1/chat/completions \
  --upstream-model claude-opus-5-5 --api-key-env LITELLM_API_KEY
```

The bridge appends the endpoint, so its base URL deliberately omits `/v1`.
Resolve `LITELLM_API_KEY` through the existing credential store rather than
placing its value in a command argument. Model-catalog presence alone does not
prove streaming, tool continuation, usage accounting, cancellation, or a
successful CLI turn. Qualify those against the internal gateway separately.
The current bridge implements OpenAI Chat Completions and Responses; it does
not yet implement a native Anthropic Messages adapter.

## Research sources

- [Bridge source and compatibility contract](https://github.com/shiqkuangsan/cursor-cli-byok/tree/48bee0bbfb7aec5578724672384475576209c5ac)
- [Upstream exact-version evidence](https://github.com/shiqkuangsan/cursor-cli-byok/blob/48bee0bbfb7aec5578724672384475576209c5ac/docs/compatibility.md)
- [LiteLLM Cursor integration](https://docs.litellm.ai/docs/tutorials/cursor_integration)
- [Native subscription relay merged 2026-11-17](https://github.com/BerriAI/litellm/pull/52205)

LiteLLM's native Cursor subscription relay forwards signed-in Cursor inference
without translating it to other models. The local BYOK bridge performs the
translation required for the internal OpenAI/Anthropic model deployments.

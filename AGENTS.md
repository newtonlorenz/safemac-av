# Repository Agent Instructions

These instructions apply to the entire repository. They govern automated agents and maintainers using agent-assisted workflows.

## Non-negotiable GitHub workflow

- Never commit or push directly to `main`.
- Never rewrite, force-push, delete, or move `main` or a published tag.
- Put every tracked change through a pull request, including documentation, CI, release scripts, and maintenance changes.
- Start from a clean, current `main` and create a short-lived branch.
- Automated branches must use `codex/<scope>`. Human branches should use `feat/`, `fix/`, `docs/`, `test/`, or `chore/`.
- Merge with GitHub's squash-merge control only. Do not merge locally and push the result.
- Do not merge with failing or unavailable CI unless the maintainer explicitly approves an exception documented in the pull request.
- Do not merge a pull request without explicit maintainer authorization.

Repository settings, issue management, security advisories, and release assets cannot be changed through a pull request. Treat those as audited GitHub operations: obtain explicit authorization, inspect current state first, make the smallest change, and read the result back.

## Required change workflow

1. Run `git status --short --branch` and preserve unrelated work.
2. Run `git fetch origin`, switch to `main`, and update it with `git pull --ff-only origin main`.
3. Create a focused branch from `main`.
4. Add a failing test first for behavior changes, then implement the smallest fix.
5. Run verification proportional to the change and record exact results.
6. Review the complete diff, run `git diff --check`, and scan for secrets, private paths, signing assets, and generated output.
7. Commit with a conventional subject such as `fix:`, `feat:`, `docs:`, `test:`, `refactor:`, `ci:`, or `chore:`.
8. Push the branch with `git push -u origin <branch>`.
9. Open a pull request containing the problem, solution, security/privacy impact, verification, and remaining risks.
10. Resolve review threads and re-run affected checks after every material update.
11. Merge through GitHub with squash merge, then update local `main` with a fast-forward pull.

If a requested operation conflicts with these rules, stop and explain the conflict. Do not silently bypass protection.

## Verification expectations

- Run the complete unit and integration suite for Swift behavior changes.
- Build the Release configuration for source, project, entitlement, or packaging changes.
- Run the signed UI scheme and exercise the built interface directly for UI changes.
- Validate links, commands, and rendered structure for documentation-only changes.
- Add regression coverage for fixes. Do not weaken or skip assertions to obtain a pass.
- Preserve test evidence in the pull request. A command starting is not a passing result.

Use the exact commands documented in [CONTRIBUTING.md](CONTRIBUTING.md). UI tests require a locally signable host; do not pass `CODE_SIGNING_ALLOWED=NO` to the UI scheme.

## Security and privacy

- Never commit credentials, app-specific passwords, tokens, certificates, private keys, provisioning profiles, `.env` files, personal paths, or unsanitized logs.
- Never add real malware or irreplaceable personal files as fixtures.
- Treat quarantine, restore, deletion, scheduling, executable paths, subprocess arguments, filesystem writes, and persisted data as security-sensitive boundaries.
- Validate external data and filesystem paths. Surface user-facing errors instead of discarding them.
- Preserve the user's existing worktree and configuration. Avoid destructive Git commands.
- Report vulnerabilities through GitHub private security advisories, not public issues.

## Release discipline

- Put version, changelog, packaging, and release-note source changes through a pull request first.
- Tag only a reviewed commit already merged to `main`.
- Treat published tags and release assets as immutable. Publish a new version instead of replacing history.
- Build macOS releases from a clean tag.
- Sign with Developer ID, enable hardened runtime, notarize with Apple, and staple the ticket.
- Publish the universal `arm64` and `x86_64` DMG with `SHA256SUMS.txt`.
- Verify the signature, notarization ticket, Gatekeeper assessment, architectures, checksum, and installed UI before publishing.
- Download the GitHub-hosted assets again and verify them before declaring the release complete.

## Scope and ownership

- Keep pull requests focused and reviewable. Separate unrelated changes.
- Preserve the existing architecture unless the pull request explains and tests a deliberate change.
- Update README, architecture, security, or contributor documentation when behavior or workflow changes.
- Do not add agent scratchpads, private reports, local plans, build products, or tool state to the repository.

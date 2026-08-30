# Issue tracker: GitHub

Issues and specs for this repository live as GitHub issues on [`lambertaurelle/homelab-iac`](https://github.com/lambertaurelle/homelab-iac). Use the `gh` CLI for all operations.

Infer the repo from `git remote -v`; `gh` does this automatically when run inside a clone.

## Conventions

- **Create an issue**:
  ```bash
  gh issue create --title "<title>" --body "<body-markdown>" --label "<label>"
  ```
  Use a heredoc for multi-line bodies:
  ```bash
  gh issue create --title "..." --label "ready-for-agent" --body "$(cat <<'EOF'
  ## What to build
  ...
  EOF
  )"
  ```
- **Read an issue**:
  ```bash
  gh issue view <number> --comments
  ```
  Filter comments and fetch labels using `jq`:
  ```bash
  gh issue view <number> --json number,title,body,labels,comments --jq '{number, title, body, labels: [.labels[].name], comments: [.comments[].body]}'
  ```
- **List issues**:
  ```bash
  gh issue list --state open --json number,title,body,labels,comments --jq '[.[] | {number, title, body, labels: [.labels[].name], comments: [.comments[].body]}]'
  ```
  Filter by triage status (e.g. ready for autonomous agent execution):
  ```bash
  gh issue list --state open --label "ready-for-agent"
  ```
- **Comment on an issue**:
  ```bash
  gh issue comment <number> --body "<comment-body>"
  ```
- **Apply / remove labels**:
  ```bash
  gh issue edit <number> --add-label "ready-for-agent"
  gh issue edit <number> --remove-label "needs-triage"
  ```
- **Assign an issue**:
  ```bash
  gh issue edit <number> --add-assignee @me
  ```
- **Close an issue**:
  ```bash
  gh issue close <number> --comment "<resolution-summary>"
  ```

## Triage Label Integration

Skills interact with the five canonical triage roles mapped in [`docs/agents/triage-labels.md`](file:///root/homelab-iac/docs/agents/triage-labels.md):

| Label | Role & Meaning |
| :--- | :--- |
| `needs-triage` | Maintainer needs to evaluate this issue |
| `needs-info` | Waiting on reporter or user for clarification |
| `ready-for-agent` | Fully specified with acceptance criteria; ready for agent execution |
| `ready-for-human` | Requires human interaction or physical homelab access |
| `wontfix` | Will not be actioned |

## Engineering Workflow Guidelines Alignment

As documented in [`AGENTS.md`](file:///root/homelab-iac/AGENTS.md), agents follow the three-phase engineering lifecycle:

1. **Alignment & Planning (`/grill-me`, `/to-spec`)**:
   - Specs synthesized from conversations are published to GitHub issues using `gh issue create`.
   - Apply the `ready-for-agent` label.
2. **Issue Decomposition (`/to-tickets`)**:
   - Break specs into atomic, vertically-sliced issues with clear acceptance criteria.
   - Publish issues in dependency order (blockers first) and link dependencies (native GitHub dependencies or `Blocked by: #<n>`).
   - Label decomposed tickets as `ready-for-agent`.
3. **Execution & Verification**:
   - Claim the issue with `gh issue edit <n> --add-assignee @me`.
   - Implement changes in code (`tofu/`, `stacks/`, `scripts/`).
   - **Verification Gate before closing**:
     - Pre-commit hooks: `pre-commit run --all-files`
     - OpenTofu format & validate: `tofu fmt -check tofu/` and `tofu -chdir=tofu validate`
     - DevSecOps scanner: `/root/homelab-iac/scripts/scan-security.sh --tofu-only` (or full suite)
   - Close the issue with a resolution comment linking commits/diffs.

## Pull requests as a triage surface

**PRs as a request surface: no.** _(Set to `yes` if this repo treats external PRs as feature requests; `/triage` reads this flag.)_

When set to `yes`, PRs run through the same labels and states as issues, using the `gh pr` equivalents:

- **Read a PR**: `gh pr view <number> --comments` and `gh pr diff <number>` for the diff.
- **List external PRs for triage**: `gh pr list --state open --json number,title,body,labels,author,authorAssociation,comments` then keep only `authorAssociation` of `CONTRIBUTOR`, `FIRST_TIME_CONTRIBUTOR`, or `NONE` (drop `OWNER`/`MEMBER`/`COLLABORATOR`).
- **Comment / label / close**: `gh pr comment`, `gh pr edit --add-label`/`--remove-label`, `gh pr close`.

GitHub shares one number space across issues and PRs, so a bare `#42` may be either: resolve with `gh pr view 42` and fall back to `gh issue view 42`.

## When a skill says "publish to the issue tracker"

Create a GitHub issue via `gh issue create`. Include clear acceptance criteria and appropriate triage labels (`ready-for-agent` by default).

## When a skill says "fetch the relevant ticket"

Run `gh issue view <number> --comments` or fetch JSON details via `gh issue view <number> --json number,title,body,labels,comments`.

## Wayfinding operations

Used by `/wayfinder`. The **map** is a single issue with **child** issues as tickets.

- **Map**: a single issue labelled `wayfinder:map`, holding the Notes / Decisions-so-far / Fog body. `gh issue create --label wayfinder:map`.
- **Child ticket**: an issue linked to the map as a GitHub sub-issue (`gh api` on the sub-issues endpoint). Where sub-issues aren't enabled, add the child to a task list in the map body and put `Part of #<map>` at the top of the child body. Labels: `wayfinder:<type>` (`research`/`prototype`/`grilling`/`task`). Once claimed, the ticket is assigned to the driving dev (`gh issue edit <n> --add-assignee @me`).
- **Blocking**: GitHub's **native issue dependencies**, the canonical, UI-visible representation. Add an edge with:
  ```bash
  gh api --method POST repos/lambertaurelle/homelab-iac/issues/<child>/dependencies/blocked_by -F issue_id=<blocker-db-id>
  ```
  where `<blocker-db-id>` is the blocker's numeric **database id** (`gh api repos/lambertaurelle/homelab-iac/issues/<n> --jq .id`, _not_ the `#number` or `node_id`). GitHub reports `issue_dependencies_summary.blocked_by` (open blockers only, the live gate). Where dependencies aren't available, fall back to a `Blocked by: #<n>, #<n>` line at the top of the child body. A ticket is unblocked when every blocker is closed.
- **Frontier query**: list the map's open children (`gh issue list --state open`, scoped to the map's sub-issues / task list), drop any with an open blocker (`issue_dependencies_summary.blocked_by > 0`, or an open issue in the `Blocked by` line) or an assignee; first in map order wins.
- **Claim**: `gh issue edit <n> --add-assignee @me`, the session's first write.
- **Resolve**: `gh issue comment <n> --body "<answer>"`, then `gh issue close <n>`, then append a context pointer (gist + link) to the map's Decisions-so-far.

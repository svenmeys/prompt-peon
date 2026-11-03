#!/bin/sh
# Lock the repository down. Safe to run again. Needs the gh command, signed in as the owner.
# Branch protection only works once the repository is public, or on a paid plan.
set -eu
REPO=svenmeys/prompt-peon

# Only GitHub's own actions, pinned to exact commits. Workflows can only read.
gh api -X PUT "repos/$REPO/actions/permissions" -F enabled=true -f allowed_actions=selected -F sha_pinning_required=true
gh api -X PUT "repos/$REPO/actions/permissions/selected-actions" -F github_owned_allowed=true -F verified_allowed=false
gh api -X PUT "repos/$REPO/actions/permissions/workflow" -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false

# Nothing from anyone new runs without an owner pressing approve, and the owner never does.
gh api -X PUT "repos/$REPO/actions/permissions/fork-pr-contributor-approval" -f approval_policy=all_external_contributors

# Nobody but the owner changes main without a reviewed pull request, and nobody can rewrite it.
gh api -X PUT "repos/$REPO/branches/main/protection" --input - <<'JSON'
{
  "required_status_checks": null,
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "required_approving_review_count": 1,
    "require_code_owner_reviews": true,
    "dismiss_stale_reviews": true,
    "require_last_push_approval": true
  },
  "restrictions": null,
  "required_conversation_resolution": true,
  "allow_force_pushes": false,
  "allow_deletions": false
}
JSON

# Bugs in issues, ideas in Discussions, and one reviewed commit per pull request.
gh repo edit "$REPO" --enable-issues --enable-discussions --enable-squash-merge --enable-merge-commit=false --enable-rebase-merge=false --delete-branch-on-merge

# Installers follow releases, so a published one can't be changed afterwards.
gh api -X PUT "repos/$REPO/immutable-releases"

# Fewer places to spam, and accounts under a day old can't comment or open anything. That limit lasts
# a month, so run this again if a launch day comes back around.
gh repo edit "$REPO" --enable-wiki=false --enable-projects=false
gh api -X PUT "repos/$REPO/interaction-limits" -f limit=existing_users -f expiry=one_month

# Private security reports, and pushes containing a known kind of secret get blocked.
gh api -X PUT "repos/$REPO/private-vulnerability-reporting"
gh api -X PATCH "repos/$REPO" --input - <<'JSON'
{ "security_and_analysis": { "secret_scanning": { "status": "enabled" }, "secret_scanning_push_protection": { "status": "enabled" } } }
JSON

echo "Locked down. Self-hosted runners on this repository: $(gh api "repos/$REPO/actions/runners" -q .total_count) (should be 0)"

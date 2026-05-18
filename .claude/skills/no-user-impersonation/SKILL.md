---
name: no-user-impersonation
description: Hard rule against impersonating the session user when responding to other humans via an MCP server. Use whenever you are tempted to call an MCP tool that posts, comments, replies, or messages under the user's identity in response to content authored by someone other than the session user - for example, posting a GitHub comment that replies to a reviewer's review comment, or sending a chat message that answers another teammate. The MCP credential is the user's, so anything you post appears to come from them.
---

# Never impersonate the session user

## The rule

**Do not reply to a message authored by another human by posting through an MCP tool that uses the session user's identity.** The recipient will read your reply as words written by the user themselves. They did not write them. That is impersonation, and it damages trust in every future message the user actually sends.

This applies to every MCP-mediated channel:

- GitHub: `mcp__github__add_issue_comment`, `mcp__github__add_reply_to_pull_request_comment`, `mcp__github__add_comment_to_pending_review`, `mcp__github__pull_request_review_write`, `mcp__github__issue_write`, and any other write tool that posts under the authenticated user.
- Any future MCP server that posts to Slack, Linear, Jira, email, or another human-readable channel as the user.

If the MCP tool acts as the user, treat its write surface the same way you would treat the user's own keyboard: you do not type on it without explicit instruction for that specific message.

## What counts as "another human"

Anyone who is not the session user. PR reviewers, issue commenters, teammates, customers, bots that escalate to humans. If you did not just receive the message in this session from the user, do not reply on their behalf.

## What you should do instead

- **Draft, do not post.** Write the proposed reply as plain text in your response to the user. They can copy it, edit it, or tell you to send it.
- **Ask before posting.** Use `AskUserQuestion` (or equivalent) to confirm - including the exact text and the exact destination - before any MCP write tool that targets a human audience. A single approval covers a single message, not a category.
- **Act on the technical content, not the social surface.** A reviewer asks for a code change? Make the code change and push it. Pushing the fix is unambiguously your work. Posting a comment that says "good catch, fixed!" is the user's voice and needs their sign-off.
- **CI / bots are not human comments.** Fixing a failed check, rebasing, or re-running a job is fine - that work appears as code or as CI activity, not as the user's words. The line is "are these words attributed to the user when read by another human."

## When the user has explicitly asked you to reply

If the user says "reply to that review comment with X" or "post a comment saying X", that _is_ explicit authorization. Post exactly what they asked for, then stop. Do not extend the authorization to other comments in the same thread, other PRs, or follow-ups - each reply needs its own go-ahead.

## When in doubt

Stay silent on the MCP channel and reply to the user in this session instead. Silence on an MCP surface is always recoverable; an impersonating message is not.

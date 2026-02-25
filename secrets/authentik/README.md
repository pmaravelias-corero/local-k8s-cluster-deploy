# Authentik Token

Create a `token` file in this directory containing a raw Authentik API token.

```
echo "your-token-here" > secrets/authentik/token
```

The `token` file is gitignored.

## How to get a token

- Admin UI → Directory → Tokens and App passwords
- Look for an existing token named `management-plane-api-password` or similar
- If none exists, create a new token with intent **API** — it must have read access to `core/groups`

## How it's used

The Management Plane API reads this file at startup from `/secrets/authentik/token` (mounted via a Kubernetes ConfigMap) to fetch user groups and tenant feature flags from Authentik.

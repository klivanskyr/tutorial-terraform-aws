# Network Security Overview

## Architecture

```
Internet
    │
    ▼
┌─────────────────────────────────────────────────────────────┐
│  Cloudflare DNS (grey cloud — DNS only, not proxied)        │
└─────────────────────────────────────────────────────────────┘
    │
    ▼ HTTPS (TLS 1.2+)
┌─────────────────────────────────────────────────────────────┐
│  AWS CloudFront                                             │
│  • ACM certificate (us-east-1)                              │
│  • redirect-to-https enforced                               │
│  • /api/*   → ALB (HTTP, within AWS network)               │
│  • /admin*  → ALB (HTTP, within AWS network)               │
│  • /*       → S3 static site                               │
└─────────────────────────────────────────────────────────────┘
    │                          │
    ▼ HTTP (port 80)           ▼ HTTP (port 80, S3 website endpoint)
┌──────────────┐         ┌──────────────────────────────────┐
│  ALB         │         │  S3 (public read, static files)  │
│  public      │         └──────────────────────────────────┘
│  subnets     │
│  SG: alb     │
└──────────────┘
    │
    ▼ HTTP (port 8000)
┌─────────────────────────────────────────────────────────────┐
│  ECS Fargate (private subnets, no public IP)                │
│  SG: ecs — only accepts traffic from SG: alb                │
│  Outbound via NAT Gateway                                   │
└─────────────────────────────────────────────────────────────┘
    │                          │
    ▼ port 5432                ▼ port 6379
┌──────────────┐         ┌──────────────────┐
│  RDS Proxy   │         │  ElastiCache     │
│  private     │         │  Redis           │
│  SG: rds-    │         │  private subnets │
│  proxy       │         │  SG: redis       │
└──────────────┘         └──────────────────┘
    │
    ▼ port 5432
┌──────────────┐
│  RDS         │
│  Postgres    │
│  private     │
│  SG: rds     │
└──────────────┘
```

---

## What Is Protected and How

### 1. Network Perimeter

**VPC with private/public subnet split**
- ECS, RDS, RDS Proxy, and Redis all live in private subnets with no public IP
- Only the ALB and NAT Gateway are in public subnets
- Private subnets route outbound traffic through the NAT Gateway — they can initiate connections to the internet but nothing can initiate a connection back to them

**Security groups follow least-privilege**
- `alb`: accepts port 80/443 from the internet
- `ecs`: accepts port 8000 from `alb` SG only — not from any IP range
- `rds-proxy`: accepts port 5432 from `ecs` SG only
- `rds`: accepts port 5432 from `rds-proxy` SG only
- `redis`: accepts port 6379 from `ecs` SG only

Using security group references (rather than CIDR ranges) means "any resource with the `alb` SG attached" — this is tighter than an IP range because it can't be accidentally broadened.

### 2. TLS / Encryption in Transit

**Visitor → CloudFront**: TLS 1.2+ enforced, ACM certificate, HTTP automatically redirected to HTTPS.

**CloudFront → S3**: HTTP only (S3 website endpoint doesn't support HTTPS). Content is public static files — no sensitive data.

**CloudFront → ALB**: HTTP on port 80, within AWS's private backbone. Traffic never leaves AWS infrastructure. This is a common and accepted pattern but is not encrypted.

**ALB → ECS**: HTTP on port 8000 inside the VPC. Same as above.

**ECS → RDS Proxy → RDS**: Unencrypted by default. RDS supports TLS but it is not configured here.

**ECS → Redis**: Unencrypted. ElastiCache supports TLS (`transit_encryption_enabled`) but it is not configured here.

### 3. Authentication and Authorisation

**JWT via HttpOnly cookies**
- Access token (1 day) and refresh token (7 days) are stored as `HttpOnly; Secure; SameSite=Lax` cookies
- `HttpOnly`: JavaScript cannot read the tokens — XSS attacks cannot steal them
- `Secure`: cookies are only sent over HTTPS
- `SameSite=Lax`: cookies are not sent on cross-site POST requests — CSRF protection at the browser level
- Refresh token rotation: on every refresh the old token is blacklisted and a new one is issued
- Logout blacklists the refresh token in the database so it cannot be reused even if captured

**Default-deny authorisation**
- `DEFAULT_PERMISSION_CLASSES = [IsAuthenticated]` means every endpoint requires auth unless explicitly opted out
- Only `health`, `auth/login`, `auth/refresh`, and `auth/logout` are public

**CSRF**
- `CSRF_TRUSTED_ORIGINS` set to the production domain — admin form submissions from other origins are rejected
- `SECURE_PROXY_SSL_HEADER` set so Django correctly identifies requests as HTTPS despite the HTTP ALB→ECS leg

### 4. Secrets Management

All secrets are stored in AWS Secrets Manager and injected at container startup — never in environment files, git, or Docker images:

| Secret | Path | What it holds |
|--------|------|----------------|
| DB credentials | `django-api/db-credentials` | RDS username + password |
| Django secret key | `django-api/secret-key` | Used for signing sessions and tokens |
| Superuser credentials | `django-api/superuser-credentials` | Admin portal login |

The ECS execution role has `secretsmanager:GetSecretValue` for exactly these three ARNs — nothing else.

The ECS task role (what the running Django code uses) has no Secrets Manager access — it only has SSM permissions for `execute-command` debugging.

### 5. Database

**RDS Proxy sits between ECS and RDS**
- The app connects to the proxy endpoint, not directly to RDS
- The proxy authenticates to RDS using the Secrets Manager credentials — the Django container never holds the real DB password in a persistent way
- Connection pooling prevents connection exhaustion under load

---

## Known Weak Spots

### High Priority

**`ALLOWED_HOSTS = "*"`**
Django accepts any `Host` header. The correct fix is to set this to `terraform-test.deepfeat.ai` and configure the ALB health check to send a specific `Host` header (using the ALB `host_header` condition), so the health check still passes. As-is, a malicious request with a spoofed `Host` header would not be rejected.

**No WAF (Web Application Firewall)**
There is no AWS WAF attached to CloudFront or the ALB. Common attacks — SQL injection, XSS, path traversal, large payload floods — are not filtered at the edge. AWS WAF can be attached to CloudFront with managed rule sets and costs ~$5/month plus per-request fees.

**No rate limiting on auth endpoints**
`POST /api/auth/login` has no brute-force protection. An attacker can attempt unlimited password guesses. Fix: add `django-ratelimit` (uses Redis, which is already present) to limit login attempts per IP.

**Django admin is publicly reachable**
`/admin/` is accessible from any IP on the internet. Automated scanners will find it and attempt credential stuffing. Fix options:
- Restrict by IP using a CloudFront geo/IP restriction or WAF rule
- Move to a non-standard URL (e.g., `path('internal-ops/', admin.site.urls)`)
- Require VPN before CloudFront routes the request

**Access token lifetime is 1 day**
If an access token cookie is somehow extracted (e.g., via a compromised browser extension), it is valid for 24 hours. Typical production systems use 15 minutes. The refresh token handles keeping users logged in silently. Reducing access token lifetime to 15 minutes would limit the blast radius of a token compromise with minimal UX impact.

### Medium Priority

**No TLS between ECS and Redis**
ElastiCache Redis is inside the VPC with security group restrictions, so it is not reachable from the internet. However, traffic is unencrypted inside the VPC. Add `transit_encryption_enabled = true` to the ElastiCache cluster and update the Django Redis URL to use `rediss://` (TLS scheme).

**No TLS between ECS and RDS**
Same situation. RDS supports TLS; the Django DB connection can be forced to require it with `'OPTIONS': {'sslmode': 'require'}`.

**No Redis authentication**
The ElastiCache cluster has no `auth_token`. Any ECS task (or future service) with the `ecs` security group attached can read and write the Redis cache freely. Add `auth_token` to the ElastiCache cluster and the `REDIS_URL`.

**`createsuperuser` CMD operator precedence bug**
The current Dockerfile CMD:
```
migrate --noinput && createsuperuser --noinput || true && gunicorn
```
Due to shell precedence this evaluates as:
```
((migrate && createsuperuser) || true) && gunicorn
```
If `migrate` **fails**, the `|| true` still makes the expression succeed and gunicorn starts — running against an unmigrated database. Fix:
```
migrate --noinput && (createsuperuser --noinput || true) && gunicorn
```

**Single NAT Gateway**
Both private subnets route through one NAT Gateway in `us-west-1a`. If that AZ has an outage, ECS tasks in `us-west-1c` lose outbound internet access (ECR pulls, Secrets Manager, CloudWatch logs). Production setups put a NAT Gateway in each AZ.

**Single ECS task (`desired_count = 1`)**
One task means one AZ failure or one bad deployment takes the service down entirely. Increasing to 2 tasks across both AZs provides redundancy.

### Low Priority

**CloudFront → S3 over HTTP**
The S3 website endpoint only speaks HTTP. This is acceptable for a public static site — the content is not sensitive. To enforce HTTPS, switch from the S3 website endpoint to an S3 REST endpoint with an OAC (Origin Access Control), which supports HTTPS and also makes the bucket private.

**No CloudFront access logging**
No record of who is hitting what paths, which makes detecting attack patterns (scanning, scraping, credential stuffing) impossible after the fact. Enable CloudFront access logs to S3.

**Short CloudWatch log retention (7 days)**
Forensic investigations often need weeks of logs. Increase to 30–90 days or ship logs to S3 for long-term storage.

**No GuardDuty**
AWS GuardDuty monitors API calls, network flows, and DNS queries for anomalous behaviour (e.g., a compromised ECS task making unusual outbound connections). It costs a small amount per GB of logs analysed and would be the first signal of a runtime compromise.

**S3 bucket is fully public**
The static site bucket has `block_public_acls = false` and a public-read bucket policy. Any file uploaded to the bucket is immediately public. Switching to OAC (mentioned above) would make the bucket private and only allow CloudFront to read it.

---

## Summary Table

| Control | Status |
|---------|--------|
| HTTPS to visitors | ✅ Enforced via CloudFront |
| HTTPS CloudFront → ALB | ❌ HTTP only (within AWS network) |
| HTTPS ALB → ECS | ❌ HTTP only (within AWS network) |
| HTTPS ECS → RDS | ❌ Not configured |
| HTTPS ECS → Redis | ❌ Not configured |
| Redis authentication | ❌ Not configured |
| Private subnets for backend | ✅ ECS, RDS, Redis all private |
| Security group least-privilege | ✅ Per-resource SG references |
| Secrets in code or git | ✅ All in Secrets Manager |
| HttpOnly JWT cookies | ✅ |
| CSRF protection | ✅ SameSite=Lax + CSRF_TRUSTED_ORIGINS |
| Default-deny authorisation | ✅ |
| Refresh token rotation + blacklist | ✅ |
| WAF | ❌ Not configured |
| Rate limiting on login | ❌ Not configured |
| Admin IP restriction | ❌ Publicly reachable |
| Access token lifetime | ⚠️ 1 day (consider 15 min) |
| ALLOWED_HOSTS | ⚠️ Wildcard |
| GuardDuty | ❌ Not enabled |
| CloudFront access logging | ❌ Not enabled |

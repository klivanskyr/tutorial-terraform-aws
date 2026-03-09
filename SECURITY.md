# Security Architecture

## Network Diagram

```
Internet
   │
   │ HTTPS (TLS 1.2+)
   ▼
┌─────────────────────────────────────────────────────┐
│  CloudFront (CDN + TLS termination)                 │
│  - ACM cert (us-east-1) for terraform-test.deepfeat │
│  - redirect-to-https on all behaviors               │
│  - /api/* and /admin* → ALB (no caching)            │
│  - /* (default) → S3 (static files, cached)         │
└────────────┬───────────────────────┬────────────────┘
             │ HTTP (within AWS)     │ HTTP (within AWS)
             ▼                       ▼
      ┌────────────┐         ┌──────────────────┐
      │    ALB     │         │  S3 Static Site  │
      │ (public    │         │  (index.html,    │
      │  subnets)  │         │   /static/ files)│
      └─────┬──────┘         └──────────────────┘
            │ HTTP :8000
            │ (private subnet, security group)
            ▼
   ┌─────────────────────┐
   │   ECS Fargate Task  │  (private subnet, no public IP)
   │   Django + Gunicorn │
   │   port 8000         │
   └────┬──────────┬─────┘
        │          │
        │ TLS      │ plaintext
        ▼          ▼
 ┌──────────┐  ┌──────────────┐
 │ RDS      │  │  ElastiCache │
 │ Proxy    │  │  Redis       │
 │ (private)│  │  (private)   │
 └────┬─────┘  └──────────────┘
      │ TLS (require_tls=true)
      ▼
 ┌──────────┐
 │ RDS      │
 │ Postgres │
 │ (private,│
 │ encrypted│
 │ at rest) │
 └──────────┘
```

---

## Security Controls by Layer

### 1. TLS / Encryption in Transit

| Segment | Protocol | Notes |
|---|---|---|
| Visitor → CloudFront | HTTPS, TLS 1.2+ | ACM cert, SNI-only |
| CloudFront → ALB | HTTP | Traffic never leaves AWS private network |
| CloudFront → S3 | HTTP | S3 website endpoint is HTTP-only |
| ALB → ECS | HTTP :8000 | Same VPC, no public path |
| ECS → RDS Proxy | TLS | `require_tls = true` on the proxy |
| RDS Proxy → RDS | TLS | AWS-managed, automatic |
| ECS → Redis | **No TLS** | Plaintext within VPC — see weak spots |

The CloudFront→ALB and CloudFront→S3 legs being HTTP is a deliberate, widely-accepted tradeoff. That traffic travels over AWS's internal network backbone, never the public internet.

### 2. Network Isolation (VPC + Security Groups)

Every resource uses least-privilege security group rules — no resource accepts traffic from "anywhere" except the ALB (which must face the internet).

```
Internet → ALB SG (ports 80, 443)
ALB SG   → ECS SG (port 8000 only, via security group reference)
ECS SG   → RDS Proxy SG (port 5432 only)
ECS SG   → Redis SG (port 6379 only)
RDS Proxy SG → RDS SG (port 5432 only)
```

- ECS tasks have **no public IP** (`assign_public_ip = false`)
- RDS, RDS Proxy, and Redis all live in **private subnets** with no internet gateway route
- Outbound internet from ECS goes through a **NAT Gateway** (private → NAT in public subnet → IGW)
- The NAT Gateway is the only way ECS can reach the internet; it is not reachable inbound

### 3. Authentication

**API authentication (JWT + HttpOnly cookies)**
- JWTs stored in HttpOnly cookies — JavaScript cannot read them (XSS protection)
- `Secure=True, SameSite=Lax` cookie flags prevent cross-site transmission
- Access token: 1-day lifetime
- Refresh token: 7-day lifetime with rotation — each use issues a new token
- Old refresh tokens are blacklisted in Postgres after rotation (`BLACKLIST_AFTER_ROTATION=True`)
- All API endpoints require authentication by default (`DEFAULT_PERMISSION_CLASSES = [IsAuthenticated]`)
- Public endpoints explicitly opt out with `permission_classes = [AllowAny]`
- CSRF protection is active (Django default) — required for admin form posts

**Django admin authentication**
- Session-based (Django's built-in admin auth)
- Superuser password auto-generated (24 chars, `random_password` resource) and stored in AWS Secrets Manager
- Password never appears in code or Terraform state as plaintext (it's in `random_password.result`)
- Credentials retrieved via: `aws secretsmanager get-secret-value --secret-id django-api/superuser-credentials`

### 4. Secrets Management

All sensitive values are stored in AWS Secrets Manager — nothing is hardcoded:

| Secret | Path | Used by |
|---|---|---|
| DB credentials | `django-api/db-credentials` | RDS Proxy + ECS task |
| Django SECRET_KEY | `django-api/secret-key` | ECS task |
| Superuser password | `django-api/superuser-credentials` | ECS task (startup) |

- ECS execution role has IAM permission scoped to **only these three secrets** (not `*`)
- RDS Proxy role has IAM permission scoped to **only the DB secret**
- Secrets are injected as environment variables at container start — the app never fetches them at runtime

### 5. Database

- RDS Postgres in private subnets, unreachable from the internet
- Storage encrypted at rest (AWS-managed keys)
- ECS connects to RDS **via the proxy**, never directly to the RDS instance
- RDS Proxy provides connection pooling (prevents connection exhaustion under load)
- `require_tls = true` on the proxy — all ECS↔Proxy traffic is encrypted
- DB password is 32 chars, generated by Terraform, never hardcoded

### 6. IAM (Least Privilege)

Two distinct IAM roles for ECS:

- **Execution role**: Used by the ECS control plane to pull images, write logs, fetch secrets. Managed policy `AmazonECSTaskExecutionRolePolicy` + inline policy for the three secrets.
- **Task role**: Used by running Django code. Only has SSM permissions for `aws ecs execute-command` (no S3, no DynamoDB, no SNS etc.)

### 7. Static Files

- Django admin static files served from S3 at `/static/`, not from the application server
- S3 bucket is publicly readable (required for static site hosting)
- Static files are extracted from the Docker image at deploy time and synced via `aws s3 sync --delete`
- No Gunicorn overhead for static file requests

---

## Known Weak Spots

### High Priority

**`ALLOWED_HOSTS = "*"`**
The ECS task definition sets `ALLOWED_HOSTS=*`. This means Django accepts requests with any Host header, which allows Host header injection attacks. The reason it's `*` is that ALB health checks send the private task IP as the Host header (e.g. `10.0.10.5:8000`), and we'd need to whitelist that dynamically or configure a fixed health check hostname on the ALB.
*Fix*: Set a custom `Host` header on the ALB health check rule, then set `ALLOWED_HOSTS=terraform-test.deepfeat.ai`.

**No WAF (Web Application Firewall)**
There is no AWS WAF attached to CloudFront or the ALB. Common attacks (SQL injection, XSS, bad bots, rate limiting) are not blocked at the edge.
*Fix*: Attach AWS WAF with the AWS managed rule groups to the CloudFront distribution.

**No login rate limiting**
`/api/auth/login` has no brute-force protection. An attacker can try passwords indefinitely.
*Fix*: Add `django-ratelimit` or a cache-based throttle to the login view.

**Admin panel publicly reachable**
`/admin*` is reachable from any IP on the internet via CloudFront. Anyone can attempt to log in.
*Fix*: Add a CloudFront geo-restriction or IP allowlist, or move admin behind a VPN/bastion.

### Medium Priority

**No Redis authentication or TLS**
Redis has no password (`AUTH` disabled) and no TLS. Anyone who gets into the VPC — a compromised ECS task, a misconfigured security group — can read or write the cache freely.
*Fix*: Enable ElastiCache in-transit encryption and set an auth token. Use `rediss://` URL in Django.

**ALB is internet-facing**
The ALB is `internal = false`, which means it has a public IP and DNS name. Only CloudFront should be sending it traffic, but the ALB itself has no restriction that enforces this — it accepts traffic from any IP.
*Fix*: Add an ALB listener rule that only allows traffic from CloudFront IP ranges (AWS publishes these), or restrict the ALB security group to CloudFront prefix lists.

**1-day access token lifetime**
If an access token is stolen (e.g. via a compromised device, a log that leaks the cookie value), the attacker has up to 24 hours before it expires. There is no mechanism to revoke access tokens before expiry.
*Fix*: Shorten access token lifetime to 15 minutes. The refresh flow is transparent to the browser.

**Dockerfile CMD operator precedence bug**
The container startup command is:
```
python manage.py migrate --noinput && python manage.py createsuperuser --noinput || true && gunicorn ...
```
Due to shell operator precedence (`||` binds before `&&` on the right), `|| true` applies to the entire chain. If `migrate` fails, `createsuperuser` is skipped but Gunicorn still starts — serving an unmigrated database.
*Fix*: Use explicit grouping: `(migrate && createsuperuser || true) && gunicorn ...`

### Low Priority

**Single NAT Gateway**
There is one NAT Gateway in `us-west-1a`. If that AZ goes down, ECS tasks in `us-west-1c` lose internet access (can't reach ECR, Secrets Manager, CloudWatch).
*Fix*: Add a second NAT Gateway in `us-west-1c` and add an AZ-specific private route table.

**Single ECS task**
`desired_count = 1`. If the task crashes, there's a window of downtime while ECS replaces it.
*Fix*: Set `desired_count = 2` and enable multi-AZ deployment.

**Backup retention is 1 day**
RDS automated backups are kept for only 1 day. If data is corrupted or accidentally deleted, you have a very narrow recovery window.
*Fix*: Set `backup_retention_period = 7` (or more) in production.

**`skip_final_snapshot = true` and `deletion_protection = false`**
`terraform destroy` would permanently delete the RDS instance and all data with no backup snapshot.
*Fix*: Set both to production-safe values before going live.

---

## Summary

| Control | Status | Notes |
|---|---|---|
| TLS for visitors | ✅ | CloudFront + ACM cert, TLS 1.2+ |
| TLS for ECS↔DB | ✅ | RDS Proxy `require_tls = true` |
| TLS for ECS↔Redis | ❌ | Plaintext, no auth |
| Network isolation | ✅ | Private subnets, security groups, no public IPs on ECS/RDS/Redis |
| ALB locked to CloudFront | ❌ | ALB publicly reachable on port 80 |
| API authentication | ✅ | JWT in HttpOnly cookies, default-deny |
| CSRF protection | ✅ | Django default middleware |
| Secrets management | ✅ | Secrets Manager, scoped IAM |
| DB encryption at rest | ✅ | RDS `storage_encrypted = true` |
| DB connection pooling | ✅ | RDS Proxy |
| Admin auto-provisioned | ✅ | Secrets Manager, never hardcoded |
| WAF | ❌ | Not configured |
| Login rate limiting | ❌ | Not implemented |
| Admin IP restriction | ❌ | Admin reachable from internet |
| ALLOWED_HOSTS locked | ❌ | Currently `*` |
| Short access token lifetime | ⚠️ | 1 day (recommended: 15 minutes) |
| High availability | ⚠️ | Single task, single NAT Gateway |
| DB deletion protection | ⚠️ | Disabled (fine for dev, not prod) |

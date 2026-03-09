provider "aws" {
  region = "us-west-1"
}

# The random provider generates random values (passwords, IDs, etc.) at
# plan time. It has no AWS dependency — it's a pure Terraform utility.
# We use it to generate a secure DB password so we never hardcode one.
provider "random" {}

# CloudFront is a global service but it can only use ACM certificates that
# are created in us-east-1. This is an AWS hard requirement — it doesn't matter
# where your bucket or distribution is. Terraform lets you define multiple
# provider configurations using an alias so you can target different regions
# within the same config.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

resource "aws_s3_bucket" "static_site" {
  bucket = "terraform-test.deepfeat.ai"

  # Allow `terraform destroy` to delete the bucket even if it has objects in it.
  # For production, remove this so you can't accidentally wipe your static files.
  force_destroy = true

  tags = {
    Name        = "terraform-test-static-site"
    Project     = "terraform-tutorial"
    Environment = "dev"
    ManagedBy   = "terraform"
  }
}

# S3 blocks all public access by default — we need to disable that
resource "aws_s3_bucket_public_access_block" "static_site" {
  bucket = aws_s3_bucket.static_site.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

# Allow anyone to read objects (serves the static files publicly)
resource "aws_s3_bucket_policy" "static_site" {
  bucket = aws_s3_bucket.static_site.id

  # Must wait for public access block to be removed first
  depends_on = [aws_s3_bucket_public_access_block.static_site]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "PublicReadGetObject"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.static_site.arn}/*"
      }
    ]
  })
}

# ============================================================
# ACM (AWS Certificate Manager) — TLS/SSL Certificate
# ============================================================

# ACM issues free TLS certificates. We're requesting one for our domain.
# We use DNS validation, which means AWS gives us a CNAME record to add to
# our DNS provider (Cloudflare). Once Cloudflare has that record, AWS can
# verify we own the domain and will issue the certificate.
#
# Note the `provider = aws.us_east_1` — this tells Terraform to use the
# aliased provider we defined above, so the cert is created in us-east-1.
resource "aws_acm_certificate" "cert" {
  provider          = aws.us_east_1
  domain_name       = "terraform-test.deepfeat.ai"
  validation_method = "DNS"

  # lifecycle rules control how Terraform handles resource replacement.
  # Normally if you change a cert, Terraform destroys the old one first —
  # but that would break your site. create_before_destroy tells Terraform
  # to spin up the new cert before tearing down the old one.
  lifecycle {
    create_before_destroy = true
  }
}

# This resource doesn't create anything in AWS — it just makes Terraform
# WAIT until the certificate is actually validated and issued before
# continuing. Without this, Terraform might try to attach an unvalidated
# cert to CloudFront and fail.
#
# Since our DNS is on Cloudflare (not Route53), Terraform can't add the
# validation CNAME automatically. Instead we'll output the record you need
# to add manually. Once you add it, this resource will unblock and finish.
resource "aws_acm_certificate_validation" "cert" {
  provider        = aws.us_east_1
  certificate_arn = aws_acm_certificate.cert.arn
}

# ============================================================
# CloudFront Distribution
# ============================================================

# CloudFront is AWS's CDN (Content Delivery Network). It sits in front of
# your S3 bucket and handles:
#   - HTTPS termination (using the ACM cert above)
#   - Caching your content at edge locations worldwide
#   - Redirecting HTTP → HTTPS
resource "aws_cloudfront_distribution" "static_site" {
  enabled             = true
  default_root_object = "index.html" # Serve this when someone hits the root URL

  # An "origin" is the backend server CloudFront fetches content from.
  # We point it at the S3 website endpoint (not the raw S3 bucket URL).
  # The website endpoint is important because it understands index.html
  # routing and 404 handling — the raw bucket URL does not.
  origin {
    # website_endpoint looks like: bucket-name.s3-website-us-west-1.amazonaws.com
    domain_name = aws_s3_bucket_website_configuration.static_site.website_endpoint
    origin_id   = "S3StaticSite" # A local label — used to link origins to behaviors below

    # The S3 website endpoint only speaks HTTP (not HTTPS).
    # CloudFront talks to it over HTTP on the backend, but serves
    # HTTPS to your visitors on the frontend. This is fine for a
    # public static site — the content isn't sensitive in transit.
    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  # Second origin: the ALB in front of ECS/Django.
  # CloudFront connects to it over HTTP (port 80) — HTTPS is handled by
  # CloudFront on the visitor side, so the CF→ALB leg stays within AWS's network.
  origin {
    domain_name = aws_lb.main.dns_name
    origin_id   = "ALBDjangoAPI"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  # ordered_cache_behavior rules are evaluated top to bottom.
  # The first match wins. This one catches all /api/* requests and
  # sends them to Django instead of S3.
  #
  # Key differences from the static site behavior:
  #   - All HTTP methods allowed (APIs need POST, PUT, DELETE, etc.)
  #   - Query strings, headers, and cookies all forwarded (APIs need them)
  #   - TTL = 0 everywhere (never cache API responses)
  ordered_cache_behavior {
    path_pattern     = "/api/*"
    target_origin_id = "ALBDjangoAPI"

    allowed_methods = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods  = ["GET", "HEAD"]

    viewer_protocol_policy = "redirect-to-https"

    forwarded_values {
      query_string = true
      headers      = ["*"]  # Forward all headers (Authorization, Content-Type, etc.)
      cookies {
        forward = "all"
      }
    }

    # Zero TTL = CloudFront never caches. Every request goes through to Django.
    min_ttl     = 0
    default_ttl = 0
    max_ttl     = 0
  }

  # Route /admin/* to Django. Same pattern as /api/* — all methods, all cookies,
  # all headers forwarded, zero caching. The two things that make admin special:
  #   - Cookies: Django uses a session cookie (not JWT) for admin auth
  #   - Headers: Django's CSRF checks the Referer header — it must be forwarded
  ordered_cache_behavior {
    path_pattern     = "/admin*"
    target_origin_id = "ALBDjangoAPI"

    allowed_methods = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods  = ["GET", "HEAD"]

    viewer_protocol_policy = "redirect-to-https"

    forwarded_values {
      query_string = true
      headers      = ["*"]
      cookies {
        forward = "all"
      }
    }

    min_ttl     = 0
    default_ttl = 0
    max_ttl     = 0
  }

  # Cache behaviors define how CloudFront handles requests.
  # "default" applies to all paths not matched by a more specific behavior.
  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD"]          # Only allow read requests
    cached_methods         = ["GET", "HEAD"]          # Cache these method responses
    target_origin_id       = "S3StaticSite"           # Must match the origin_id above
    viewer_protocol_policy = "redirect-to-https"      # Auto-redirect HTTP → HTTPS

    # forwarded_values controls what request info gets passed to the origin.
    # For a static site we don't need query strings or cookies,
    # so we strip them — this maximizes cache hit rate.
    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }
  }

  # viewer_certificate configures HTTPS for visitors.
  # We attach our ACM cert here. Note we depend on the _validation_ resource
  # (not the cert itself) to ensure the cert is fully issued before use.
  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.cert.certificate_arn
    ssl_support_method       = "sni-only" # SNI is the modern standard and is free.
                                          # The alternative (vip) costs ~$600/month.
    minimum_protocol_version = "TLSv1.2_2021" # Disables old, insecure TLS versions
  }

  # aliases are the custom domain names this distribution responds to.
  # Without this, CloudFront only responds to its own *.cloudfront.net domain.
  aliases = ["terraform-test.deepfeat.ai"]

  # geo_restriction lets you block or allowlist countries.
  # We're not restricting anything here.
  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  tags = {
    Name        = "terraform-test-static-site"
    Project     = "terraform-tutorial"
    Environment = "dev"
    ManagedBy   = "terraform"
  }
}

# Enable S3's built-in static website hosting
resource "aws_s3_bucket_website_configuration" "static_site" {
  bucket = aws_s3_bucket.static_site.id

  index_document {
    suffix = "index.html"
  }

  error_document {
    key = "404.html"
  }
}

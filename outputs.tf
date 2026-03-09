output "admin_credentials_secret" {
  description = "Retrieve the admin password: aws secretsmanager get-secret-value --secret-id django-api/superuser-credentials --query SecretString --output text"
  value       = aws_secretsmanager_secret.superuser.name
}

output "s3_bucket_name" {
  description = "S3 bucket name — used by deploy.sh to sync static files"
  value       = aws_s3_bucket.static_site.id
}

output "s3_website_endpoint" {
  description = "The raw S3 static website URL (HTTP only). CloudFront uses this as its origin."
  value       = aws_s3_bucket_website_configuration.static_site.website_endpoint
}

# After running `terraform apply`, Terraform will pause at the certificate
# validation step and print this output. Copy the name/value from here and
# add a CNAME record in Cloudflare (with the proxy OFF / gray cloud).
# Once Cloudflare has that record, AWS will validate the cert and Terraform
# will continue creating the CloudFront distribution.
output "acm_validation_cname" {
  description = "Add this CNAME to Cloudflare (DNS only, not proxied) to validate your ACM certificate."
  value = {
    for dvo in aws_acm_certificate.cert.domain_validation_options : dvo.domain_name => {
      cname_name  = dvo.resource_record_name
      cname_value = dvo.resource_record_value
    }
  }
}

# Once the distribution is created, take this domain and add it as a CNAME
# in Cloudflare pointing to terraform-test.deepfeat.ai.
# Keep the Cloudflare proxy OFF (gray cloud) to avoid double-proxying.
output "cloudfront_domain" {
  description = "Point your Cloudflare CNAME at this domain (DNS only, not proxied)."
  value       = aws_cloudfront_distribution.static_site.domain_name
}
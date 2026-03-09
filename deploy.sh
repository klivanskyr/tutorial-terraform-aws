#!/bin/bash
set -e

REGION="us-west-1"
ECR_URL=$(terraform output -raw ecr_repository_url)
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Authenticate Docker to ECR
aws ecr get-login-password --region $REGION | \
  docker login --username AWS --password-stdin "$AWS_ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"

# Build, tag, push
cd django/
docker build -t django-app .
cd ..

docker tag django-app:latest "$ECR_URL:latest"
docker push "$ECR_URL:latest"

# Sync admin static files to S3.
# collectstatic already ran inside the Docker build, so we extract the result
# from the image rather than re-running it locally (avoids needing Django
# installed on the deploy machine).
S3_BUCKET=$(terraform output -raw s3_bucket_name)
CONTAINER_ID=$(docker create django-app:latest)
docker cp "$CONTAINER_ID:/app/staticfiles/." ./staticfiles_tmp/
docker rm "$CONTAINER_ID"

aws s3 sync ./staticfiles_tmp/ "s3://$S3_BUCKET/static/" \
  --delete \
  --region $REGION

rm -rf ./staticfiles_tmp

# Always deploy with the latest task definition revision.
# Terraform may have created new revisions (e.g. when env vars or secrets
# change) without updating the service (due to ignore_changes). This ensures
# we never get stuck on an old revision with stale config.
LATEST_TASK_DEF=$(aws ecs describe-task-definition \
  --task-definition django-api \
  --region $REGION \
  --query 'taskDefinition.taskDefinitionArn' \
  --output text)

aws ecs update-service \
  --cluster django-api \
  --service django-api \
  --task-definition "$LATEST_TASK_DEF" \
  --force-new-deployment \
  --region $REGION \
  --no-cli-pager

#!/bin/bash
set -e  # exit immediately if any command fails

BUCKET="terraform-test.deepfeat.ai"
BUILD_DIR="web-app/dist"

echo "Building Next.js..."
cd web-app
npm run build
cd ..

echo "Uploading to s3://$BUCKET ..."
# --delete removes files from S3 that no longer exist in the build output
aws s3 sync "$BUILD_DIR" "s3://$BUCKET" --delete

echo "Done. Visit: http://$BUCKET.s3-website-us-west-1.amazonaws.com"

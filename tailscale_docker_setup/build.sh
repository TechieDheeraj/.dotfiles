#! /bin/bash
echo "=========================================================="
echo " IMAGE_TAG: ${IMAGE_TAG:=nginx:v2}"
echo "=========================================================="

set -x

docker build . -f Dockerfile \
		--tag ${IMAGE_TAG}

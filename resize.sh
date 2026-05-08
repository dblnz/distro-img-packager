#!/bin/bash

set -euo pipefail

RAW_IMAGE="${RAW_IMAGE:-image.raw}"
mb=$((1024*1024))

size="$(qemu-img info -f raw --output json "$RAW_IMAGE" | jq -r '."virtual-size"')"
rounded_size=$((((size+mb-1)/mb)*mb))

# check if the image is already large enough
if [ "$size" -ge "$rounded_size" ]; then
	echo "Image already has a rounded size: $size bytes"
	exit 0
fi

qemu-img resize -f raw "$RAW_IMAGE" "$rounded_size"
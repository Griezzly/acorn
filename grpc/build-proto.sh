#!/usr/bin/env bash
# Compiles the obama-proto files for Go
# Requires protoc
# and Google protobuf files in /usr/include
# or /usr/local/include

# Change directory to where script is located
cd "$(dirname "$0")"

includeDir="/usr/include"
if [ ! -d "/usr/include" ]; then
  # Macs often do not have access to the /usr/include folder, but rather to /usr/local/include
  includeDir="/usr/local/include"
fi

# Generate .pb.go files
protoc -I$includeDir -I. ./*.proto --go_out=. --go-grpc_out=.
#!/bin/bash
# generate-certs.sh — Generate CA + client certificate for IAM Roles Anywhere.
#
# Usage: ./generate-certs.sh [output_dir]
#
# Produces:
#   ca.key / ca.crt        — Certificate Authority (keep ca.key offline!)
#   client.key / client.crt — Client cert signed by CA (deployed to MCP server)
#
# The CA cert is uploaded to IAM Roles Anywhere as the Trust Anchor source.
# The client cert+key are stored in Secrets Manager for ECS task injection.
set -euo pipefail

OUTPUT_DIR="${1:-./certs}"
mkdir -p "$OUTPUT_DIR"

CA_DAYS=3650          # 10 years
CLIENT_DAYS=365       # 1 year (rotate annually)
CA_SUBJECT="/CN=MCP Bridge CA/O=DevOps Agent"
CLIENT_SUBJECT="/CN=mcp-bridge-client/O=DevOps Agent"

echo "==> Generating CA key + certificate (valid ${CA_DAYS} days)..."
openssl genrsa -out "$OUTPUT_DIR/ca.key" 4096
openssl req -new -x509 \
  -key "$OUTPUT_DIR/ca.key" \
  -out "$OUTPUT_DIR/ca.crt" \
  -days "$CA_DAYS" \
  -subj "$CA_SUBJECT"

echo "==> Generating client key + CSR..."
openssl genrsa -out "$OUTPUT_DIR/client.key" 2048
openssl req -new \
  -key "$OUTPUT_DIR/client.key" \
  -out "$OUTPUT_DIR/client.csr" \
  -subj "$CLIENT_SUBJECT"

echo "==> Signing client cert with CA (valid ${CLIENT_DAYS} days)..."
openssl x509 -req \
  -in "$OUTPUT_DIR/client.csr" \
  -CA "$OUTPUT_DIR/ca.crt" \
  -CAkey "$OUTPUT_DIR/ca.key" \
  -CAcreateserial \
  -out "$OUTPUT_DIR/client.crt" \
  -days "$CLIENT_DAYS"

rm -f "$OUTPUT_DIR/client.csr" "$OUTPUT_DIR/ca.srl"

echo ""
echo "=== Done ==="
echo "CA cert (upload to Roles Anywhere):  $OUTPUT_DIR/ca.crt"
echo "Client cert (store in SM):           $OUTPUT_DIR/client.crt"
echo "Client key (store in SM):            $OUTPUT_DIR/client.key"
echo "CA key (KEEP OFFLINE!):              $OUTPUT_DIR/ca.key"
echo ""
echo "Next steps:"
echo "  1. Deploy cfn/roles-anywhere-hub.yaml with CACertificateBody=\$(cat $OUTPUT_DIR/ca.crt)"
echo "  2. Store client cert+key in Secrets Manager:"
echo "     aws secretsmanager create-secret --name /mcp/ra-cert --secret-string file://$OUTPUT_DIR/client.crt"
echo "     aws secretsmanager create-secret --name /mcp/ra-key  --secret-string file://$OUTPUT_DIR/client.key"

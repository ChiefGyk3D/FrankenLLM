#!/bin/bash
# Test connection and services

SERVER_IP="192.168.201.145"

echo "Testing LLM server endpoints..."
echo ""

echo "1. Testing 5060 Ti server (port 8080):"
curl -s http://$SERVER_IP:8080/health || echo "Not responding"
echo ""

echo "2. Testing 3050 server (port 8081):"
curl -s http://$SERVER_IP:8081/health || echo "Not responding"
echo ""

echo "3. For Ollama, test with:"
echo "   curl http://$SERVER_IP:11434/api/tags"
echo "   curl http://$SERVER_IP:11435/api/tags"

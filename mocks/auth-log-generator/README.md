# Mock Authentication Log Generator

This service generates realistic authentication log events for testing the ZTAC IP Reputation Engine.

## Purpose

Simulates authentication attempts from various IP addresses with different success/failure patterns:
- **Attacker IPs**: High failure rate (95% fail) - triggers ZTAC blocking
- **Legitimate IPs**: High success rate (90% succeed) - normal user behavior
- **Corporate IPs**: Always successful - simulates always-allowed list

## Configuration

### IP Addresses

**Attackers** (repeated failures - should be blocked by ZTAC):
- 203.0.113.5
- 203.0.113.42
- 198.51.100.88

**Legitimate Users** (mostly successful):
- 10.0.1.50, 10.0.1.51
- 192.168.1.100, 192.168.1.101
- 172.16.0.25

**Corporate Network** (always allowed):
- 10.0.0.10, 10.0.0.11

### Tenants
- patmon
- perimara
- demo-tenant

## Log Format

Outputs JSON logs to stdout in this format:

```json
{
  "timestamp": "2024-01-15T10:30:45.123456Z",
  "level": "WARN",
  "service": "auth-service",
  "tenant": "patmon",
  "event_type": "authentication",
  "auth": {
    "ip_address": "203.0.113.5",
    "username": "admin",
    "success": false,
    "method": "password",
    "user_agent": "curl/7.68.0",
    "failure_reason": "invalid_credentials"
  }
}
```

## How It Works

1. Generates authentication events every 2 seconds
2. Outputs JSON logs to stdout
3. Grafana Alloy collects these logs from Kubernetes pod logs
4. Alloy parses JSON and sends to ZTAC via OTLP (port 4317)
5. ZTAC analyzes failure patterns and blocks malicious IPs

## Testing ZTAC

After deploying with `./deploy.sh`:

1. **Watch the logs**:
   ```bash
   kubectl logs -f -l app=auth-log-generator
   ```

2. **Check Alloy is collecting logs**:
   ```bash
   kubectl logs -f -l app=alloy
   ```

3. **Query ZTAC for blocked IPs** (after 5+ failures):
   Use the ZTAC gRPC API on port 9090 to check IP reputation

## Expected Behavior

After running for 1-2 minutes:
- Attacker IPs (203.0.113.*) should accumulate failures
- ZTAC should block these IPs based on `loginFailureThreshold`
- Legitimate IPs should remain unblocked
- Corporate IPs should never be blocked (always-allowed list)

## Customization

Edit `generate_auth_logs.py` to change:
- `LOG_INTERVAL`: Time between log batches (default: 2 seconds)
- IP address lists
- Failure rates
- Usernames
- Tenants

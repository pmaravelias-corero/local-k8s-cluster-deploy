#!/usr/bin/env python3
"""
Mock Authentication Log Generator
Generates realistic authentication attempt logs for testing ZTAC IP reputation engine.
Outputs JSON logs to stdout for collection by Grafana Alloy.
"""
import json
import time
import random
import os
from datetime import datetime

# Configuration
LOG_INTERVAL = 2  # seconds between log batches

# Read tenants from environment variable (comma-separated)
TENANTS_ENV = os.getenv('TENANTS')
TENANTS = [t.strip() for t in TENANTS_ENV.split(',') if t.strip()]

# IP addresses that will be "attackers" (repeated failures)
ATTACKER_IPS = [
    '203.0.113.5',    # Will fail repeatedly
    '203.0.113.42',   # Another attacker
    '198.51.100.88',  # Occasional attacker
]

# Legitimate user IPs (mostly successful)
LEGITIMATE_IPS = [
    '10.0.1.50',
    '10.0.1.51',
    '192.168.1.100',
    '192.168.1.101',
    '172.16.0.25',
]

# Corporate network (always allowed in ZTAC config)
CORPORATE_IPS = [
    '10.0.0.10',
    '10.0.0.11',
]

USERNAMES_LEGITIMATE = [
    'admin@example.com',
    'john.doe@example.com',
    'jane.smith@example.com',
    'operator@example.com',
]

USERNAMES_ATTACKER = [
    'admin',
    'administrator',
    'root',
    'test',
    'admin@admin.com',
]

def generate_auth_event(tenant, ip, username, success, reason=None):
    """Generate a single authentication log event in JSON format."""
    event = {
        'timestamp': datetime.utcnow().isoformat() + 'Z',
        'level': 'INFO' if success else 'WARN',
        'service': 'auth-service',
        'tenant': tenant,
        'event_type': 'authentication',
        'auth': {
            'ip_address': ip,
            'username': username,
            'success': success,
            'method': 'password',
            'user_agent': 'Mozilla/5.0' if random.random() > 0.3 else 'curl/7.68.0',
        }
    }

    if not success and reason:
        event['auth']['failure_reason'] = reason

    return event

def generate_log_batch():
    """Generate a batch of authentication log events."""
    events = []

    # Generate attacker attempts (mostly failures)
    for _ in range(random.randint(3, 8)):
        ip = random.choice(ATTACKER_IPS)
        tenant = random.choice(TENANTS)
        username = random.choice(USERNAMES_ATTACKER)

        # Attackers fail 95% of the time
        success = random.random() < 0.05
        reason = random.choice([
            'invalid_credentials',
            'user_not_found',
            'password_mismatch',
            'account_locked'
        ]) if not success else None

        events.append(generate_auth_event(tenant, ip, username, success, reason))

    # Generate legitimate user attempts (mostly successes)
    for _ in range(random.randint(5, 10)):
        ip = random.choice(LEGITIMATE_IPS)
        tenant = random.choice(TENANTS)
        username = random.choice(USERNAMES_LEGITIMATE)

        # Legitimate users succeed 90% of the time
        success = random.random() < 0.90
        reason = random.choice([
            'invalid_credentials',
            'session_expired',
        ]) if not success else None

        events.append(generate_auth_event(tenant, ip, username, success, reason))

    # Generate corporate network access (always successful)
    if random.random() < 0.3:  # 30% chance per batch
        ip = random.choice(CORPORATE_IPS)
        tenant = random.choice(TENANTS)
        username = random.choice(USERNAMES_LEGITIMATE)

        events.append(generate_auth_event(tenant, ip, username, True))

    return events

def main():
    print("=" * 80)
    print("Mock Authentication Log Generator")
    print("=" * 80)
    print(f"Generating authentication logs every {LOG_INTERVAL} seconds")
    print(f"Tenants: {', '.join(TENANTS)}")
    print(f"Attacker IPs (high failure rate): {', '.join(ATTACKER_IPS)}")
    print(f"Legitimate IPs (high success rate): {', '.join(LEGITIMATE_IPS)}")
    print(f"Corporate IPs (always allowed): {', '.join(CORPORATE_IPS)}")
    print("=" * 80)
    print()

    iteration = 0
    while True:
        try:
            iteration += 1
            events = generate_log_batch()

            # Output each event as a JSON line
            for event in events:
                print(json.dumps(event), flush=True)

            if iteration % 10 == 0:  # Status update every 10 iterations
                failures = sum(1 for e in events if not e['auth']['success'])
                print(json.dumps({
                    'timestamp': datetime.utcnow().isoformat() + 'Z',
                    'level': 'INFO',
                    'service': 'auth-log-generator',
                    'message': f'Generated {len(events)} events ({failures} failures)',
                    'iteration': iteration
                }), flush=True)

            time.sleep(LOG_INTERVAL)

        except Exception as e:
            print(json.dumps({
                'timestamp': datetime.utcnow().isoformat() + 'Z',
                'level': 'ERROR',
                'service': 'auth-log-generator',
                'message': f'Error generating logs: {str(e)}'
            }), flush=True)
            time.sleep(LOG_INTERVAL)

if __name__ == '__main__':
    main()

#!/usr/bin/env python3
import time
import random
import os
from prometheus_client import CollectorRegistry, Gauge, push_to_gateway
import requests

PUSHGATEWAY_URL = 'pushgateway:19091'
PUSH_INTERVAL = 15  # seconds

# Read tenants from environment variable (comma-separated)
TENANTS_ENV = os.getenv('TENANTS')
TENANTS = [t.strip() for t in TENANTS_ENV.split(',') if t.strip()]

def generate_metrics():
    """Generate synthetic metrics and push to Pushgateway"""
    
    registry = CollectorRegistry()
    
    # The key metric your operational-api queries
    # sum:cnstraffic_interface_rx_bytes:rate5m, rate1h, rate1d
    # These are recording rules, but we'll generate the base metrics they aggregate from

    cnstraffic_rx_5m = Gauge(
        'sum:cnstraffic_interface_rx_bytes:rate5m',
        'Network traffic RX bytes rate over 5 minutes',
        ['tenant', 'provider', 'connectionType', 'interface', 'nodetype', 'node'],
        registry=registry
    )

    cnstraffic_rx_1h = Gauge(
        'sum:cnstraffic_interface_rx_bytes:rate1h',
        'Network traffic RX bytes rate over 1 hour',
        ['tenant', 'provider', 'connectionType', 'interface', 'nodetype', 'node'],
        registry=registry
    )

    cnstraffic_rx_1d = Gauge(
        'sum:cnstraffic_interface_rx_bytes:rate1d',
        'Network traffic RX bytes rate over 1 day',
        ['tenant', 'provider', 'connectionType', 'interface', 'nodetype', 'node'],
        registry=registry
    )

    # Additional useful metrics
    active_connections = Gauge(
        'active_connections_total',
        'Total active connections',
        ['tenant', 'provider', 'connectionType', 'nodetype', 'node'],
        registry=registry
    )

    packet_loss_rate = Gauge(
        'packet_loss_rate_percent',
        'Packet loss rate percentage',
        ['tenant', 'provider', 'connectionType', 'nodetype', 'node'],
        registry=registry
    )
    
    print("Starting metric generation for Operational API...")
    print(f"Pushing to {PUSHGATEWAY_URL} every {PUSH_INTERVAL} seconds")
    
    # Define realistic providers and connection types
    providers = [
        'AWS',
        'GCP',
        'Azure',
        'Cloudflare',
        'Akamai',
        'DigitalOcean'
    ]

    connection_types = [
        'Direct',
        'Transit',
        'Peering',
        'VPN'
    ]

    node_types = ['router']

    nodes = ['bot0', 'bot1', 'bot2', 'bot3']

    tenants = TENANTS  # Use tenants from environment variable

    # Provider-specific interface naming patterns
    # Each provider-connection type combination gets distinct interfaces
    provider_interfaces = {
        'AWS': {
            'Direct': ['eth0', 'eth1', 'ens5'],
            'Transit': ['eth0', 'eth2', 'ens6'],
            'Peering': ['eth1', 'ens5', 'ens7'],
            'VPN': ['tun0', 'tun1', 'eth0']
        },
        'GCP': {
            'Direct': ['ens4', 'ens5', 'gce0'],
            'Transit': ['ens4', 'ens6', 'gce1'],
            'Peering': ['ens5', 'gce0', 'gce2'],
            'VPN': ['tun0', 'tun1', 'ens4']
        },
        'Azure': {
            'Direct': ['eth0', 'eth1', 'eth2'],
            'Transit': ['eth0', 'eth3', 'eth4'],
            'Peering': ['eth1', 'eth2', 'eth5'],
            'VPN': ['tun0', 'tun1', 'eth0']
        },
        'Cloudflare': {
            'Direct': ['cf-wan0', 'cf-wan1', 'eth0'],
            'Transit': ['cf-wan0', 'cf-wan2', 'eth1'],
            'Peering': ['cf-peer0', 'cf-peer1', 'cf-wan0'],
            'VPN': ['tun0', 'tun1', 'cf-wan0']
        },
        'Akamai': {
            'Direct': ['aka0', 'aka1', 'eth0'],
            'Transit': ['aka0', 'aka2', 'eth1'],
            'Peering': ['aka-peer0', 'aka-peer1', 'aka0'],
            'VPN': ['tun0', 'tun1', 'aka0']
        },
        'DigitalOcean': {
            'Direct': ['eth0', 'eth1', 'vtnet0'],
            'Transit': ['eth0', 'eth2', 'vtnet1'],
            'Peering': ['eth1', 'vtnet0', 'vtnet2'],
            'VPN': ['tun0', 'tun1', 'eth0']
        }
    }
    
    iteration = 0
    while True:
        try:
            iteration += 1
            
            # Generate traffic metrics for each combination
            for tenant in tenants:
                for provider in providers:
                    for conn_type in connection_types:
                        # Not all combinations exist - add some randomness
                        if random.random() < 0.3:  # 30% chance to skip this combo
                            continue

                        # Get provider-specific interfaces for this connection type
                        interfaces = provider_interfaces[provider][conn_type]

                        for node_type in node_types:
                            for node in nodes:
                                # Some nodes may not be active for this combo
                                if random.random() < 0.4:  # 40% chance to skip this node
                                    continue

                                for interface in interfaces:
                                    # Generate realistic traffic values (bytes per second)
                                    # 5m rate: higher granularity, more variation
                                    base_rate_5m = random.uniform(1e6, 100e6)  # 1MB/s to 100MB/s
                                    cnstraffic_rx_5m.labels(
                                        tenant=tenant,
                                        provider=provider,
                                        connectionType=conn_type,
                                        interface=interface,
                                        nodetype=node_type,
                                        node=node
                                    ).set(base_rate_5m)

                                    # 1h rate: smoother, averaged out
                                    base_rate_1h = base_rate_5m * random.uniform(0.8, 1.2)
                                    cnstraffic_rx_1h.labels(
                                        tenant=tenant,
                                        provider=provider,
                                        connectionType=conn_type,
                                        interface=interface,
                                        nodetype=node_type,
                                        node=node
                                    ).set(base_rate_1h)

                                    # 1d rate: even smoother
                                    base_rate_1d = base_rate_1h * random.uniform(0.9, 1.1)
                                    cnstraffic_rx_1d.labels(
                                        tenant=tenant,
                                        provider=provider,
                                        connectionType=conn_type,
                                        interface=interface,
                                        nodetype=node_type,
                                        node=node
                                    ).set(base_rate_1d)

                                # Connection and quality metrics (per node)
                                active_connections.labels(
                                    tenant=tenant,
                                    provider=provider,
                                    connectionType=conn_type,
                                    nodetype=node_type,
                                    node=node
                                ).set(random.randint(10, 1000))

                                packet_loss_rate.labels(
                                    tenant=tenant,
                                    provider=provider,
                                    connectionType=conn_type,
                                    nodetype=node_type,
                                    node=node
                                ).set(random.uniform(0.0, 2.5))
            
            # Push to gateway
            push_to_gateway(PUSHGATEWAY_URL, job='cnstraffic_metrics', registry=registry)
            
            if iteration % 4 == 0:  # Log every minute (4 * 15s)
                print(f"✓ Pushed metrics at {time.strftime('%Y-%m-%d %H:%M:%S')}")
                print(f"  Generated data for {len(tenants)} tenants, {len(providers)} providers")
            
        except Exception as e:
            print(f"✗ Error pushing metrics: {e}")
        
        time.sleep(PUSH_INTERVAL)

if __name__ == '__main__':
    print("=" * 60)
    print("Operational API Metrics Generator")
    print("=" * 60)
    print(f"Target: {PUSHGATEWAY_URL}")
    print(f"Interval: {PUSH_INTERVAL}s")
    print("=" * 60)
    generate_metrics()
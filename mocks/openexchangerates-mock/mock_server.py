#!/usr/bin/env python3
from flask import Flask, request, jsonify
import time
import random

app = Flask(__name__)

# Base exchange rates (USD base)
BASE_RATES = {
    "AED": 3.673,
    "AUD": 1.532,
    "CAD": 1.393,
    "CHF": 0.884,
    "CNY": 7.245,
    "EUR": 0.925,
    "GBP": 0.790,
    "HKD": 7.773,
    "INR": 83.42,
    "JPY": 149.83,
    "KRW": 1383.50,
    "MXN": 17.08,
    "NOK": 10.89,
    "NZD": 1.677,
    "RUB": 92.50,
    "SEK": 10.76,
    "SGD": 1.344,
    "TRY": 34.15,
    "USD": 1.0,
    "ZAR": 18.23
}

def add_variation(rate):
    """Add small random variation to simulate market changes"""
    variation = random.uniform(-0.02, 0.02)  # ±2% variation
    return round(rate * (1 + variation), 6)

@app.route('/api/latest.json', methods=['GET'])
def get_latest_rates():
    """Mock OpenExchangeRates latest endpoint"""
    
    # Check for Authorization header (optional, just for logging)
    auth = request.headers.get('Authorization', '')
    if auth:
        print(f"[Mock OpenExchangeRates] Request with auth: {auth[:20]}...")
    
    # Generate rates with slight variations
    current_rates = {
        currency: add_variation(rate) 
        for currency, rate in BASE_RATES.items()
    }
    
    response = {
        "disclaimer": "Mock data for development - Usage subject to terms: https://openexchangerates.org/terms",
        "license": "Mock License",
        "timestamp": int(time.time()),
        "base": "USD",
        "rates": current_rates
    }
    
    print(f"[Mock OpenExchangeRates] Served {len(current_rates)} exchange rates")
    return jsonify(response), 200

@app.route('/health', methods=['GET'])
def health():
    return jsonify({"status": "healthy"}), 200

if __name__ == '__main__':
    print("=" * 60)
    print("OpenExchangeRates Mock API Server")
    print("=" * 60)
    print("Listening on http://0.0.0.0:8080")
    print("Endpoint: /api/latest.json")
    print("=" * 60)
    app.run(host='0.0.0.0', port=8080, debug=False)
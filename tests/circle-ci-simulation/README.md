# CircleCI Simulation Tests

This directory contains tests to simulate CircleCI pipeline behavior locally.

## Purpose

Simulate CircleCI cache restore and build behavior to verify:
1. Musl-cross-make skip logic works after cache restore
2. Cache key hashing matches CircleCI behavior
3. Timestamp refresh behavior

## Usage

```bash
# Run all tests
./run_tests.sh

# Run specific test
./test_musl_skip.sh

# Simulate cold cache (removes build artifacts)
./simulate_cold_cache.sh
```

## Test Structure

- `simulate_cold_cache.sh` - Removes build artifacts to simulate first run
- `test_musl_skip.sh` - Verifies musl-cross-make skips when crossgcc exists
- `test_cache_hash.sh` - Verifies cache key generation matches CircleCI
- `run_tests.sh` - Main test runner
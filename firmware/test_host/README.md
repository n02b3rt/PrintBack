# Host-side unit tests

Tests pure logic from `firmware/main/` without hardware and without
ESP-IDF, plain gcc on this machine.

## Convention

A module qualifies for testing here if it **doesn't** have any
ESP-IDF/hardware includes (`freertos/*.h`, `esp_*.h`, `nvs*.h`,
`driver/*.h`, `mbedtls/*.h`), i.e. it's plain, portable C.

For a module `firmware/main/X.c` add `test_X.c` here. `run_tests.sh`
finds the pair by name on its own and compiles it with host gcc, no CMake.

## Usage

```sh
./run_tests.sh
```

## Current tests

- `test_kanon.c`: the k-anonymity threshold (an hourly aggregate < 5
  events → don't publish, fold into the daily total)

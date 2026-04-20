# EasyNet 0.1.0-beta.2

## Highlights

- Added client auto reconnect with configurable retry backoff and jitter.
- Added client heartbeat scheduling and heartbeat failure reporting.
- Added client and server traffic monitoring with unified runtime traffic events.
- Added client/server observability configuration entry points.
- Added facade-facing `EasyNet...` typealiases and tightened README guidance around recommended public APIs.
- Split core tests into focused files and expanded coverage to 37 passing tests.

## API And Documentation

- Standardized packet request guidance around `request(packet:...)`.
- Clarified compatibility aliases vs recommended entry points.
- Clarified system plugins vs demo plugins and demo messages vs business messages.
- Added a formal business integration template showing how to define custom messages and plugins.

## Validation

- Full `swift test` passed locally with 37 tests and 0 failures.

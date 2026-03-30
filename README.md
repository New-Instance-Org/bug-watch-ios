# NISDK iOS Starter

Minimal Swift Package and CocoaPods starter for NISDK.

## Features

- Single public entry point
- Shared configuration model
- No product-specific business logic
- Ready to rename and extend

## Quick Start

```swift
import NISDK

let configuration = NISDKConfiguration(
    apiKey: "replace-me",
    environment: .sandbox
)

let sdk = NISDK(configuration: configuration)
print(sdk.statusMessage())
print(sdk.defaultHeaders())
```

## What To Replace

- Package and pod names
- Placeholder repository metadata
- Default base URLs in `NISDKConfiguration`
- Public API surface in `NISDK.swift`

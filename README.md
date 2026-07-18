# OllamaKit

Swift package for [Ollama](https://ollama.com) in **local** or **cloud** mode.

Reusable across macOS / iOS apps via Swift Package Manager.

## Install

In Xcode: **File → Add Package Dependencies…** and use:

```text
https://github.com/pierostud/OllamaKit.git
```

Or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/pierostud/OllamaKit.git", from: "1.0.0")
]
```

## Features

- Local server (`http://127.0.0.1:11434`) or Ollama Cloud (`https://ollama.com`)
- Bearer auth for cloud API keys (Keychain in Release, UserDefaults in Debug)
- Chat client (`/api/chat`)
- Model management for local: list / load / unload / pull
- Cloud model access filtering (plan-aware) + account plan lookup
- Ready-made `OllamaSettingsView` with searchable cloud model picker

## Usage

```swift
import OllamaKit

let settings = OllamaSettings(
    defaultsKeyPrefix: "myapp.ollama",
    keychainService: "eu.example.MyApp.ollama-cloud-api-key"
)

// Settings UI
OllamaSettingsView(settings: settings)

// Chat
let client = OllamaClient(connectionConfig: settings.connectionConfig)
let reply = try await client.chat(
    model: settings.model,
    system: "You are a helpful assistant.",
    user: "Hello"
)
```

## Requirements

- macOS 14+ / iOS 17+
- Swift 6

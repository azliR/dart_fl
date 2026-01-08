# fl 🚀

A lightweight companion for `flutter run` that makes your life easier with auto hot-reload, `dart:developer` logs in your terminal, and smart device management that remembers your favorites.

## ✨ Features

### 🔥 Auto Reload & Logging
- Watches `lib/` and hot reloads automatically when you save
- Shows `dart:developer` logs right in your terminal
- All `flutter run` options work — just pass them through!
- Same `r`, `R`, `q` shortcuts you're used to

### 📱 Smart Device Management
- **Project-aware ranking** — Devices you use in this project show up first
- **Your favorites first** — Most used devices bubble to the top globally too
- **Remembers everything** — Devices stick around across refreshes
- **Self-cleaning** — Unused devices auto-remove after 30 days
- **Smart filtering** — Only shows devices matching your project

## 📦 Installation

```sh
# Clone it
git clone https://github.com/azliR/dart_fl.git

# Install it
dart pub global activate --source path .
```

> 💡 Make sure `$HOME/.pub-cache/bin` is in your `PATH`!

## 🎮 Usage

### Running Your App

```sh
# Just run it — pick a device
fl run

# Skip the picker, grab the first one
fl run -y

# Specify a device directly
fl run -d iPhone

# With flavor and target
fl run --flavor staging --target lib/main_dev.dart

# Only iOS devices please
fl run --platform ios
```

### 🎯 Device Selection

When picking a device:
- **1-9** — Select by number
- **Enter** — Grab the first one
- **r** — Refresh the list
- **q** — Quit

### 🔧 Device Management

```sh
fl device list      # See what's cached
fl device refresh   # Update the list
fl device rm <id>   # Remove one
```

### 📋 Other Goodies

```sh
fl pub sort         # Alphabetize your pubspec deps
fl flutter doctor   # Pass commands to Flutter
```

### ⚙️ Run Options

| Option | What it does |
|--------|--------------|
| `-d <id>` | Pick a device |
| `-y` | Auto-select first device |
| `--platform <name>` | Filter by platform |
| `--force-device-refresh` | Force a fresh list |

## ⌨️ Keyboard Shortcuts

| Key | Action |
|-----|--------|
| `r` | Hot reload |
| `R` | Hot restart |
| `q` | Quit |
| `h` | Help |

## 🔧 Troubleshooting

- **Flutter not found?** Make sure it's in your `PATH`
- **Missing a device?** Run `fl device refresh` or press `r` during selection
- **Only watches `lib/`** — Use symlinks for code elsewhere, or just press `r`

---

Made with ☕ by [@azliR](https://github.com/azliR)

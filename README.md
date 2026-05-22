<div align="center">

<img src="docs/logo.svg" alt="Terraform Graph Online" width="140" />

# Terraform Graph Online

**Realtime visualization for `terraform graph` with live execution status overlay.**

[![Python](https://img.shields.io/badge/Python-3.10%2B-3776AB?logo=python&logoColor=white)](https://www.python.org/)
[![FastAPI](https://img.shields.io/badge/FastAPI-0.110%2B-009688?logo=fastapi&logoColor=white)](https://fastapi.tiangolo.com/)
[![D3.js](https://img.shields.io/badge/D3.js-7-F9A03C?logo=d3.js&logoColor=white)](https://d3js.org/)
[![Terraform](https://img.shields.io/badge/Terraform-1.x-7B42BC?logo=terraform&logoColor=white)](https://www.terraform.io/)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](#-contributing)
[![AI Generated](https://img.shields.io/badge/100%25-AI%20generated-FF6F61?logo=openai&logoColor=white)](#-ai-generated-notice)

[English](README.md) · [简体中文](README_CN.md)

<img src="docs/banner.svg" alt="Terraform Graph Online Banner" width="100%" />

</div>

---

## ✨ Overview

**Terraform Graph Online** is a lightweight, self-hosted system that renders a Terraform project's dependency graph in the browser and overlays the **live execution state** of every resource as `terraform plan` / `apply` runs.

It consists of two parts:

| Component | Role |
| --- | --- |
| 🖥️ **Server** | FastAPI + WebSocket + static SPA. Stores DOT graphs and logs in SQLite, pushes state changes to browsers. |
| 🤖 **Agent** | A small Python CLI installed on the Terraform runner. Executes `terraform graph`, wraps `terraform` commands, and streams stdout/stderr back to the server. |

Everything runs as plain Python — no Docker, no message broker, no cloud account required.

## 🎯 Why?

Terraform's CLI output is linear, but infrastructure is a **graph**. When dozens of resources are being provisioned in parallel, plain text logs make it hard to answer:

- *Which resource is currently being created?*
- *Did this module finish before that one started?*
- *Where exactly did `apply` fail in the dependency tree?*

This project answers those questions visually and **without requiring `plan`/`apply` permissions on the server side** — only `terraform graph` is mandatory.

## 🌟 Features

- 🌐 **Web-based visualization** — interactive DAG rendered with D3 + dagre-d3.
- 🔴🟢🟡 **Live status overlay** — resources are colored as `queued` / `running` / `complete` / `failed`, updated in real time.
- 🧩 **Multi-session** — manage multiple Terraform projects/environments side-by-side.
- 🪶 **Zero infra** — single FastAPI process + SQLite file. Static frontend served from the same port.
- 🛡️ **Read-only friendly** — works in environments where the runner can only execute `terraform graph` and read logs.
- 💻 **Cross-platform agent** — Linux/macOS shell + Windows PowerShell wrappers shipped out of the box.
- 🔌 **Multiple ingestion modes** — wrap a command (`watch`), tail an existing log (`tail`), upload a finished log (`upload-log`), or mirror a whole shell session (`shell`).

## 🏗️ Architecture

```
┌────────────────────────────┐         HTTP / WebSocket          ┌────────────────────────────┐
│   Terraform runner host    │ ───────────────────────────────►  │      Server (FastAPI)      │
│                            │  POST /api/sessions/{sid}/graph   │                            │
│  ┌──────────────────────┐  │  POST /api/sessions/{sid}/logs    │  ┌──────────────────────┐  │
│  │  tfgraph-agent       │  │                                   │  │  parser  (DOT)       │  │
│  │  • graph (DOT)       │  │ ◄─────────────────────────────────┤  │  store   (SQLite)    │  │
│  │  • watch / tail      │  │           WebSocket push          │  │  hub     (WS fanout) │  │
│  │  • upload-log        │  │                                   │  └──────────┬───────────┘  │
│  └──────────────────────┘  │                                   │             │              │
└────────────────────────────┘                                   │             ▼              │
                                                                 │  ┌──────────────────────┐  │
                                                                 │  │  Static SPA          │  │
                                                                 │  │  D3 + dagre-d3       │  │
                                                                 │  └──────────────────────┘  │
                                                                 └────────────────────────────┘
```

- **Graph source**: `terraform graph` (DOT) is parsed once per session.
- **State source**: regex matching on console output (`Creating...`, `Creation complete`, `Modifying...`, `Destroying...`, `Apply complete!`, …).
- **Transport**: Agent → Server via HTTP; Server → Browser via WebSocket.

## 📁 Project Structure

```
terraform-graph/
├── server/                     # Online system (FastAPI + static SPA)
│   ├── app.py                  # API + WebSocket entrypoint
│   ├── parser.py               # DOT parser
│   ├── store.py                # SQLite storage layer
│   ├── requirements.txt
│   └── static/                 # Frontend (HTML + CSS + JS)
│       ├── index.html
│       ├── style.css
│       └── app.js
├── agent/                      # Runner-side agent
│   ├── tfgraph_agent.py        # Main CLI
│   ├── tfgraph-agent.sh        # POSIX wrapper
│   ├── tfgraph-agent.ps1       # Windows PowerShell wrapper
│   ├── install.sh              # One-shot installer (Linux/macOS)
│   ├── install.ps1             # One-shot installer (Windows)
│   └── requirements.txt
├── docs/                       # Logos & images
└── README.md
```

## 📦 Download

Pre-built **single-file binaries** are published to [Releases](https://github.com/corningma/terraform-graph/releases/latest) — no Python required on target machines.

| Platform | Server | Agent |
|---|---|---|
| Linux x86_64 | `tfgraph-server-linux-amd64` | `tfgraph-agent-linux-amd64` |
| macOS Intel | `tfgraph-server-darwin-amd64` | `tfgraph-agent-darwin-amd64` |
| macOS Apple Silicon | `tfgraph-server-darwin-arm64` | `tfgraph-agent-darwin-arm64` |
| Windows x64 | `tfgraph-server-windows-amd64.exe` | `tfgraph-agent-windows-amd64.exe` |

```bash
# Server
curl -fsSL -o tfgraph-server \
  https://github.com/corningma/terraform-graph/releases/latest/download/tfgraph-server-linux-amd64
chmod +x tfgraph-server && ./tfgraph-server

# Agent
curl -fsSL -o tfgraph-agent \
  https://github.com/corningma/terraform-graph/releases/latest/download/tfgraph-agent-linux-amd64
chmod +x tfgraph-agent
TFGRAPH_SERVER=http://<server-ip>:8000 ./tfgraph-agent ping
```

> Prefer running from source? Read on for the developer flow ↓

## 🚀 Quick Start

### 1. Start the server

```bash
cd server
pip install -r requirements.txt
python app.py
# → listens on http://0.0.0.0:8000
```

Open `http://<server-ip>:8000` in a browser.

### 2. Install the agent on the Terraform runner

**Linux / macOS**

```bash
curl -O http://<server-ip>:8000/install.sh
bash install.sh http://<server-ip>:8000
```

**Windows (PowerShell)**

```powershell
Invoke-WebRequest http://<server-ip>:8000/install.ps1 -OutFile install.ps1
.\install.ps1 -Server http://<server-ip>:8000
```

Or install manually:

```bash
cd agent
pip install -r requirements.txt
export TFGRAPH_SERVER=http://<server-ip>:8000
```

### 3. Use the agent

```bash
# Connectivity check
tfgraph-agent ping

# In your Terraform project directory: create a session and upload the graph
cd /path/to/your/tf-project
tfgraph-agent graph --name "prod-network"

# Wrap a Terraform command and stream stdout/stderr in real time
tfgraph-agent watch -- terraform plan
tfgraph-agent watch -- terraform apply

# No plan/apply permission? Tail an existing log file instead
tfgraph-agent tail /path/to/terraform.log

# Or upload a complete log file in one shot
tfgraph-agent upload-log /path/to/terraform.log
```

## 🧠 Design Highlights

- **Only depends on `terraform graph`** — the full dependency graph comes from DOT, no `plan`/`apply` privilege needed.
- **State derived from logs** — resource status is inferred by matching keywords like `Creating...`, `Creation complete`, `Modifying...`, `Destroying...`, `Apply complete!` in console output.
- **Realtime by default** — Agent posts incremental log lines via HTTP; Server fans them out to browsers over WebSocket.
- **Lightweight stack** — FastAPI + SQLite on the backend; pure static frontend (D3 + dagre-d3 from CDN).
- **Multi-tenant friendly** — session-keyed storage means many runners and many projects can share one server.

## 🛠️ CLI Reference

| Command | Purpose |
| --- | --- |
| `tfgraph-agent ping` | Verify connectivity to the server |
| `tfgraph-agent init --name <n>` | Register/update a session without uploading the graph |
| `tfgraph-agent graph --name <n>` | Run `terraform graph` and upload the DOT |
| `tfgraph-agent shell` | Mirror an entire sub-shell session to the server |
| `tfgraph-agent watch -- <cmd...>` | Wrap a command and stream its output |
| `tfgraph-agent tail <log>` | Tail an existing log file and upload new lines |
| `tfgraph-agent upload-log <log>` | Upload a complete log file in one shot |

### Environment variables

| Variable | Description |
| --- | --- |
| `TFGRAPH_SERVER` | Server URL, e.g. `http://10.0.0.1:8000` |
| `TFGRAPH_SESSION` | Explicit session ID (otherwise derived from `--name`) |
| `TFGRAPH_NAME` | Default session name (defaults to current directory basename) |

## 🤖 AI-Generated Notice

> **This project was generated 100% by an AI coding assistant.**
>
> Every file in this repository — Python source code, FastAPI server, agent CLI,
> POSIX/PowerShell wrappers, frontend HTML/CSS/JS, SVG logo & banner, and this
> README — was authored by an AI based on natural-language requirements from the
> project owner. **No part of the codebase was hand-written by a human developer.**
>
> The code is released under the MIT License and provided **"AS IS"**, without
> warranty of any kind. You are strongly encouraged to **review, test, and audit**
> the code before deploying it to production or security-sensitive environments.

## 🤝 Contributing

Issues and PRs are welcome! If you spot a bug, want to add a status keyword for another locale, or have ideas for the UI — please open an issue first to discuss.

## 📄 License

Released under the [MIT License](LICENSE).

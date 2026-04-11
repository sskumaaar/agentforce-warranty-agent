# Electra Cars — Warranty Claim Agent

> **Agentforce World Tour Mumbai Hackathon 2026 — Automotive Cloud Challenge**

## The Problem

Electra Cars is an EV OEM with 300,000+ vehicles on the road. Their dealer network sends **1,000+ warranty claim requests daily** via email. Only 3 claim approvers handle this volume manually — opening emails, checking attachments, verifying warranty coverage. The result: massive bottlenecks, delayed repairs, and frustrated dealers.

## Our Solution

An **AI-powered Warranty Claim Agent** built on Salesforce Agentforce that replaces the manual email-to-approval pipeline with an intelligent, multi-channel digital experience.

### What It Does

| Capability | How |
|------------|-----|
| **Conversational Claim Intake** | Dealers submit claims via Web Chat or WhatsApp — the Agentforce Service Agent guides them through VIN lookup, warranty validation, and part selection conversationally |
| **Instant Triage & Scoring** | Claims are automatically scored for risk and severity using Apex-based rules engine, routing high-priority cases for immediate review |
| **Real-Time Approver Notifications** | The moment a claim is submitted, approvers receive Slack alerts with claim summary, risk score, and recommended action |
| **Slack-Based Approval Workflow** | Approvers review, ask follow-up questions, and approve/reject claims directly within Slack via an Agentforce Employee Agent |
| **Warranty Intelligence** | Automatic VIN-to-warranty chain validation ensures only covered parts are approved, reducing fraudulent claims |

### Architecture

```
Dealer (Web Chat / WhatsApp)
        │
        ▼
  Agentforce Service Agent ──► Automotive Cloud (Vehicle, Claim, AssetWarranty)
        │                              │
        ▼                              ▼
  Auto-Triage Flow ──────────► Risk Score + Severity Assignment
        │
        ▼
  Platform Event ──► Slack Notification ──► Employee Agent (Approve/Reject)
        │
        ▼
  Claim Status Updated ──► Dealer Notified
```

## Tech Stack

| Product / Feature | Usage |
|-------------------|-------|
| **Automotive Cloud** | Vehicle, Claim, AssetWarranty, WarrantyTerm, ClaimItem, ClaimCoverage |
| **Agentforce** | Service Agent (dealer-facing) + Employee Agent (approver-facing) |
| **Agent Builder** | Custom topics, actions, and prompt templates |
| **Apex** | Triage engine, risk scoring, invocable actions |
| **Flow** | Record-triggered automation, screen flows, platform event handlers |
| **Experience Cloud** | Dealer portal with embedded web chat |
| **Slack Integration** | Approval notifications, conversational agent in Slack |
| **Digital Engagement** | Web Chat channel for external agent |
| **Data Cloud** | Customer insights and prompt grounding |
| **LWC** | Claim dashboard, real-time status components |
| **Platform Events** | Real-time claim submission notifications |

## Project Structure

```
force-app/
└── main/
    └── default/
        ├── classes/          → WC_* Apex classes (triage engine, invocable actions, tests)
        ├── lwc/              → wc* Lightning Web Components (dashboards, status views)
        ├── flows/            → WC_* Flows (auto-triage, Slack notifications, scoring)
        ├── objects/          → Custom fields on Claim, Vehicle, AssetWarranty
        ├── customMetadata/   → WC_Config__mdt (configuration records)
        ├── permissionsets/   → Agent and approver permission sets
        ├── triggers/         → WC_* triggers
        ├── layouts/          → Custom layouts for Claim, Vehicle
        ├── flexipages/       → Lightning pages
        ├── tabs/             → Custom tabs
        └── quickActions/     → Quick actions for claim processing
```

## Naming Convention

| Type | Pattern | Example |
|------|---------|---------|
| Apex | `WC_` + PascalCase | `WC_ClaimTriageService` |
| LWC | `wc` + camelCase | `wcClaimDashboard` |
| Flow | `WC_` + Snake_Case | `WC_Auto_Triage_On_Submit` |
| Custom Fields | Descriptive `__c` | `Risk_Score__c` |
| Custom Metadata | `WC_Config__mdt` | `WC_Config.Slack_Channel` |

## Team

| Member | Focus Area |
|--------|------------|
| **Santosh** | Agentforce agents, architecture, prompt templates |
| **Piyush** | Apex classes, triage engine, test coverage |
| **Pooja** | Flows, Slack integration, digital engagement |
| **Sonal** | Custom objects, LWC components, reports & dashboards |

## Setup

1. Clone this repository
2. Authenticate with the hackathon org: `sf org login web --alias hackathon`
3. Deploy: `sf project deploy start --source-dir force-app --target-org hackathon`

## License

This project was created for the Agentforce World Tour Mumbai Hackathon 2026.

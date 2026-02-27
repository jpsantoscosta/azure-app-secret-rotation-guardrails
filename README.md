# Designing Safe Azure App Registration Secret Rotation (With Guardrails)

This repository contains a production-ready Azure Function implementation for safe and deterministic Azure App Registration secret rotation using:

- Azure Functions (PowerShell 7)
- Managed Identity
- Microsoft Graph PowerShell
- Azure Key Vault

The objective is not simply to automate rotation.

The objective is to rotate safely.

---

## Why This Exists

In many Azure environments:

- Client secrets are stored in Azure Key Vault  
- Expiry alerts are configured  
- Rotation is handled manually  

Monitoring works.

But alert-driven rotation can introduce timing risks, inconsistent execution, and accidental outages.

This implementation uses a **guardrail-driven approach**, where rotation only happens when clearly required — based on deterministic validation logic.

---

## How It Works

1. Azure Function authenticates using Managed Identity  
2. Reads the active `keyId` from Key Vault tags  
3. Retrieves application credentials from Microsoft Graph  
4. Validates expiration against a rotation threshold  
5. Applies a 2-day buffer to avoid boundary instability  
6. Rotates only when required  
7. Writes the new secret value back to Key Vault with metadata  

If the current secret is still valid beyond the defined threshold, the function exits safely (no-op).

---

## Guardrails Implemented

- Rotation only occurs when necessary  
- Key Vault is treated as the source of truth  
- Active secret is validated against Microsoft Graph  
- Structured JSON logging for traceability  
- Explicit failure handling  
- No blind credential deletion  

---

## Required Permissions

### Microsoft Graph (Application Permission)

Admin consent required.

---

### Azure RBAC

The Function Managed Identity requires:

Key Vault Secrets Officer

On the target Key Vault.

---

## Required App Settings
TARGET_APPID

KEYVAULT_NAME

KV_SECRET_NAME

ROTATE_DAYS_BEFORE = 30

NEW_SECRET_LIFETIME_DAYS = 180

AUTOMATION_PREFIX = auto-rotated

MANAGED_BY = func-sec-rotator

EXPIRY_GRACE_HOURS = 96

MIN_EXPIRED_DAYS = 3


---

## Buffer Strategy (Why 2 Days?)

A 2-day buffer is intentionally included to prevent edge-condition instability caused by:

- Timezone differences  
- Execution timing  
- Clock drift  
- Boundary evaluation inconsistencies  

Without a buffer, scheduled executions near the threshold could cause unnecessary or repeated rotations.

The buffer ensures stability and predictability.

---

## Cleanup Logic

A safe cleanup function (expired credential removal with additional guardrails) will be published separately.

---

## Disclaimer

This implementation assumes governance control over the target App Registration.

Always validate in a non-production environment before deploying to production.

---

## Author

João Paulo Costa  
Microsoft MVP | Azure Core Infrastructure

# 1Password Vault Structure Guide

## 🏗️ Recommended Vault Organization

This guide shows how to organize your 1Password vaults for optimal .env generation.

**Created:** $(date)

---

## 📁 Vault Structure Overview

```
1Password Account
│
├── 🔵 Personal (Your personal stuff)
│   ├── Netflix
│   ├── Amazon
│   └── Banking...
│
├── 🟡 Development (Dev/test credentials)
│   ├── DEV - n8n
│   ├── DEV - PostgreSQL
│   ├── DEV - OpenAI (test keys)
│   └── DEV - Twilio (test account)
│
├── 🔴 Production (LIVE production secrets)
│   ├── PROD - n8n
│   ├── PROD - PostgreSQL
│   ├── PROD - OpenAI
│   ├── PROD - Grok
│   ├── PROD - Anthropic
│   ├── PROD - Twilio
│   └── PROD - Hetzner
│
└── 🟢 Infrastructure (Server access)
    ├── Hetzner VPS Root
    ├── GitHub Deploy Keys
    └── Service Account Tokens
```

---

## 🎯 Production Vault - Detailed Example

### Item: PROD - n8n

```
Title: PROD - n8n
Category: Login

Fields:
  ┌─────────────────────────────────────┐
  │ Label: Encryption_Key               │
  │ Type: Password                      │
  │ Value: abc123def456ghi789...        │
  └─────────────────────────────────────┘
  
  ┌─────────────────────────────────────┐
  │ Label: Admin_Password               │
  │ Type: Password                      │
  │ Value: secure_admin_pass_xyz        │
  └─────────────────────────────────────┘
  
  ┌─────────────────────────────────────┐
  │ Label: URL                          │
  │ Type: URL                           │
  │ Value: https://n8n.yourdomain.com   │
  └─────────────────────────────────────┘

Notes:
  n8n automation platform admin credentials
  URL: https://n8n.yourdomain.com
  Rotation: Quarterly (next: 2025-01-01)
  Used by: Main VPS container

Tags: production, n8n, automation
```

**Result in .env:**
```bash
PROD_N8N_ENCRYPTION_KEY=abc123def456ghi789...
PROD_N8N_ADMIN_PASSWORD=secure_admin_pass_xyz
PROD_N8N_URL=https://n8n.yourdomain.com
```

---

### Item: PROD - PostgreSQL

```
Title: PROD - PostgreSQL
Category: Database

Fields:
  ┌─────────────────────────────────────┐
  │ Label: Username                     │
  │ Type: Text                          │
  │ Value: postgres                     │
  └─────────────────────────────────────┘
  
  ┌─────────────────────────────────────┐
  │ Label: Password                     │
  │ Type: Password                      │
  │ Value: db_secure_password_123       │
  └─────────────────────────────────────┘
  
  ┌─────────────────────────────────────┐
  │ Label: Database                     │
  │ Type: Text                          │
  │ Value: n8n_production               │
  └─────────────────────────────────────┘
  
  ┌─────────────────────────────────────┐
  │ Label: Host                         │
  │ Type: Text                          │
  │ Value: postgres                     │
  └─────────────────────────────────────┘
  
  ┌─────────────────────────────────────┐
  │ Label: Port                         │
  │ Type: Text                          │
  │ Value: 5432                         │
  └─────────────────────────────────────┘

Notes:
  PostgreSQL database for n8n production
  Container name: postgres
  Volume: /opt/postgres-data
  Rotation: Every 180 days

Tags: production, database, postgresql
```

**Result in .env:**
```bash
PROD_POSTGRESQL_USERNAME=postgres
PROD_POSTGRESQL_PASSWORD=db_secure_password_123
PROD_POSTGRESQL_DATABASE=n8n_production
PROD_POSTGRESQL_HOST=postgres
PROD_POSTGRESQL_PORT=5432
```

---

### Item: PROD - OpenAI

```
Title: PROD - OpenAI
Category: API Credential

Fields:
  ┌─────────────────────────────────────┐
  │ Label: API_Key                      │
  │ Type: Password                      │
  │ Value: sk-proj-abc123xyz789...      │
  └─────────────────────────────────────┘
  
  ┌─────────────────────────────────────┐
  │ Label: Organization_ID              │
  │ Type: Text                          │
  │ Value: org-xyz123                   │
  └─────────────────────────────────────┘
  
  ┌─────────────────────────────────────┐
  │ Label: Model                        │
  │ Type: Text                          │
  │ Value: gpt-4o-mini                  │
  └─────────────────────────────────────┘

Notes:
  OpenAI API key for production LLM calls
  Dashboard: https://platform.openai.com
  Monthly limit: $50
  Current usage: Check dashboard
  Created: 2025-10-01
  Rotation: Quarterly (next: 2026-01-01)

Tags: production, api, llm, openai
```

**Result in .env:**
```bash
PROD_OPENAI_API_KEY=sk-proj-abc123xyz789...
PROD_OPENAI_ORGANIZATION_ID=org-xyz123
PROD_OPENAI_MODEL=gpt-4o-mini
```

---

### Item: PROD - Twilio

```
Title: PROD - Twilio
Category: API Credential

Fields:
  ┌─────────────────────────────────────┐
  │ Label: Account_SID                  │
  │ Type: Text                          │
  │ Value: AC123456789abcdef...         │
  └─────────────────────────────────────┘
  
  ┌─────────────────────────────────────┐
  │ Label: Auth_Token                   │
  │ Type: Password                      │
  │ Value: xyz789abc123def456...        │
  └─────────────────────────────────────┘
  
  ┌─────────────────────────────────────┐
  │ Label: Phone_Number                 │
  │ Type: Text                          │
  │ Value: +15551234567                 │
  └─────────────────────────────────────┘
  
  ┌─────────────────────────────────────┐
  │ Label: Messaging_Service_SID        │
  │ Type: Text                          │
  │ Value: MG123456...                  │
  └─────────────────────────────────────┘

Notes:
  Twilio SMS/Voice API credentials
  Dashboard: https://console.twilio.com
  Phone number: +1-555-123-4567
  Monthly budget: $20
  Webhook URL: https://your-domain.com/webhook/twilio

Tags: production, api, sms, twilio
```

**Result in .env:**
```bash
PROD_TWILIO_ACCOUNT_SID=AC123456789abcdef...
PROD_TWILIO_AUTH_TOKEN=xyz789abc123def456...
PROD_TWILIO_PHONE_NUMBER=+15551234567
PROD_TWILIO_MESSAGING_SERVICE_SID=MG123456...
```

---

## 🎨 Naming Convention Rules

### Item Titles

**Format:** `[ENV] - [Service Name]`

**Examples:**
- ✅ `PROD - OpenAI`
- ✅ `DEV - PostgreSQL`
- ✅ `STAGING - Stripe`
- ❌ `Production OpenAI` (no hyphen separator)
- ❌ `openai-prod` (lowercase, wrong format)

**Environment Prefixes:**
- `PROD` - Production/live environment
- `DEV` - Development/testing
- `STAGING` - Staging environment
- `LOCAL` - Local development only

### Field Labels

**Format:** Use underscores for multi-word labels

**Examples:**
- ✅ `API_Key`
- ✅ `Auth_Token`
- ✅ `Account_SID`
- ✅ `Webhook_Secret`
- ❌ `API Key` (spaces work but underscores are cleaner)
- ❌ `api-key` (hyphens become underscores anyway)
- ❌ `apiKey` (camelCase becomes APIKEY)

**Common Field Labels:**
- `API_Key` → `PROD_SERVICE_API_KEY`
- `Username` → `PROD_SERVICE_USERNAME`
- `Password` → `PROD_SERVICE_PASSWORD`
- `Auth_Token` → `PROD_SERVICE_AUTH_TOKEN`
- `Secret_Key` → `PROD_SERVICE_SECRET_KEY`
- `Webhook_Secret` → `PROD_SERVICE_WEBHOOK_SECRET`
- `Database` → `PROD_SERVICE_DATABASE`
- `Host` → `PROD_SERVICE_HOST`
- `Port` → `PROD_SERVICE_PORT`

---

## 📋 Complete Production Vault Checklist

### Core Infrastructure
```
□ PROD - n8n
  □ Encryption_Key
  □ Admin_Password
  □ URL

□ PROD - PostgreSQL
  □ Username
  □ Password
  □ Database
  □ Host
  □ Port

□ PROD - Redis (if using)
  □ Password
  □ Host
  □ Port
```

### LLM Services
```
□ PROD - OpenAI
  □ API_Key
  □ Organization_ID (optional)
  □ Model

□ PROD - Anthropic
  □ API_Key

□ PROD - Grok
  □ API_Key
```

### Communication Services
```
□ PROD - Twilio
  □ Account_SID
  □ Auth_Token
  □ Phone_Number
  □ Messaging_Service_SID (if using)

□ PROD - SendGrid (if using email)
  □ API_Key
  □ From_Email
```

### External Services
```
□ PROD - Stripe (if monetizing)
  □ Publishable_Key
  □ Secret_Key
  □ Webhook_Secret

□ PROD - GitHub
  □ Personal_Access_Token
  □ Deploy_Key

□ PROD - Cloudflare (if using)
  □ API_Token
  □ Zone_ID
```

---

## 🔄 Migration Guide

### Moving from Hardcoded to Dynamic

**Before (hardcoded in script):**
```bash
N8N_ENCRYPTION_KEY=$(op item get "PROD - n8n" --fields label=Encryption_Key)
OPENAI_API_KEY=$(op item get "PROD - OpenAI" --fields label=API_Key)
# ...10 more hardcoded lines
```

**After (dynamic):**
```bash
# Just run once - pulls ALL items automatically
/opt/scripts/regenerate-env-dynamic.sh Production
```

**Steps:**
1. Ensure all items follow naming convention: `PROD - ServiceName`
2. Ensure all fields use underscore labels: `API_Key` not `API Key`
3. Run dynamic script: `regen-env`
4. Compare output with old .env
5. Fix any naming mismatches in 1Password
6. Re-run: `regen-env`
7. Test thoroughly before deleting old script

---

## 💡 Advanced Tips

### Using Tags for Organization

Add tags to items for easy filtering:
- `production` - All prod credentials
- `api` - All API keys
- `database` - All database credentials
- `rotate-quarterly` - Items needing regular rotation
- `high-security` - Critical credentials

### Using Categories

1Password categories help organize:
- **API Credential** - For API keys
- **Database** - For database credentials
- **Login** - For service logins
- **Server** - For SSH keys, VPS access
- **Secure Note** - For other secrets

### Custom Sections

Add sections to group related fields:

```
PROD - n8n
├── Core
│   ├── Encryption_Key
│   └── Admin_Password
├── SMTP (if configured)
│   ├── SMTP_Host
│   ├── SMTP_Port
│   ├── SMTP_User
│   └── SMTP_Pass
└── Webhook
    └── Webhook_URL
```

### Using Folders (1Password Teams)

If you have 1Password Teams, use folders:

```
Production Vault
├── Core Services/
│   ├── PROD - n8n
│   └── PROD - PostgreSQL
├── API Keys/
│   ├── PROD - OpenAI
│   ├── PROD - Anthropic
│   └── PROD - Grok
└── External Services/
    ├── PROD - Twilio
    └── PROD - Stripe
```

---

## 🎓 Example: Adding a New Service

Let's say you want to add Stripe payments:

### Step 1: Create Item in 1Password

```
Title: PROD - Stripe
Category: API Credential

Fields:
  Publishable_Key: pk_live_xyz123...
  Secret_Key: sk_live_abc789...
  Webhook_Secret: whsec_def456...

Notes:
  Stripe payment processing
  Dashboard: https://dashboard.stripe.com
  Test mode keys in DEV - Stripe
  Webhook endpoint: /webhook/stripe

Tags: production, api, payments, stripe
```

### Step 2: Regenerate .env

```bash
ssh root@your-vps
regen-env
# Press 'y' to restart
```

### Step 3: Variables Automatically Available

```bash
# In your .env file:
PROD_STRIPE_PUBLISHABLE_KEY=pk_live_xyz123...
PROD_STRIPE_SECRET_KEY=sk_live_abc789...
PROD_STRIPE_WEBHOOK_SECRET=whsec_def456...

# Use in n8n workflows immediately!
```

**No script changes needed! 🎉**

---

## 📚 Field Label Reference

Common labels and their ENV variable results:

| 1Password Label | ENV Variable | Common Use |
|----------------|--------------|------------|
| `API_Key` | `SERVICE_API_KEY` | API authentication |
| `Auth_Token` | `SERVICE_AUTH_TOKEN` | OAuth tokens |
| `Secret_Key` | `SERVICE_SECRET_KEY` | Signing/encryption |
| `Webhook_Secret` | `SERVICE_WEBHOOK_SECRET` | Webhook validation |
| `Account_SID` | `SERVICE_ACCOUNT_SID` | Twilio account ID |
| `Organization_ID` | `SERVICE_ORGANIZATION_ID` | OpenAI org ID |
| `Username` | `SERVICE_USERNAME` | Database/service user |
| `Password` | `SERVICE_PASSWORD` | Authentication |
| `Database` | `SERVICE_DATABASE` | Database name |
| `Host` | `SERVICE_HOST` | Server hostname |
| `Port` | `SERVICE_PORT` | Server port |
| `URL` | `SERVICE_URL` | Service endpoint |
| `Encryption_Key` | `SERVICE_ENCRYPTION_KEY` | Data encryption |
| `Phone_Number` | `SERVICE_PHONE_NUMBER` | Twilio number |
| `From_Email` | `SERVICE_FROM_EMAIL` | Email sending |

---

## ✅ Quality Checklist

Before running the script, verify:

- [ ] All item titles follow format: `[ENV] - [Service]`
- [ ] All field labels use underscores (not spaces or hyphens)
- [ ] No duplicate field labels within same item
- [ ] Sensitive values in Password-type fields (not Text)
- [ ] Notes document what each credential is for
- [ ] Tags added for organization
- [ ] Service account has READ access to vault
- [ ] Items in correct vault (Production vs Development)

---

**Questions? Issues? Check the main README or regenerate to see detailed output!**

**Last Updated:** $(date)

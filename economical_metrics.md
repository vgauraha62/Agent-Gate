# 💰 AgentGate Business Model & API Service Strategy

## Executive Summary

You provide **two complementary services** that work together: a **hosted API** (pay-per-request) for developers who want zero setup, and a **self-hosted Cage** (subscription) for enterprises who need air-gapped security. This creates multiple revenue streams with different price points.


## 🎯 What You Provide in Your API Service

### Service 1: Hosted Policy API (SaaS)

**What it is:** A cloud endpoint that developers call to check if an operation is allowed.

```bash
curl -X POST https://api.agentgate.io/v1/check \
  -H "Authorization: Bearer YOUR_API_KEY" \
  -d '{"tool": "bash", "command": "cat .env", "agent_id": "claude"}'

# Response
{"decision": "DENY", "policy_id": "block-secrets", "reason": ".env files contain credentials"}
```

**What users get:**
- No installation required
- Always updated policies
- Centralized audit logs
- Works with any tool (curl, Python, Node.js)

**What you provide:**
- API endpoint (global, low-latency)
- API key management
- Policy storage and evaluation
- Audit log storage
- Billing and rate limiting

### Service 2: AgentGate Cage (Self-Hosted)

**What it is:** The complete proxy + sandbox that runs on the user's machine (what we just architected).

```bash
curl -fsSL https://agentgate.io/install.sh | bash
agentgate start
```

**What users get:**
- Zero latency (no cloud roundtrip)
- Complete isolation (their secrets never leave)
- Works offline
- Full audit trail

**What you provide:**
- Software distribution (Docker images, binary releases)
- Documentation and support
- Updates and security patches


## 💵 Revenue Model: Freemium + Tiered Pricing

### Tier 1: Free Tier (Acquisition)

| Quota | Limit | Purpose |
|-------|-------|---------|
| API requests | 1,000/month | Let developers try it |
| AgentGate Cage | Unlimited (open source) | Builds ecosystem |
| Audit retention | 7 days | Basic visibility |

**Goal:** Get developers using AgentGate. Make it viral through open source.

### Tier 2: Pro Tier ($29/month or $290/year)

| Feature | Included |
|---------|----------|
| API requests | 100,000/month |
| Audit retention | 90 days |
| Policy templates | SOC2, HIPAA, PCI ready |
| Support | Email within 24 hours |
| Teams | Up to 5 users |

**Target:** Small teams, startups, solo developers with revenue.

### Tier 3: Business Tier ($299/month)

| Feature | Included |
|---------|----------|
| API requests | 1,000,000/month |
| Audit retention | 1 year |
| SSO (Google, Okta) | Included |
| Policy export/import | Included |
| Support | Slack channel, 4-hour response |
| Teams | Unlimited users |

**Target:** Mid-market companies, compliance-heavy teams.

### Tier 4: Enterprise Tier (Custom pricing, $2,000+/month)

| Feature | Included |
|---------|----------|
| API requests | Custom (10M+) |
| Audit retention | Custom (up to 7 years) |
| Self-hosted Cage | Full deployment support |
| Air-gapped support | Yes |
| SLA | 99.9% uptime guarantee |
| Support | Dedicated Slack, 1-hour response |
| SOC2 Type II report | Included |
| On-premise deployment | Yes |

**Target:** Fortune 500, financial services, healthcare, government.


## 📊 Revenue Stack: What You Charge For

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    AGENTGATE REVENUE STACK                                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  Layer 1: API Requests (Metered)                                           │
│  ├── First 1,000: FREE                                                    │
│  ├── 1,001 - 100,000: $0.0003 per request ($29/month)                     │
│  ├── 100,001 - 1,000,000: $0.00025 per request ($249/month)               │
│  └── 1,000,000+: Custom pricing                                            │
│                                                                              │
│  Layer 2: AgentGate Cage (Software License)                                │
│  ├── Open Source core: FREE (Apache 2.0)                                  │
│  ├── Enterprise features: Subscription ($2,000+/month)                    │
│  └── Air-gapped deployment: Custom pricing                                 │
│                                                                              │
│  Layer 3: Audit Storage                                                     │
│  ├── 7 days: FREE                                                          │
│  ├── 90 days: Included in Pro                                              │
│  ├── 1 year: Included in Business                                          │
│  └── Custom retention: Enterprise                                          │
│                                                                              │
│  Layer 4: Support & Services                                                │
│  ├── Community: FREE (GitHub issues)                                       │
│  ├── Email: Pro ($29/month)                                                │
│  ├── Slack: Business ($299/month)                                          │
│  └── Dedicated: Enterprise ($2,000+/month)                                 │
│                                                                              │
│  Layer 5: Compliance & Security                                             │
│  ├── SOC2 Type I: Business tier                                            │
│  ├── SOC2 Type II: Enterprise                                              │
│  ├── HIPAA BAA: Enterprise + $500/month                                    │
│  └── FedRAMP: Custom (government pricing)                                  │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```


## 🔄 Distribution: How You Deliver

### Option A: Hosted API (SaaS) - 70% margin

```bash
# Developer signs up at api.agentgate.io
# Gets API key: ag_xyz123...

# Uses with Claude Code via proxy
export ANTHROPIC_BASE_URL=https://api.agentgate.io/v1/proxy
export AGENTGATE_API_KEY=ag_xyz123...

# AgentGate charges per request
# Your cost: ~$0.00005 per request (AWS/GCP)
# Your price: $0.0003 per request
# Margin: 83%
```

### Option B: Self-Hosted Cage (Software) - 90% margin

```bash
# Developer downloads
docker pull agentgate/cage:latest
docker run -d -p 8080:8080 agentgate/cage

# Your cost: $0 (open source distribution)
# Enterprise features: $2,000+/month license
# Margin: 90%+
```

### Option C: Hybrid (Recommended)

```
┌─────────────────────────────────────────────────────────────────┐
│                    HYBRID DISTRIBUTION                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  Small teams / solo developers:                                 │
│  └── Hosted API (pay as you go, no infrastructure)             │
│                                                                  │
│  Mid-market:                                                     │
│  └── Self-hosted Cage + Pro/Business features                  │
│                                                                  │
│  Enterprise:                                                     │
│  └── Self-hosted Cage + Enterprise license + support contract  │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```


## 📈 Go-to-Market Pricing Strategy

### Phase 1: Land & Expand (First 6 months)

| User Segment | Offer | Goal |
|--------------|-------|------|
| Solo developers | Free tier (1,000 req/month) | Build user base, get feedback |
| Open source | Free Cage (Apache 2.0) | Create ecosystem, viral growth |
| Early adopters | 50% off first year | Validate willingness to pay |

### Phase 2: Monetize (Months 6-12)

| Segment | Price | Conversion Target |
|---------|-------|-------------------|
| Free tier → Pro | $29/month | 5% conversion |
| Pro → Business | $299/month | 10% upgrade |
| Cage users → Enterprise | $2,000+/month | 1% conversion |

### Phase 3: Scale (Year 2+)

| Channel | Strategy |
|---------|----------|
| Self-serve | API pricing page, automatic upgrades |
| Sales | Enterprise contracts (6-figure ACV) |
| Partners | AWS Marketplace, GCP Marketplace |


## 💰 Financial Projections (Solo Founder Realistic)

### Year 1: Build & Validate

| Metric | Target |
|--------|--------|
| Free tier users | 10,000 |
| Pro users (5% conversion) | 500 |
| Pro MRR | $14,500 |
| Business users (10 of 500) | 10 |
| Business MRR | $2,990 |
| Total MRR (Year 1 end) | ~$17,500 |
| Annual Run Rate | ~$210,000 |

### Year 2: Scale

| Metric | Target |
|--------|--------|
| Free tier users | 50,000 |
| Pro users (8% conversion) | 4,000 |
| Pro MRR | $116,000 |
| Business users (5% of Pro) | 200 |
| Business MRR | $59,800 |
| Enterprise (5 at $2k) | 5 |
| Enterprise MRR | $10,000 |
| Total MRR (Year 2 end) | ~$186,000 |
| Annual Run Rate | ~$2.2M |

**This is realistic for a solo founder with a differentiated product in a growing market.**


## 🎯 What You Actually Build & Sell

### The API Service (Your Cloud)

```yaml
# What users interact with
api.agentgate.io:
  - POST /v1/check          # Policy decision (counts as 1 request)
  - POST /v1/audit          # Query audit logs (counts as 1 request)
  - GET /v1/policies        # List policies (free)
  - PUT /v1/policies/{id}   # Update policy (Business+)
  
# How you bill
- Free: 1,000 requests/month
- Pro: $29 for 100,000 requests ($0.00029 each)
- Business: $299 for 1,000,000 requests ($0.000299 each)
- Overages: $0.0005 per request after limit
```

### The Cage Software (Self-Hosted)

```yaml
# What users download
agentgate/cage:
  - Open source core (Apache 2.0)
  - Docker image (docker pull agentgate/cage)
  - Binary releases (Linux, macOS, Windows)
  
# What's free
- Basic policy engine
- Local audit log
- Single user
- Community support

# What's paid (license key)
- SSO (OIDC, SAML)
- Audit log export to SIEM
- Role-based access control
- 99.9% uptime SLA
- Dedicated support
```


## 🚀 Immediate Next Steps (This Week)

### 1. Set Up API Billing Infrastructure

```bash
# Use Stripe for payments (best for solo founders)
npm install stripe @stripe/stripe-js

# Use Upstash for rate limiting (free tier available)
npm install @upstash/ratelimit

# Use Supabase for user management (free tier)
# Or Auth0 (free tier up to 7,000 users)
```

### 2. Add API Key Authentication

```zig
// In your AgentGate API (main.zig)
const API_KEY_HEADER = "Authorization";

const valid_keys = std.StringHashMap(void).init(allocator);
// Load from database or environment

pub fn authenticate(req: *http.Request) !bool {
    const auth_header = req.headers.get("Authorization") orelse return false;
    const api_key = std.mem.trim(u8, auth_header, "Bearer ");
    return valid_keys.contains(api_key);
}
```

### 3. Add Rate Limiting

```zig
// Simple in-memory rate limiter
const RateLimiter = struct {
    requests: std.StringHashMap(u32),
    window_ms: u64 = 60_000,  // 1 minute
    limit: u32 = 100,          // 100 requests per minute
    
    pub fn check(self: *RateLimiter, key: []const u8) bool {
        const count = self.requests.get(key) orelse 0;
        if (count >= self.limit) return false;
        self.requests.put(key, count + 1) catch return false;
        return true;
    }
};
```

### 4. Create Pricing Page

```html
<!-- /pricing page on your website -->
<div class="pricing">
  <div class="tier free">
    <h3>Free</h3>
    <p class="price">$0<span>/month</span></p>
    <ul>
      <li>1,000 API requests</li>
      <li>7-day audit retention</li>
      <li>Community support</li>
    </ul>
    <button>Get Started</button>
  </div>
  
  <div class="tier pro">
    <h3>Pro</h3>
    <p class="price">$29<span>/month</span></p>
    <ul>
      <li>100,000 API requests</li>
      <li>90-day audit retention</li>
      <li>Email support</li>
    </ul>
    <button>Subscribe</button>
  </div>
  
  <div class="tier business">
    <h3>Business</h3>
    <p class="price">$299<span>/month</span></p>
    <ul>
      <li>1,000,000 API requests</li>
      <li>1-year audit retention</li>
      <li>Slack support</li>
    </ul>
    <button>Contact Sales</button>
  </div>
</div>
```


## ✅ Summary: Your API Service Revenue Model

| What You Provide | How You Charge | Typical Customer |
|-----------------|----------------|------------------|
| **Hosted API** | Pay per request ($0.0003) + monthly subscription | Solo devs, small teams |
| **Cage (self-hosted)** | Free (open core) + enterprise license ($2k+/month) | Enterprises, air-gapped |
| **Audit storage** | Included in subscription tiers | Compliance teams |
| **Support** | Tiered (email, Slack, dedicated) | All paying customers |
| **Professional services** | Hourly ($250-500/hour) | Enterprises needing custom policies |

**Your API service is the low-friction entry point. Your Cage software is the high-value enterprise product. Together, they cover the entire market.**

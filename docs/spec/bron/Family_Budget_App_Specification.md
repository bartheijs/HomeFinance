# Family Budget App — Feature Specification

## 1. Project Overview

### 1.1 Purpose
Replace a manually maintained Excel workbook (used since 2006) that tracks all family income, expenses, savings, and budgets on a shared "paying" bank account. The app must make the monthly reconciliation process faster, less error-prone, and more insightful — while preserving the exact financial logic the family already uses.

### 1.2 Current Pain Points
- Manually typing every transaction into the correct cell — slow and error-prone.
- Balance reconciliation is done by comparing the calculated balance with the real bank balance.
- Checking "besteedbaar" (spendable amount) requires temporarily filling in all planned monthly expenses to simulate end-of-month state.
- Flagging which expenses should be reimbursed from the savings account is manual.
- Tracking category totals (fuel, eating out) requires separate columns that must be manually tagged.
- No easy way to see trends or reports across months/years.

### 1.3 Key Workflow
1. **Import** bank transactions from CSV for a period.
2. **AI-assisted categorization**: the app suggests which budget line each transaction belongs to, based on description, amount, and history.
3. **Review & correct**: the user reviews suggestions and corrects before committing.
4. **Reconcile**: compare calculated balance with actual bank balance.
5. **Transfer flagging**: mark transactions that should be covered from the savings account; generate total transfer amount.
6. **Reports & insights**: view spending by category, trends over time, budget vs. actual.

---

## 2. Data Model (extracted from Excel)

### 2.1 Time Structure
- Data is organized per **year** (one sheet per year, 2006–2026+).
- Each year has **12 monthly columns** (jan–dec) plus a **"plan" column** (column B) representing the budgeted/expected amount.
- The app should support creating a new year by copying the plan from the previous year and allowing adjustments.

### 2.2 Transaction Categories

#### 2.2.1 Fixed Monthly Items (rows 2–~60 in Excel)
These are recurring monthly line items. Each has:
- A **label** (e.g. "UIT hypotheek", "IN Loon Ouder 1")
- A **direction prefix**: `UIT` (expense), `IN` (income), `RES` (reservation)
- A **plan amount** (what it should be each month)
- An **actual amount** per month (what was actually paid/received)

**Current fixed items (2026 example):**

**Income (IN):**
| Label | Plan Amount |
|-------|------------|
| IN Loon Ouder 2 | €2,000 |
| IN Loon Ouder 1 | €3,000 |
| IN kindgebonden budget | €100 |
| IN Kinderbijslag | €270 (quarterly) |

**Expenses (UIT) — monthly bills:**
| Label | Plan Amount |
|-------|------------|
| UIT boodschappen (groceries) | €450 |
| UIT Sparen (savings transfer) | €500 |
| UIT Spaar Kids Studie | €250 |
| UIT Spaar Kids Rijbewijs | €90 |
| UIT zorgverzekering (health insurance) | €350 |
| UIT Verzekering (other insurance) | €162.50 |
| UIT ORV (life insurance) | €12 |
| UIT hypotheek (mortgage) | €600 |
| UIT Odido (telecom) | €67.50 |
| UIT Auto wegenbelasting (road tax) | €94 |
| UIT Vattenfall (energy) | €120 |
| UIT Kosten ASN (bank fees) | €1.35 + €3.65 |
| UIT lening privé (private loan) | €200 |
| UIT waterbedrijf (water) | €23 |
| UIT Zangles Kind 1 | €60 |
| UIT Zangles Kind 2 | €60 |
| UIT kleedgeld Kind 1 regulier | €30 |
| UIT Parkeren app | €30 |
| UIT schoonmaak | variable |
| UIT Spotify | €21.99 |
| UIT t-mobile gezin | €65.50 |
| UIT HBO | €8.49 |
| UIT Netflix | €20.99 |
| UIT NPO Start | €2.95 |

**Note:** Some items appear/disappear over the years. The app must allow adding/removing line items.

#### 2.2.2 Reserveringen (Reservations) — rows 7–30
Monthly amounts set aside for annual/irregular expenses. They are:
- Listed individually (e.g. "RES Gemeente belastingen €100", "RES auto €250", "RES Levensverzekering €210")
- **Summed into a single line** "RESERVERINGEN" (row 6) which is the total transferred once per month
- The individual lines are visible for transparency but only the total is transferred

**Current reservations (2026):**
| Label | Monthly Amount |
|-------|---------------|
| RES Gemeente belastingen | €100 |
| RES waterbedrijf | €80 |
| RES Lenzen Kind 1 | €34 |
| RES Google drive | €9 |
| RES Boeken budget | €12.50 |
| RES spaar tandarts | €95 |
| RES eigenrisico zorg | €20 |
| RES ANWB | €15 |
| RES DAM | €30 |
| RES jaarbijdrage | €50 |
| RES auto | €250 |
| RES uitje ouders | €100 |
| RES Museum jaarkaart | €16 |
| RES club Kind 2 | €100 |
| RES club 1 Kind 1 | €100 |
| RES onderhoud CV | €20 |
| RES Levensverzekering | €210 |
| RES fietsen | €100 |
| RES onderhoud huis | €150 |
| RES Telefoons | €50 |
| RES kleedgeld Kind 1 | €20 |
| RES kleedgeld Kind 2 | €35 |
| RES AI | €25 |
| RES jaarlijks uitje | €25 |
| **Total RESERVERINGEN** | **€1,646.50** |

#### 2.2.3 IN Various (one-time income per month)
- Refunds, reimbursements, gifts, returns, bonus payments, vacation money
- Each entry has: description, amount, month column
- Examples: "retour tandarts €80.00", "Gift familie €2,000", "betalen wintersport €3,500.00"
- Summed per month in a total row

#### 2.2.4 UIT Various (one-time expenses per month)
- All ad-hoc spending: shopping, fuel, eating out, subscriptions, pocket money, vacation costs, etc.
- Each entry has: description, amount, month column
- Examples: "tanken -€32.26", "IKEA -€171.79", "zakgeld -€7.00"
- Summed per month in a total row

#### 2.2.5 Category Tracking Columns (P and Q)
- **Column P**: "Uit eten / Horeca" — eating out expenses are tagged here with the same amount
- **Column Q**: "Tanken" (fuel) — fuel expenses are tagged here
- These are **not additional expenses** — they duplicate amounts from UIT Various for tracking purposes
- The app should support arbitrary tracking categories (user-configurable)

### 2.3 Summary Calculations

#### 2.3.1 Monthly Totals
- **IN Various total** per month: sum of all one-time income
- **UIT Various total** per month: sum of all one-time expenses
- **IN - UIT** per month: (IN Various total) - abs(UIT Various total) = net one-time cash flow

#### 2.3.2 "Tov maand budget" (vs monthly budget)
- Compares actual month result against the planned monthly surplus/deficit
- Formula: `plan_total - (IN_various - UIT_various)` per month
- Positive = underspent vs plan, negative = overspent

#### 2.3.3 Year-End Summary
| Field | Description |
|-------|-------------|
| Op de rekening op 01-01 | Opening balance at start of year |
| IN | Total income for the year |
| UIT | Total expenses for the year |
| Op de rekening | Closing balance = opening + IN + UIT |
| Reserveringen | Amount currently reserved (on the account but earmarked) |
| anti rood buffer | Safety buffer to prevent going negative (currently €4,500) |
| Tijdelijk anti rood | Temporary additional buffer (€0 normally) |
| Besteedbaar | Truly spendable = closing balance - reserveringen - anti_rood - tijdelijk_anti_rood |

### 2.4 Special Concepts

#### 2.4.1 Reserveringen Balance
- Money sits on the paying account but is earmarked for future bills
- When a reserved expense is actually paid (e.g. annual insurance), the reservation amount decreases
- The "UIT lening privé" payments reduce the reservation pool

#### 2.4.2 Anti-Rood Buffer
- Two buffers: a permanent one (€4,500) and a temporary one (€0 currently)
- Purpose: keep the account from going below zero
- Sometimes anti-rood amounts are temporarily added/removed (visible in IN/UIT Various as "anti rood" entries of +€1,000 or -€1,000)

#### 2.4.3 Besteedbaar (Spendable) Calculation
This is the key metric. It answers: "If all monthly bills were paid this month, how much could we actually spend?"
- `Besteedbaar = current_balance - reserveringen - anti_rood_buffer - tijdelijk_anti_rood`
- To calculate it, you must simulate as if all fixed monthly expenses and income have been processed

#### 2.4.4 Savings Account Transfers
- Some expenses in UIT Various should be reimbursed from the savings account (e.g. large purchases, vacation costs)
- The user flags these during review
- At month-end, the total flagged amount is transferred from savings to the paying account

#### 2.4.5 Pocket Money ("zakgeld")
- Regular weekly pocket money for the kids (Kind 1 and Kind 2)
- Amounts change over the years (currently €7 + €5 per week)
- Appears as individual entries in UIT Various

---

## 3. Features

### 3.1 CSV Import & AI-Assisted Categorization

**3.1.1 CSV Import**
- Upload bank CSV export (ASN Bank format, or configurable for other banks)
- Parse: date, description, amount, counter-account, reference
- Show imported transactions in a review list
- Support importing a date range (partial month, full month, or multiple months)

**3.1.2 Rule-Based Categorization**
- For each imported transaction, the engine applies stored rules to suggest:
  - **Which budget line it belongs to** (fixed monthly item OR "various")
  - **Whether it's IN or UIT**
  - **A description** (cleaned up from bank description)
  - **Tracking category tags** (e.g. "tanken", "uit eten")
  - **Whether it should be flagged for savings account reimbursement**
- Rules are built from:
  - Counterparty name/account (e.g. "Hypotheekverstrekker" → "UIT hypotheek")
  - Amount matching (e.g. €600.00 → mortgage)
  - User-created rules from past corrections (self-learning)
  - Description keywords (e.g. "tanken" → fuel category)
- Present suggestions with confidence level (high/medium/low/none)
- Allow bulk operations (e.g. "all zakgeld entries confirmed")
- Every user correction automatically creates or refines a matching rule

**3.1.3 Review & Commit**
- Show each transaction with its suggested categorization
- Allow user to:
  - Accept suggestion
  - Change category
  - Change description
  - Add/remove tracking tags
  - Flag for savings reimbursement
  - Split a transaction across categories
  - Mark as "skip" (already entered)
- Commit button saves all reviewed transactions to the budget

### 3.2 Budget Management

**3.2.1 Year Setup**
- Create a new year from template (copy plan from previous year)
- Edit plan amounts for any line item
- Add/remove budget line items
- Reorder items

**3.2.2 Monthly View**
- Show the familiar grid: rows = budget items, columns = months
- Color coding:
  - Green: amount matches plan
  - Yellow: amount differs from plan
  - Gray: not yet entered (future months)
  - Red: missing (expected but not received/paid)
- Click a cell to see the underlying transaction(s)
- Edit amounts directly in the grid

**3.2.3 Reserveringen Management**
- View individual reservation items and their monthly amounts
- Auto-calculate the total "RESERVERINGEN" amount
- When a reserved expense occurs (e.g. annual insurance paid), prompt to reduce the relevant reservation
- Track reservation balance over time

**3.2.4 Fixed Items Tracking**
- Dashboard showing which monthly bills have been paid this month and which are pending
- Alert for bills that are overdue (past their usual date)
- Show variance from plan (e.g. "Odido was €69.34 instead of planned €67.50")

### 3.3 Balance & Reconciliation

**3.3.1 Balance Tracking**
- Opening balance per year (manually entered once)
- Running balance calculated from all transactions
- Compare calculated balance with actual bank balance (user enters actual)
- Show difference — must be €0.00 to confirm no errors

**3.3.2 Besteedbaar Calculator**
- Show current "besteedbaar" amount at any point in the month
- Simulate: "If all remaining monthly items were processed, what would besteedbaar be?"
- Update in real-time as transactions are added

**3.3.3 Savings Transfer Summary**
- Show all transactions flagged for savings reimbursement
- Calculate total to transfer
- Mark transfer as completed
- History of savings transfers

### 3.4 Reports & Analytics

**3.4.1 Monthly Summary**
- Total IN, total UIT, net result
- vs. plan comparison
- Breakdown by category
- Besteedbaar trend

**3.4.2 Category Reports**
- For tracked categories (tanken, uit eten, etc.):
  - Monthly totals
  - Running year total
  - Trend chart
  - Average per month
- Useful for: "How much do we spend on fuel per month? Should we increase the salary transfer?"

**3.4.3 Year-over-Year Comparison**
- Compare any metric across years
- See how spending patterns change
- Track income growth

**3.4.4 Budget vs. Actual**
- Per line item: planned vs. actual per month
- Highlight items consistently over/under budget
- Annual totals

**3.4.5 Expense Breakdown**
- Pie/bar charts of UIT Various by category or tag
- Top expenses per month
- "Where did the money go?" view

### 3.5 Data Management

**3.5.1 Historical Data**
- Import historical data from the existing Excel (2006–2026)
- All years should be queryable for reports
- Read-only for completed years, editable for current year

**3.5.2 Export**
- Export to Excel (recreate the familiar format)
- Export to CSV
- PDF reports

**3.5.3 Backup**
- Database backup/restore
- Export complete dataset

---

## 4. Business Rules

### 4.1 Amount Conventions
- All expenses are stored as **negative numbers**
- All income is stored as **positive numbers**
- The plan column stores the expected amount (negative for expenses, positive for income)

### 4.2 Kinderbijslag (Child Benefits)
- Paid quarterly, not monthly
- Plan amount is the monthly equivalent (annual / 12)
- Actual amount appears in the quarter it's received

### 4.3 Reservation Total
- The "RESERVERINGEN" line (row 6) = sum of all individual RES items (rows 7-30)
- This total may change during the year (items added/removed mid-year)
- Only the total is transferred as a single transaction each month

### 4.4 Anti-Rood Management
- When cash gets tight, a temporary "anti rood" amount is added (shows as +€1,000 in IN Various)
- When it's paid back, it shows as -€1,000 in UIT Various
- The outstanding anti-rood balance should be tracked

### 4.5 Vacation Money
- "vakantiegeld" (holiday pay) is a lump sum received once a year
- Often transferred to savings immediately
- Should be handled as one-time income, not regular monthly income

### 4.6 Plan Amount Changes
- Some bills change amounts during the year (e.g. insurance premium changes)
- The plan column shows the "current" expected amount
- Historical months retain their actual amounts regardless of plan changes

### 4.7 Transaction Matching Rules (rule-based engine)
Priority order:
1. **Exact counterparty + amount match** → auto-assign with high confidence
2. **Counterparty match, different amount** → suggest category, flag amount difference
3. **Keyword match in description** → suggest with medium confidence
4. **Amount match only** → suggest with low confidence
5. **No match** → present as uncategorized
6. **User correction** → automatically creates/updates a rule for next time

Common patterns to recognize:
- "zakgeld" amounts (€7, €5) appearing weekly → pocket money
- Recurring same-amount debits → likely a monthly bill
- "retour" in description → refund/return (positive amount)
- "tanken" or fuel station names → fuel category
- Restaurant/café names → eating out category
- "scouting", "turnen" → children's activities

---

## 5. User Interface Requirements

### 5.1 Login
- Google "Sign in" button
- If the user's email is not in the allowed list, show an access denied message
- Stay logged in via session (don't require login every visit)

### 5.2 Dashboard
- Current month overview
- Besteedbaar amount (prominently displayed)
- Bills paid/pending status
- Recent transactions
- Quick actions: import CSV, view reports

### 5.3 Transaction Import Screen
- Drag & drop CSV upload
- Preview of parsed transactions
- Bulk categorization review
- Confidence indicators
- Filter by: uncategorized, low confidence, flagged for savings

### 5.4 Monthly Budget Grid
- Spreadsheet-like view matching the familiar Excel layout
- Scrollable months, sticky category labels
- Inline editing
- Color-coded cells (paid/pending/missing/differs from plan)

### 5.5 Reports Screen
- Date range selector
- Category filter
- Chart type selector (bar, line, pie)
- Export buttons

### 5.6 Settings
- Budget plan management (add/remove/edit line items)
- Tracking categories configuration
- Bank CSV format configuration
- Anti-rood buffer amount
- Reservation items management

---

## 6. Technical Considerations

### 6.1 Platform & Architecture
- **Web application** (responsive, mobile-specific pages may be added later)
- **Single user** with **Google OAuth login** (free, no subscription needed)
  - Uses Google Cloud OAuth 2.0 credentials
  - Only the configured Google email address is allowed to log in (whitelist of 1)
  - Easily extendable: add more email addresses to allow other family members
  - Session managed via HTTP-only cookie or JWT
- **Frontend:** React with TypeScript, CSS (user is experienced in this stack)
- **Backend:** Node.js with TypeScript (Express or Fastify)
- **Database:** SQLite via Prisma ORM (recommended for v1 — zero setup, file-based, perfect for single-user; can migrate to PostgreSQL later if needed). Prisma gives you a typed schema, migrations, and easy querying without needing to learn SQL.
- **Monorepo** structure: `/client` (React) + `/server` (Node/Express) + shared types

### 6.2 Data Storage
- **SQLite** via **Prisma ORM** (file-based, no server needed, migrateable to PostgreSQL later)
- Key models: Year, BudgetItem, Transaction, Category, TrackingTag, Reservation, CategorizationRule
- Prisma schema provides TypeScript types shared between frontend and backend

### 6.3 CSV Parsing
- Support ASN Bank CSV format (primary) — sample CSV will be provided during development
- Configurable column mapping for other banks
- Handle Dutch number format (comma as decimal separator)
- Handle date formats (dd-mm-yyyy)

### 6.4 Categorization Engine (Rule-Based)
- **Phase 1: Rule-based matching only** (no AI/ML)
- Matching rules stored in the database, editable by the user
- Rule types:
  1. **Counterparty match**: exact or partial match on counterparty name/account → assign category
  2. **Amount match**: specific amount recurring monthly → assign to fixed item
  3. **Keyword match**: keywords in description (e.g. "tanken", "scouting") → assign category + tracking tag
  4. **Combined rules**: counterparty + amount range → high-confidence match
- Every user correction creates or updates a rule automatically
- Rules have a priority order; first match wins
- **Future phase:** optionally add Claude API for smarter parsing of unfamiliar transactions

### 6.5 Multi-Year Support
- Efficient storage and querying across 20+ years of data
- Year initialization workflow
- Balance carry-forward between years

---

## 7. Migration Plan

### 7.1 Data Import from Excel
- Parse all sheets (2006–2026) from the existing .xlsx file
- Map to the new data model
- Preserve all historical transactions
- Validate totals match after import

### 7.2 Rule Seeding from Historical Data
- Extract unique counterparties and their historical categorizations
- Auto-generate matching rules from patterns (e.g. "Hypotheekverstrekker" always maps to mortgage)
- Pre-populate tracking category assignments (tanken, uit eten)
- User can review and refine generated rules before going live

---

## 8. Glossary

| Dutch Term | English | Description |
|-----------|---------|-------------|
| Besteedbaar | Spendable | Amount truly available after all obligations |
| Reserveringen | Reservations | Money set aside for future/annual expenses |
| Anti-rood | Anti-red (overdraft prevention) | Safety buffer |
| Tanken | Fuel | Car fuel expenses |
| Uit eten | Eating out | Restaurant/café expenses |
| Zakgeld | Pocket money | Children's allowance |
| Boodschappen | Groceries | Weekly grocery budget |
| Sparen | Savings | Transfer to savings account |
| Kinderbijslag | Child benefits | Government quarterly payment |
| Kindgebonden budget | Child-linked budget | Government child support |
| Wegenbelasting | Road tax | Quarterly car tax |
| Schoonmaak | Cleaning | House cleaning service |
| Kleedgeld | Clothing allowance | Money for kids' clothes |
| Vakantiegeld | Holiday pay | Annual lump sum from employer |

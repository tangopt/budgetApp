# Property Management and UK Self Assessment — Design Spec

Status: **for review** (2026-10-16). Supersedes the DRAFT of the same date. Personal figures are deliberately not in this file (they live in the user's `Tax/_app-import/` data).

## 0. Decisions so far
- Outputs in **GBP at the HMRC average rate** for the tax year; source amounts stay in their own currency.
- **UK only** for tax outputs (Portugal data is kept as input: PT tax paid, PT returns as evidence).
- The app keeps an **evidence library** (copies of files it links or the user adds; renamed; fingerprinted) and **remembers the source folders** (Lisboa, Tax, IRS UK) to pick up new/changed files; it may later tidy those folders to its structure with the user's approval.
- **2025/26 is the first live year**; **2024/25 and 2023/24 are regression years** (must reproduce both people's filed returns).
- For 2025/26 and every later year the app produces **both** the full SA box values **and the accountant's template output** (filled .xlsx per person) so the user can file alone or hand it to an accountant.
- The property's data serves **two purposes**: the yearly tax return, and a **holistic view of the property's finances**.
- **All costs come from the BBVA movements** (already imported); **documentary evidence comes from external sources** (portal rent receipts, notices, invoices, statements), linked to the transactions.
- Future iOS/iPadOS clients: all logic in BudgetCore; the evidence library is sync-ready.

## 1. Property (holistic view)
New **Property** area (sidebar), one page per property (Lisbon today):
- **Profile**: name, country, matrix article, owners with ownership % by date range, linked accounts (BBVA current, BBVA mortgage, tenant deposit held, retirement fund is NOT property), purchase/loan facts (capital borrowed, term, balloon), documents (deeds, licences, certificates).
- **Tenancies**: tenant, contract (document), start/end, rent history (e.g. 2,100 → 2,300), advance rent and caução held (ties to the "Tenant deposit held" account), receipts.
- **Money**: per calendar year and per UK tax year — rent received, costs by Lisbon category, mortgage interest vs capital, net cash flow, yield on purchase price, outstanding loan; charts over time; links to the Budget grid filtered to the property's accounts/categories.
- **Obligations calendar**: IMI instalments, condomínio, insurance renewals, PT IRS deadline, UK SA deadlines, rate resets on the mortgage.
- **Checks**: rent months without a receipt, transactions without evidence, expected recurring costs missing, deposit balance vs contract.

## 2. Records and links
- **Rent receipt** (imported from the Portal das Finanças receipts — CSV/XLS export or PDF): contract, receipt no., **rent period**, receipt date, amount, withholding, status (issued/cancelled); **linked to the BBVA credit(s)** that paid it (many-to-one allowed: tenant transfers include utility recharges).
- **Transaction ↔ evidence**: any transaction can link to one or more documents; any document can link to several transactions (e.g. one IMI notice → 3 instalment payments; one insurance receipt → one debit).
- **Tax line ↔ transactions**: each deduction/income line of a tax year lists the transactions (or manual items) it is computed from, with the attribution rule applied, so every SA box drills down: box → line → transactions → documents.
- **Manual tax items**: things not in BBVA (UK accountant invoice in GBP, postage, P60/P11D figures, HMRC payments) are entered with their document.

## 3. Evidence library
- Stored in the app's container (`Application Support/Budget/Evidence/<sha256 prefix>/…`), with metadata: original path, source folder, imported name, canonical name (`YYYYMMDD - <Area> - <Type> - <Detail>[ - period][ - amount]`), type, dates/period, amount, persons, hash, text-extractability (BBVA glyph decoding; image-only flagged).
- **Source folders** are registered; a scan shows new/changed/missing files and proposes links (by date/amount/type match) for review; nothing is moved in the user's folders without approval.
- Only **linked or explicitly added** files are copied (not the whole folder).
- **Export**: per tax year, an evidence pack folder in the IRS UK structure (and optional password-protected zip).

## 4. UK tax engine
- **Tax year** record per person: status (preparing → ready → filed → paid), HMRC average EUR rate, ownership/deduction split per expense type (default from property ownership; history can differ by year), FX of GBP-native items, deadlines (31 Jan balancing + 1st POA, 31 Jul 2nd POA).
- **Attribution rules** (configurable per expense type; defaults from the workbook): rent by rent-period month; mortgage interest by instalment (debit) month; service charge by quota month; building insurance apportioned by months of cover; IMI = full previous calendar year; others by invoice date; PT tax calendar year N → UK year N/N+1 for FTCR.
- **Personal income**: P60/P45 (pay, tax), P11D (benefits) imported from PDF (form-field/text extraction, user confirms), plus UK interest/dividends/pension contributions/Gift Aid if any.
- **Computation (SA110)**: personal allowance incl. taper, bands and rates for the year (rules stored per tax year), property profit (SA106 F4/F5) with residential finance costs at basic-rate credit, FTCR per source with the UK-tax-on-that-income limit, payments on account, balancing payment — every step shown.
- **Outputs**: (a) SA100/SA102/SA106 box-by-box values with an HMRC-online filing checklist; (b) the **accountant template** (.xlsx per person, same layout as the accountant's) and a rental-accounts PDF; (c) evidence pack.
- **Regression gate**: from the stored records the engine reproduces the 2024/25 and 2023/24 SA302s/approval packs for both people (box values and liability) before 2025/26 is marked ready.

## 5. Phasing (each its own plan)
1. **Evidence library + links** (library, source folders, transaction↔document links, BBVA glyph-decoding import of PDFs, matching suggestions).
2. **Property area** (profile, tenancies, deposit, money views, checks) + **rent receipts import**.
3. **Tax years + attribution + rental accounts** (per person, GBP, drill-down) + accountant template export; regression on rental accounts 2023/24, 2024/25.
4. **Personal income imports (P60/P45/P11D) + SA computation + box values + filing checklist**; full regression on both SA302s; 2025/26 live.

## 6. Open questions
1. Rent receipts: can the portal export them (CSV/XLS), or only PDFs?
2. HMRC average rate: enter yearly by hand, or fetch from HMRC's published rates?
3. Any other personal income or reliefs for either person (UK interest, dividends, pension outside payroll, Gift Aid, student loan, child benefit, capital gains)?
4. Should utilities recharged to the tenant be netted against the tenant's transfers in the property view (rent vs recharges)?

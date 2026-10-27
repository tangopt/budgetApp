# Step 9: documents first, statements later — design

Status: written 2026-10-27 from the user's request of 2026-10-24 (memory: "documents imported before their bank
movement exists stay 'waiting for a transaction'; when a later statement import brings the matching debit/credit,
Mango links them automatically (or proposes the link)"). Calls marked *(my call)* are open to correction.
Budget ~3%.

## 1. Intent

Bills, receipts and invoices often arrive (by email, or fetched on the iPad) before the bank statement that pays
them is imported. Today such a document sits unlinked and shows as missing evidence or an unlinked document until
someone links it by hand. The user wants it to wait quietly and link itself when the payment arrives.

## 2. Behaviour

1. **Waiting for a transaction.** A document whose kind expects a payment (utility bill, invoice, insurance, IMI,
   condomínio, repair bill, receipts with an amount) and that has no linked transaction is "Waiting for its
   payment" — a state shown on the document (Mac and iPad document panel) and in Documents' filter, not an error.
   It is not "missing evidence" while waiting.
2. **When a statement import (or sync from another device) brings new transactions**, Mango looks for each
   waiting document's payment using the existing matching rules (amount — net of credits —, date window after the
   document's issue/due date, payee/provider, account):
   - **exactly one confident match** → linked automatically *(my call)*, through the same guarded link path as a
     manual link (filed-year check; a refusal leaves it waiting). The import summary lists "N documents linked to
     their payments" with each pair and an Undo per pair.
   - **several candidates or a weaker match** → a suggestion, shown on the document and in Missing evidence's side
     panel (existing suggestions UI), one click to accept.
   - **nothing** → stays waiting.
3. **Utility bills** keep their bills-tracker stages: linking moves the bill from "invoice in" to "linked to
   payment" as today.
4. **Give up after a while** *(my call)*: a waiting document with no match 90 days after its due/issue date
   becomes an ordinary unlinked document (shown in Missing evidence as today), so the waiting list doesn't grow
   forever.
5. Runs on the Mac (statement imports happen there) after every import and after sync merges; the iPad shows the
   state and accepts suggestions through DeviceWriter.

## 3. Constraints

- Logic in BudgetCore, reusing existing evidence/payment matching (EvidenceLinkGuard, utility invoice intake,
  suggestions) — no second matcher.
- Filed SA years 2020/21–2024/25 never change; an automatic link into a filed year is never made (it becomes a
  suggestion the user must confirm through the filed-year warning).
- No new CloudKit record types if avoidable (the waiting state is derived, not stored) *(my call)*.
- Mac fits 1100×700; no figure wraps; names truncate in the middle; nothing saves except explicit actions (the
  automatic link is the import's own explicit action, reported with Undo).
- Tenant's personal name only on Tenancies and in the recharge email.

## 4. Non-goals

Matching documents to transactions across different currencies by FX guess; linking statements themselves;
changing how imports are confirmed.

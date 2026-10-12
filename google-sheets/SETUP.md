# Wida Jewls delivery Google Sheet setup

This integration exports only orders that have been confirmed in the Wida admin. Subsequent status changes update the same row using the order number, so it does not create duplicate rows.

## Columns shared with the delivery company

N° de commande · Date de commande · Nom complet · Téléphone · Ville · Adresse complète · Produit(s) · Quantité · Montant à encaisser (DH) · Statut · Notes

No product cost, margin, discount code, customer lifetime value, or other private business fields are sent.

## 1. Create and bind the Google Sheet

1. Create a blank Google Sheet named **Wida Jewls — Commandes livraison**.
2. Rename the first tab to **Commandes livraison** (the script will also create it if missing).
3. Open **Extensions → Apps Script**.
4. Replace the editor content with the contents of `Code.gs` in this folder.
5. Replace `REPLACE_WITH_A_LONG_RANDOM_SECRET` with a long random secret. Do not share this secret with the delivery company.
6. Save the project.

## 2. Deploy the Apps Script endpoint

1. Click **Deploy → New deployment**.
2. Select **Web app**.
3. Set **Execute as** to **Me**.
4. Set **Who has access** to **Anyone** so the Supabase server can send orders to it. The endpoint rejects requests without the shared secret.
5. Deploy, authorize access to the spreadsheet, and copy the Web app URL ending in `/exec`.

Keep the Apps Script project private. Share only the Google Sheet with the delivery company, not the script project.

## 3. Configure Supabase

After the migration is applied, open the Wida Jewls Supabase SQL Editor and run the following, replacing both placeholder values. Use the same secret that you put in `Code.gs`.

```sql
insert into public.integration_settings (key, value) values
  ('google_sheets_webhook_url', 'PASTE_YOUR_APPS_SCRIPT_WEB_APP_URL_HERE'),
  ('google_sheets_token', 'PASTE_THE_SAME_LONG_RANDOM_SECRET_HERE')
on conflict (key) do update
set value = excluded.value, updated_at = now();
```

Do not put the endpoint URL or secret in the public website's JavaScript. The private table is accessible only to the Supabase service role.

## 4. Deploy and test

1. Merge/deploy the Wida branch containing this integration.
2. Deploy the Supabase Edge Function `sync-delivery-order` with JWT verification enabled.
3. Sign in to the Wida admin, open a test order, and change its status to **confirmed**.
4. Check that exactly one row appears in the sheet. Change the order to **shipped** and confirm the same row's status changes instead of creating a duplicate.
5. Share the Google Sheet with the delivery company as **Viewer** initially. If they need to update statuses in the sheet, that is a separate two-way sync feature and should be added deliberately.

If a sync fails, the order status remains saved in Wida; the admin displays a warning and the database stores a short sync error for troubleshooting.

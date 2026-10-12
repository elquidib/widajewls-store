/**
 * Wida Jewls — private delivery dispatch sheet.
 * Bind this Apps Script to the Google Sheet via Extensions > Apps Script.
 * Replace SHARED_SECRET with the same long random token stored in Supabase.
 */
const SHARED_SECRET = "REPLACE_WITH_A_LONG_RANDOM_SECRET";
const HEADERS = [
  "N° de commande",
  "Date de commande",
  "Nom complet",
  "Téléphone",
  "Ville",
  "Adresse complète",
  "Produit(s)",
  "Quantité",
  "Montant à encaisser (DH)",
  "Statut",
  "Notes"
];

function doGet() {
  return json_({ ok: true, service: "Wida Jewls delivery sheet" });
}

function doPost(e) {
  const lock = LockService.getScriptLock();
  try {
    lock.waitLock(10000);
    const body = JSON.parse((e && e.postData && e.postData.contents) || "{}");
    if (!SHARED_SECRET || SHARED_SECRET.indexOf("REPLACE_") === 0 || body.token !== SHARED_SECRET) {
      return json_({ ok: false, error: "Unauthorized" });
    }
    const order = body.order;
    if (!order || order.order_number == null || !Array.isArray(order.items)) {
      return json_({ ok: false, error: "Invalid order payload" });
    }

    const ss = SpreadsheetApp.getActiveSpreadsheet();
    if (!ss) return json_({ ok: false, error: "No bound spreadsheet found" });
    const sheet = ss.getSheetByName("Commandes livraison") || ss.insertSheet("Commandes livraison");
    ensureHeaders_(sheet);

    const orderNumber = String(order.order_number);
    const lastRow = sheet.getLastRow();
    let targetRow = 0;
    if (lastRow >= 2) {
      const found = sheet.getRange(2, 1, lastRow - 1, 1)
        .createTextFinder(orderNumber).matchEntireCell(true).findNext();
      if (found) targetRow = found.getRow();
    }
    if (!targetRow) targetRow = Math.max(2, sheet.getLastRow() + 1);

    const items = order.items;
    const productNames = items.map(item =>
      String(item.product_name || "") + (Number(item.quantity) > 1 ? " × " + Number(item.quantity) : "")
    ).filter(Boolean);
    const quantity = items.reduce((sum, item) => sum + Number(item.quantity || 0), 0);
    const row = [
      orderNumber,
      order.created_at ? new Date(order.created_at) : "",
      String(order.customer_name || ""),
      String(order.phone || ""),
      String(order.city || ""),
      String(order.address || ""),
      productNames.join(" ; "),
      quantity,
      Number(order.total || 0),
      frenchStatus_(order.status),
      String(order.notes || "")
    ];
    sheet.getRange(targetRow, 1, 1, HEADERS.length).setValues([row]);
    sheet.getRange(targetRow, 1).setNumberFormat("@");
    sheet.getRange(targetRow, 2).setNumberFormat("dd/MM/yyyy HH:mm");
    sheet.getRange(targetRow, 4).setNumberFormat("@");
    sheet.getRange(targetRow, 9).setNumberFormat('0.00 "DH"');
    sheet.setFrozenRows(1);
    sheet.getRange(1, 1, 1, HEADERS.length).setFontWeight("bold");
    sheet.autoResizeColumns(1, HEADERS.length);
    sheet.setColumnWidth(6, 260);
    sheet.setColumnWidth(7, 220);
    sheet.setColumnWidth(11, 220);
    return json_({ ok: true, order_number: orderNumber, action: targetRow > 2 ? "upserted" : "saved" });
  } catch (err) {
    return json_({ ok: false, error: String(err && err.message || err) });
  } finally {
    try { lock.releaseLock(); } catch (_) {}
  }
}

function ensureHeaders_(sheet) {
  if (sheet.getLastRow() === 0) {
    sheet.getRange(1, 1, 1, HEADERS.length).setValues([HEADERS]);
  } else {
    const existing = sheet.getRange(1, 1, 1, HEADERS.length).getValues()[0];
    if (existing.join("|") !== HEADERS.join("|")) {
      throw new Error('Unexpected headers. Keep the first row exactly as the Wida delivery template.');
    }
  }
}

function frenchStatus_(status) {
  const map = {
    new: "Nouvelle",
    confirmed: "Confirmée",
    processing: "En préparation",
    shipped: "Expédiée",
    delivered: "Livrée",
    cancelled: "Annulée",
    returned: "Retournée"
  };
  return map[String(status || "").toLowerCase()] || String(status || "");
}

function json_(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj))
    .setMimeType(ContentService.MimeType.JSON);
}

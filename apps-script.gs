/**
 * Коло добрих екосправ — бекенд на Google Таблиці.
 * 101 курінь УСП «Карпатські Вовки»
 *
 * Що робить: тримає по одному рядку на кожного новака
 * і віддає сайтові суми по роях.
 *
 * Нічого тут міняти не треба — просто вставити й розгорнути.
 */

var SHEET_NAME = 'поступ';
var HEADERS = ['рій', 'прізвисько', 'справи', 'кількість', 'оновлено'];

/* ---------- точки входу ---------- */

function doPost(e) {
  var lock = LockService.getScriptLock();
  try {
    lock.waitLock(25000);
  } catch (err) {
    return out({ ok: false, error: 'таблиця зайнята, спробуй ще раз' });
  }
  try {
    var req = JSON.parse(e.postData.contents);
    var sh = sheet();
    var grp = clean(req.grp);
    var nick = clean(req.nick);
    if (!grp || !nick) return out({ ok: false, error: 'потрібні рій і прізвисько' });

    if (req.action === 'save') {
      saveRow(sh, grp, nick, req.codes || []);
    }
    return out({ ok: true, done: readOne(sh, grp, nick), board: board(sh) });
  } catch (err) {
    return out({ ok: false, error: String(err) });
  } finally {
    lock.releaseLock();
  }
}

function doGet(e) {
  var p = (e && e.parameter) || {};
  var cb = p.callback;
  var res;

  var lock = LockService.getScriptLock();
  try {
    lock.waitLock(25000);
  } catch (err) {
    return reply(cb, { ok: false, error: 'таблиця зайнята, спробуй ще раз' });
  }
  try {
    var sh = sheet();
    var grp = clean(p.grp);
    var nick = clean(p.nick);

    if (p.action === 'save') {
      if (!grp || !nick) {
        res = { ok: false, error: 'потрібні рій і прізвисько' };
      } else {
        saveRow(sh, grp, nick, String(p.codes || '').split(',').filter(String));
        res = { ok: true, done: readOne(sh, grp, nick), board: board(sh) };
      }
    } else if (p.action === 'load') {
      res = {
        ok: true,
        done: (grp && nick) ? readOne(sh, grp, nick) : [],
        board: board(sh)
      };
    } else {
      res = { ok: true, board: board(sh) };
    }
  } catch (err) {
    res = { ok: false, error: String(err) };
  } finally {
    lock.releaseLock();
  }
  return reply(cb, res);
}

function reply(cb, obj) {
  var json = JSON.stringify(obj);
  if (cb) {
    return ContentService
      .createTextOutput(cb + '(' + json + ')')
      .setMimeType(ContentService.MimeType.JAVASCRIPT);
  }
  return ContentService
    .createTextOutput(json)
    .setMimeType(ContentService.MimeType.JSON);
}

/* ---------- таблиця ---------- */

function sheet() {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sh = ss.getSheetByName(SHEET_NAME);
  if (!sh) {
    sh = ss.insertSheet(SHEET_NAME);
    sh.appendRow(HEADERS);
    sh.getRange(1, 1, 1, HEADERS.length).setFontWeight('bold');
    sh.setFrozenRows(1);
  }
  return sh;
}

function data(sh) {
  var last = sh.getLastRow();
  if (last < 2) return [];
  return sh.getRange(2, 1, last - 1, HEADERS.length).getValues();
}

function findRow(sh, grp, nick) {
  var rows = data(sh);
  for (var i = 0; i < rows.length; i++) {
    if (key(rows[i][0]) === key(grp) && key(rows[i][1]) === key(nick)) {
      return i + 2; // номер рядка в аркуші
    }
  }
  return 0;
}

function saveRow(sh, grp, nick, codes) {
  var list = [];
  for (var i = 0; i < codes.length; i++) {
    var c = clean(codes[i]);
    if (c && list.indexOf(c) === -1) list.push(c);
  }
  var row = [grp, nick, list.join(','), list.length, new Date()];
  var at = findRow(sh, grp, nick);
  if (at) {
    sh.getRange(at, 1, 1, HEADERS.length).setValues([row]);
  } else {
    sh.appendRow(row);
  }
}

function readOne(sh, grp, nick) {
  var at = findRow(sh, grp, nick);
  if (!at) return [];
  var cell = String(sh.getRange(at, 3).getValue() || '');
  return cell ? cell.split(',') : [];
}

function board(sh) {
  var rows = data(sh);
  var acc = {};
  for (var i = 0; i < rows.length; i++) {
    var name = clean(rows[i][0]);
    if (!name) continue;
    var k = key(name);
    if (!acc[k]) acc[k] = { grp: name, sum: 0, n: 0 };
    acc[k].sum += Number(rows[i][3]) || 0;
    acc[k].n += 1;
  }
  var list = [];
  for (var k2 in acc) list.push(acc[k2]);
  list.sort(function (a, b) { return b.sum - a.sum; });
  return list;
}

/* ---------- дрібниці ---------- */

function clean(v) {
  return String(v == null ? '' : v).trim().slice(0, 24);
}

function key(v) {
  return String(v == null ? '' : v).trim().toLowerCase();
}

function out(obj) {
  return ContentService
    .createTextOutput(JSON.stringify(obj))
    .setMimeType(ContentService.MimeType.JSON);
}

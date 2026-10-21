package com.pntapps.veltoret.data.pairing

import com.pntapps.veltoret.data.smb.FoundServer

/**
 * The page a phone's browser opens from the TV's QR code: the same fields as the TV screen, sent back to
 * the TV, which answers with "connected" or the problem. Flat dark styling like the app (no gradients).
 */
object PhoneSetupPage {

    fun html(tvName: String, found: List<FoundServer>, sendPath: String): String {
        val options = found.joinToString("") { s ->
            val label = s.name ?: if (s.isRouter) "Your router" else "File server"
            """<option value="${escape(s.address)}">${escape(label)} · ${escape(s.address)}</option>"""
        }
        val serverField = if (found.isEmpty()) "" else """
            <label>Server on your network</label>
            <select id="found" onchange="if(this.value) document.getElementById('address').value=this.value">
              <option value="">Choose one…</option>$options
            </select>"""
        return """<!doctype html>
<html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Veltoret · Add network server</title>
<style>
  :root { color-scheme: dark; }
  body { margin: 0; background: #0B0B0D; color: #F3EFE6; font: 16px/1.45 system-ui, sans-serif; }
  main { max-width: 440px; margin: 0 auto; padding: 28px 20px 40px; }
  h1 { font: 600 26px/1.2 Georgia, serif; margin: 0 0 6px; }
  p { color: #9C9AA3; margin: 0 0 22px; }
  label { display: block; font-size: 14px; color: #9C9AA3; margin: 16px 0 6px; }
  input, select { width: 100%; box-sizing: border-box; padding: 13px 14px; font-size: 16px; color: #F3EFE6;
    background: #15151A; border: 1px solid #2C2C35; border-radius: 12px; }
  input:focus, select:focus { outline: none; border-color: #E8A33D; }
  .row { display: flex; align-items: center; gap: 10px; margin-top: 16px; color: #F3EFE6; }
  .row input { width: auto; }
  button { width: 100%; margin-top: 24px; padding: 14px; font-size: 16px; font-weight: 600; color: #1A1206;
    background: #E8A33D; border: 0; border-radius: 12px; }
  button:disabled { opacity: .6; }
  #result { margin-top: 18px; min-height: 24px; }
  .ok { color: #E8A33D; } .bad { color: #FF6B5E; }
  small { display: block; color: #5E5C66; margin-top: 22px; }
</style></head><body><main>
<h1>Add network server</h1>
<p>Sending to <b>${escape(tvName)}</b>. Fill this in and the TV connects by itself.</p>
<form id="f" autocomplete="off">$serverField
  <label for="address">Server address</label>
  <input id="address" required placeholder="\\192.168.0.10\Movies" autocapitalize="off" spellcheck="false">
  <div class="row"><input type="checkbox" id="guest"><span>Guest (no password)</span></div>
  <div id="login">
    <label for="username">Username</label>
    <input id="username" autocapitalize="off" spellcheck="false" autocomplete="username">
    <label for="password">Password</label>
    <input id="password" type="password" autocomplete="current-password">
  </div>
  <button id="send">Send to TV</button>
</form>
<div id="result"></div>
<small>This page talks only to your TV, over your home Wi-Fi. It stops working when you close the screen on the TV.</small>
<script>
  const g = document.getElementById('guest');
  g.onchange = () => document.getElementById('login').style.display = g.checked ? 'none' : '';
  document.getElementById('f').onsubmit = async (e) => {
    e.preventDefault();
    const button = document.getElementById('send'), result = document.getElementById('result');
    button.disabled = true; result.className = ''; result.textContent = 'Connecting on the TV…';
    try {
      const response = await fetch('${escape(sendPath)}', { method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ address: document.getElementById('address').value, guest: g.checked,
          username: document.getElementById('username').value, password: document.getElementById('password').value }) });
      const reply = await response.json();
      result.className = reply.ok ? 'ok' : 'bad'; result.textContent = reply.message;
      if (reply.ok) document.getElementById('f').style.display = 'none';
    } catch (err) {
      result.className = 'bad'; result.textContent = "Couldn't reach the TV. Check it's still showing the QR code.";
    }
    button.disabled = false;
  };
</script>
</main></body></html>"""
    }

    fun escape(text: String): String = text
        .replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
        .replace("\"", "&quot;").replace("'", "&#39;")
}

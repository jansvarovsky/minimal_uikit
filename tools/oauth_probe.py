#!/usr/bin/env python3
"""Checks what the OAuth server accepts for a loopback (development) client. Sends no credentials."""
import base64, hashlib, json, os, secrets, subprocess, tempfile, time, urllib.error, urllib.parse, urllib.request
UA = {'User-Agent': 'thimble-test'}
def get(u): return json.load(urllib.request.urlopen(urllib.request.Request(u, headers=UA), timeout=20))
kv = dict(l.strip().split('=', 1) for l in open(os.path.expanduser('~/.config/tinysky/credentials')) if '=' in l and not l.startswith('#'))
did = get('https://bsky.social/xrpc/com.atproto.identity.resolveHandle?handle=' + kv['TINYSKY_A_HANDLE'])['did']
pds = [s for s in get('https://plc.directory/' + did)['service'] if s['id'] == '#atproto_pds'][0]['serviceEndpoint']
pr = get(pds + '/.well-known/oauth-protected-resource')
print('authorization_servers', pr['authorization_servers'])
a = get(pr['authorization_servers'][0] + '/.well-known/oauth-authorization-server')
print('dpop', a.get('dpop_signing_alg_values_supported'), 'scopes', a.get('scopes_supported'))
print('auth methods', a.get('token_endpoint_auth_methods_supported'))
b64 = lambda b: base64.urlsafe_b64encode(b).rstrip(b'=').decode()
d = tempfile.mkdtemp()
key = d + '/k.pem'
subprocess.run(['openssl', 'ecparam', '-name', 'prime256v1', '-genkey', '-noout', '-out', key], check=True, capture_output=True)
der = subprocess.run(['openssl', 'ec', '-in', key, '-pubout', '-outform', 'DER'], check=True, capture_output=True).stdout
pt = der[-65:]
jwk = {'kty': 'EC', 'crv': 'P-256', 'x': b64(pt[1:33]), 'y': b64(pt[33:])}
def rawsig(m):
    s = subprocess.run(['openssl', 'dgst', '-sha256', '-sign', key], input=m, check=True, capture_output=True).stdout
    i = 3 + 1; rl = s[3]; r = s[4:4 + rl]; sl = s[5 + rl]; t = s[6 + rl:6 + rl + sl]
    return r[-32:].rjust(32, b'\0') + t[-32:].rjust(32, b'\0')
def proof(url, nonce=None):
    h = b64(json.dumps({'typ': 'dpop+jwt', 'alg': 'ES256', 'jwk': jwk}).encode())
    c = {'htm': 'POST', 'htu': url, 'iat': int(time.time()), 'jti': secrets.token_urlsafe(12)}
    if nonce: c['nonce'] = nonce
    m = (h + '.' + b64(json.dumps(c).encode())).encode()
    return m.decode() + '.' + b64(rawsig(m))
redirect = 'http://127.0.0.1:8123/cb'
scope = 'atproto transition:generic transition:chat.bsky'
cid = 'http://localhost?' + urllib.parse.urlencode({'redirect_uri': redirect, 'scope': scope})
ver = secrets.token_urlsafe(40)
form = urllib.parse.urlencode({'client_id': cid, 'response_type': 'code', 'redirect_uri': redirect, 'scope': scope, 'state': secrets.token_urlsafe(8),
    'code_challenge': b64(hashlib.sha256(ver.encode()).digest()), 'code_challenge_method': 'S256', 'login_hint': kv['TINYSKY_A_HANDLE']}).encode()
url = a['pushed_authorization_request_endpoint']
nonce = None
for attempt in range(2):
    r = urllib.request.Request(url, data=form, headers={**UA, 'Content-Type': 'application/x-www-form-urlencoded', 'DPoP': proof(url, nonce)})
    try:
        out = json.load(urllib.request.urlopen(r, timeout=20)); print('PAR OK; has request_uri:', 'request_uri' in out); break
    except urllib.error.HTTPError as e:
        body = e.read(); nonce = e.headers.get('DPoP-Nonce'); print('PAR', e.code, body[:200], 'nonce given:', bool(nonce))
